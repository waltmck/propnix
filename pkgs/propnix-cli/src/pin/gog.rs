//! GOG Galaxy content-system v2: plan a build's tree from manifests, then stream its bytes.
//!
//! Reproduces byte-for-byte the tree `fetchGogGalaxyBuild` produces via gogdl, without writing the game
//! to disk. The materialization rules below are gogdl 1.2.2's, cited to its source; the model is
//! validated against every GOG pin in this repo (see `propnix-pin gog hash --expect`).
//!
//! AUTH SPLIT — the reason a weekly update check needs no secret at all:
//!   anonymous : builds list, build meta, depot manifests, the dependency repository
//!   Bearer    : `secure_link` only, i.e. the URLs the actual content chunks come from
//! So detecting "is there a newer build, and what files would it contain" is entirely free; only
//! recomputing the hash needs the credential.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::sync::Mutex;

use serde_json::Value;

use crate::pin::nar;

const CS: &str = "https://content-system.gog.com";
const CDN: &str = "https://gog-cdn-fastly.gog.com";
const AUTH: &str = "https://auth.gog.com";
/// gogdl's Galaxy client identity (auth.py CLIENT_ID/CLIENT_SECRET). Not a secret of ours — it is the
/// public client id every Galaxy client presents; the user's refresh token is the actual credential.
const CLIENT_ID: &str = "46899977096215655";
const CLIENT_SECRET: &str = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9";
const UA: &str = "gogdl/1.2.2 (Heroic Games Launcher)";

#[derive(Debug)]
pub enum GogError {
    /// No usable GOG credential in the store at all. A DIFFERENT problem from "this account does not own
    /// it", and a different instruction to the human — which is why it is its own variant rather than a
    /// substring of `NotOwned` (the exit-code classifier reads the type; see `pin::blocked_from`).
    NoCredential(String),
    /// The account does not own this product / DLC. NOT a failure: the caller no-ops.
    NotOwned(String),
    /// A construct we refuse to guess at rather than emit a possibly-wrong hash.
    Unsupported(String),
    Http(String),
    Parse(String),
}

impl std::fmt::Display for GogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GogError::NoCredential(m) => write!(f, "{m}"),
            GogError::NotOwned(m) => write!(f, "not owned by this account: {m}"),
            GogError::Unsupported(m) => write!(f, "refusing to hash: {m}"),
            GogError::Http(m) => write!(f, "GOG request failed: {m}"),
            GogError::Parse(m) => write!(f, "unexpected GOG response: {m}"),
        }
    }
}

impl std::error::Error for GogError {}

type R<T> = Result<T, GogError>;

/// `dl_utils.galaxy_path` — content addresses sit under a 2/2 hex fan-out.
///
/// Errors rather than slicing blind: a manifest carrying an empty or malformed `compressedMd5` would
/// otherwise panic on `&h[0..2]` INSIDE A WORKER THREAD, which used to hang the run forever rather than
/// fail it (see `prefetch::run`).
fn galaxy_path(h: &str) -> R<String> {
    if h.contains('/') {
        return Ok(h.to_string());
    }
    if h.len() < 4 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(GogError::Parse(format!(
            "content address {h:?} is not a hex digest, so its CDN path cannot be formed"
        )));
    }
    Ok(format!("{}/{}/{}", &h[0..2], &h[2..4], h))
}

/// Is this a 32-character hex MD5, as every manifest chunk must carry?
fn is_md5_hex(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// One pooled agent for the whole process.
///
/// `ureq::get()` builds a FRESH agent per call, so every chunk would pay a new TCP + TLS handshake and
/// no connection could ever be reused. With tens of thousands of chunk requests that dominates. The
/// idle-connection caps must be at least the worker count, or surplus connections are closed as soon as
/// they go idle and the next request re-handshakes anyway.
///
/// A READ timeout is as load-bearing as the connect one: the emitter consumes chunks strictly in order,
/// so one silently stalled CDN connection blocks the whole hash — with no timeout that is not a slow
/// run, it is a hang until CI's own 350-minute cap kills it.
fn agent() -> &'static ureq::Agent {
    use std::sync::OnceLock;
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .max_idle_connections(256)
            .max_idle_connections_per_host(256)
            .timeout_connect(std::time::Duration::from_secs(20))
            .timeout_read(std::time::Duration::from_secs(60))
            .build()
    })
}

/// A failed request that still knows its HTTP status, so the caller can decide both what it MEANS
/// (401/403 is an ownership gate on a product endpoint, an expired signature on a chunk URL) and whether
/// it is worth retrying.
struct HttpFail {
    status: Option<u16>,
    msg: String,
}

impl std::fmt::Display for HttpFail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.msg)
    }
}

impl HttpFail {
    /// Was this the network, rather than the server's considered answer? No status at all means the
    /// connection itself failed — which is what a dropped TCP session, a moved laptop or a recycled NAT
    /// looks like from here.
    fn transient(&self) -> bool {
        matches!(self.status, None | Some(408 | 425 | 429 | 500..=599))
    }
}

/// The transport, with the HTTP status kept (see `HttpFail`).
fn get_bytes_raw(url: &str, bearer: Option<&str>) -> Result<Vec<u8>, HttpFail> {
    let mut req = agent().get(url).set("User-Agent", UA);
    if let Some(t) = bearer {
        req = req.set("Authorization", &format!("Bearer {t}"));
    }
    match req.call() {
        Ok(resp) => {
            let mut buf = Vec::new();
            resp.into_reader().read_to_end(&mut buf).map_err(|e| HttpFail {
                // A body that ends early is the classic shape of a connection dropped mid-transfer.
                status: None,
                msg: format!("reading body: {e}"),
            })?;
            Ok(buf)
        }
        Err(ureq::Error::Status(code, _)) => Err(HttpFail {
            status: Some(code),
            msg: format!("HTTP {code}"),
        }),
        Err(e) => Err(HttpFail {
            status: None,
            // NEVER `e.to_string()` for a transport error: ureq's `Display for Transport` PREFIXES the
            // request URL (error.rs:229), and some of our URLs carry secrets in the query string — the
            // token exchange puts the refresh token AND the client secret there. Take the kind and the
            // underlying io/TLS error instead, which name the failure without naming the request; every
            // caller appends its own redacted URL where one is safe to show.
            msg: {
                let mut m = e.kind().to_string();
                if let Some(src) = std::error::Error::source(&e) {
                    m.push_str(": ");
                    m.push_str(&src.to_string());
                }
                m
            },
        }),
    }
}

/// A PRODUCT/metadata endpoint (builds list, build meta, depot manifests, `secure_link`). Here 401/403
/// is GOG's ownership gate, not a transport problem — and a transport problem is retried rather than
/// failing a run that has not even started downloading yet.
fn get_bytes(url: &str, bearer: Option<&str>) -> R<Vec<u8>> {
    let label = redact(url);
    match crate::pin::retry::with_retry(
        &label,
        &crate::pin::retry::METADATA,
        HttpFail::transient,
        || get_bytes_raw(url, bearer),
    ) {
        Ok(v) => Ok(v),
        Err(HttpFail {
            status: Some(code @ (401 | 403)),
            ..
        }) => Err(GogError::NotOwned(format!("HTTP {code} for {label}"))),
        Err(e) => Err(GogError::Http(format!("{e} for {label}"))),
    }
}

/// URLs can carry signed query parameters; never let one reach a log verbatim.
fn redact(url: &str) -> String {
    match url.split_once('?') {
        Some((base, _)) => format!("{base}?<redacted>"),
        None => url.to_string(),
    }
}

/// A chunk URL is built from `secure_link`'s `url_format`, which may embed signed parameters as PATH
/// SEGMENTS rather than as a query string — so `redact` is not enough here. Log only scheme + host; the
/// chunk's own md5 is what identifies the request anyway, and the caller already prints it.
fn redact_chunk(url: &str) -> String {
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url));
    let host = rest.split('/').next().unwrap_or("");
    if scheme.is_empty() {
        format!("{host}/<redacted>")
    } else {
        format!("{scheme}://{host}/<redacted>")
    }
}

fn get_json(url: &str, bearer: Option<&str>) -> R<Value> {
    let raw = get_bytes(url, bearer)?;
    // content-system v2 metadata is zlib-wrapped; some endpoints answer plain JSON.
    let text = match inflate(&raw) {
        Ok(v) => v,
        Err(_) => raw,
    };
    serde_json::from_slice(&text).map_err(|e| GogError::Parse(format!("{e} from {}", redact(url))))
}

fn inflate(b: &[u8]) -> std::io::Result<Vec<u8>> {
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(b).read_to_end(&mut out)?;
    Ok(out)
}

/// Exchange a stored refresh token for a short-lived access token. The token never reaches stdout,
/// stderr, or any error message.
///
/// CLASSIFY BY STATUS, NOT BY "IT FAILED". Mapping every failure here to `NotOwned` — as this used to —
/// turns an auth.gog.com outage, or a laptop with no network, into "the stored GOG refresh token was
/// rejected": the caller then walks EVERY stored account, files a false not-owned issue, and the weekly
/// run goes green (exit 4) instead of red. Only a status that means the server considered and refused
/// the grant is an ownership answer; everything else is transport, and is retried and then reported as
/// one.
pub fn access_token(refresh_token: &str) -> R<String> {
    let url = format!(
        "{AUTH}/token?client_id={CLIENT_ID}&client_secret={CLIENT_SECRET}\
         &grant_type=refresh_token&refresh_token={refresh_token}"
    );
    // The label carries no URL on purpose: this one embeds both the refresh token and the client
    // secret. (`get_bytes_raw` also keeps ureq's URL out of the message it builds.)
    let raw = crate::pin::retry::with_retry(
        "GOG token exchange",
        &crate::pin::retry::METADATA,
        HttpFail::transient,
        || get_bytes_raw(&url, None),
    )
    .map_err(|f| match f.status {
        // OAuth2 answers a dead or revoked grant with 400 invalid_grant; a rejected client is 401/403.
        Some(400 | 401 | 403) => GogError::NotOwned(
            "the stored GOG refresh token was rejected — re-run `propnix cred add gog`".into(),
        ),
        Some(code) => GogError::Http(format!("GOG token exchange failed: HTTP {code}")),
        None => GogError::Http(format!("GOG token exchange failed: {f}")),
    })?;
    let text = inflate(&raw).unwrap_or(raw);
    let v: Value = serde_json::from_slice(&text)
        .map_err(|_| GogError::Parse("token response was not JSON".into()))?;
    v.get("access_token")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| GogError::Parse("token response had no access_token".into()))
}

/// One stored GOG account: the label `cred list` shows, and its refresh token.
pub struct GogCredential {
    pub account: String,
    pub refresh_token: String,
}

/// Every GOG account the store offers, in sorted-by-name order, without logging any token.
///
/// A LIST, not a single token, because the fetchers already work this way: a propnix host may hold
/// several GOG accounts and only one of them owns a given title, so the caller tries each until one
/// does (`hash_build`). `want` (from `--gog-account` / `PROPNIX_GOG_ACCOUNT`) narrows it to one, and a
/// name the store does not hold is an error listing what it does — never a silent fall-through to
/// somebody else's account.
pub fn gog_credentials(
    cred_dir: &std::path::Path,
    want: Option<&str>,
) -> R<Vec<GogCredential>> {
    // (account label, token path). The legacy single-file layout has no username in its path, so it
    // gets a synthetic label — it must still be selectable and reportable by name.
    let mut candidates: Vec<(String, std::path::PathBuf)> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(cred_dir.join("gog")) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            candidates.push((name, e.path().join("galaxy_tokens.json")));
        }
    }
    candidates.sort();
    candidates.push((
        "<legacy>".to_string(),
        cred_dir.join("galaxy_tokens.json"), // older single-account layout
    ));

    let mut denied: Option<String> = None;
    let mut out: Vec<GogCredential> = Vec::new();
    for (account, p) in candidates {
        let text = match std::fs::read_to_string(&p) {
            Ok(t) => t,
            // A store from before user-ownership holds root-owned tokens: converge this one onto the
            // store contract (a one-off, sudo-escalated chown) and retry, rather than misreporting a
            // token we were denied as "no credential".
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                match crate::cred::store::repair_unreadable_token(cred_dir, &p)
                    .and_then(|()| {
                        std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))
                    }) {
                    Ok(t) => t,
                    Err(msg) => {
                        denied.get_or_insert(msg);
                        continue;
                    }
                }
            }
            Err(_) => continue,
        };
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            if let Some(t) = v.get("refresh_token").and_then(Value::as_str) {
                out.push(GogCredential {
                    account,
                    refresh_token: t.to_string(),
                });
            }
        }
    }

    if let Some(w) = want {
        let have: Vec<&str> = out.iter().map(|c| c.account.as_str()).collect();
        if !have.contains(&w) {
            return Err(GogError::NoCredential(format!(
                "no GOG account named {w:?} in {} (it holds: {}) — pass --gog-account with one of those, \
                 or unset PROPNIX_GOG_ACCOUNT to try them all",
                cred_dir.display(),
                if have.is_empty() { "none".to_string() } else { have.join(", ") }
            )));
        }
        out.retain(|c| c.account == w);
    }

    if out.is_empty() {
        // A permission problem we could not repair is the real story; "no credential" would send the
        // user off to mint a token they already have.
        return Err(match denied {
            Some(m) => GogError::NotOwned(m),
            None => GogError::NoCredential(format!(
                "no GOG credential under {} — run `propnix cred add gog`",
                cred_dir.display()
            )),
        });
    }
    Ok(out)
}

#[derive(Clone)]
pub struct Chunk {
    pub compressed_md5: String,
    pub md5: String,
    pub size: u64,
}

#[derive(Clone)]
pub struct FileInfo {
    pub path: String,
    pub executable: bool,
    pub size: u64,
    pub chunks: Vec<Chunk>,
    /// Which product's `secure_link` serves these chunks ("redist" for the dependency store).
    pub product: String,
}

pub struct Plan {
    pub install_directory: String,
    pub files: Vec<FileInfo>,
    pub empty_dirs: BTreeSet<String>,
    /// The GLOBAL dependency-repository build this plan was resolved against — `Some` only when the
    /// build actually installs a dependency INTO the game directory, which is the one case where
    /// `buildId` alone does not determine the tree.
    pub deps_build_id: Option<String>,
}

/// How to treat the global dependency repository, for a build that installs a dependency INTO the game
/// directory. `plan` takes this as an `Option`: `None` keeps the historical refusal (the `propnix hash
/// gog` contract — state the repository build explicitly, or be told what it currently is).
pub enum DepsPin {
    /// Resolve the repository's CURRENT build and use it; the caller learns which via Plan.
    UseCurrent,
    /// Refuse unless the repository is at exactly this build (the regression-harness contract).
    Expect(String),
}

/// propnix's post-download prune (fetchGogGalaxyBuild). A depot file matching these would be DELETED by
/// the fetcher, so our tree would disagree with the real one — refuse instead of silently diverging.
fn is_pruned(basename: &str) -> bool {
    matches!(
        basename,
        ".gogdl-resume" | ".gogdl-download-cache" | ".gogdl-redist-manifest" | ".gogdl-linux-manifest"
    ) || basename.ends_with(".tmp")
        || basename.ends_with(".delta")
}

/// A DepotFile's chunk list, STRICTLY. Every defaulted field here would have produced a plausible but
/// wrong hash: a missing `chunks` key silently planned an empty file (gogdl KeyErrors on the same
/// input), an absent md5 became `""` — which then panicked in `galaxy_path` inside a worker thread —
/// and a missing size became 0, quietly shortening the file. Refuse instead, naming the path.
fn chunks_of(item: &Value, path: &str) -> R<Vec<Chunk>> {
    // An empty ARRAY is a legal zero-byte file; an ABSENT key is a shape we have never seen — and one
    // gogdl does not accept either (`objects/v2.py` does `item_data["chunks"]`, a KeyError).
    let arr = item
        .get("chunks")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            GogError::Unsupported(format!(
                "depot file {path:?} carries no `chunks` list, so its contents are undetermined"
            ))
        })?;
    let mut out = Vec::with_capacity(arr.len());
    for (i, c) in arr.iter().enumerate() {
        let hex = |k: &str| -> R<String> {
            let v = c.get(k).and_then(Value::as_str).unwrap_or_default();
            if !is_md5_hex(v) {
                return Err(GogError::Unsupported(format!(
                    "depot file {path:?} chunk {i} has no usable {k} ({v:?})"
                )));
            }
            Ok(v.to_string())
        };
        let compressed_md5 = hex("compressedMd5")?;
        let md5 = hex("md5")?;
        let size = c.get("size").and_then(Value::as_u64).unwrap_or(0);
        if size == 0 {
            return Err(GogError::Unsupported(format!(
                "depot file {path:?} chunk {i} declares no size"
            )));
        }
        out.push(Chunk {
            compressed_md5,
            md5,
            size,
        });
    }
    // GOG's SMALL-FILES CONTAINER. `sfcRef` says the file's bytes ALSO live at an offset inside a shared
    // blob the depot ships (`smallFilesContainer`) — an transfer optimization, not a second encoding: the
    // item still carries its own complete `chunks`, and gogdl 1.2.2 ignores the key entirely (there is no
    // `sfc` anywhere in its source), downloading the chunks like any other file. 32 of homeworld-rm's
    // files are shaped this way and its pinned hash was computed from exactly those chunks.
    //
    // So the container is not a construct to refuse — but it IS a cross-check worth making: if the chunk
    // list ever failed to cover what `sfcRef` declares, the file's content would be determined by
    // something this planner does not read, and the hash would be wrong.
    if let Some(sfc) = item.get("sfcRef") {
        let want = sfc.get("size").and_then(Value::as_u64);
        let have: u64 = out.iter().map(|c| c.size).sum();
        if want != Some(have) {
            return Err(GogError::Unsupported(format!(
                "depot file {path:?} is in a small-files container declaring {want:?} bytes, but its own \
                 chunks cover {have} — its contents would come from the container, which is not read here"
            )));
        }
    }
    Ok(out)
}

// ─────────────────────────────────────────── languages ────────────────────────────────────────────
/// One row of gogdl's language table (gogdl 1.2.2 `gogdl/languages.py`, itself machine-generated from
/// https://api.gog.com/v1/languages).
struct L(&'static str, &'static str, &'static [&'static str]);

impl L {
    /// gogdl `Language.__eq__`'s string branch: a raw string matches this row when it equals — CASE
    /// INSENSITIVELY — the code, the ENGLISH NAME, or any DEPRECATED code. `native_name` is deliberately
    /// absent from the table: gogdl never compares it, so "Deutsch" matches nothing.
    fn matches(&self, s: &str) -> bool {
        let s = s.to_lowercase();
        s == self.0.to_lowercase()
            || s == self.1.to_lowercase()
            || self.2.iter().any(|d| s == d.to_lowercase())
    }
}

/// gogdl's language table, verbatim (gogdl 1.2.2 languages.py:39+, 84 rows).
///
/// WHY THE WHOLE TABLE. A depot is selected by `Depot.check_language`, which compares the requested
/// language against the depot's advertised list through the equality above — so `"de"` matches a depot
/// listing `de-DE`, and `"English"` matches one listing `en-US`. Special-casing only en→en-US (what this
/// module used to do) silently DROPPED every localized depot for any other language, and then hashed the
/// remainder: a pin that never verifies. There is no prefix or BCP-47 fallback in gogdl either — `en-AU`
/// matches nothing — so the table has to be complete to be faithful.
const LANGUAGES: &[L] = &[
    L("af-ZA", "Afrikaans", &[]),
    L("ar", "Arabic", &[]),
    L("az-AZ", "Azeri", &[]),
    L("be-BY", "Belarusian", &["be"]),
    L("bn-BD", "Bengali", &["bn_BD"]),
    L("bg-BG", "Bulgarian", &["bg", "bl"]),
    L("bs-BA", "Bosnian", &[]),
    L("ca-ES", "Catalan", &["ca"]),
    L("cs-CZ", "Czech", &["cz"]),
    L("cy-GB", "Welsh", &[]),
    L("da-DK", "Danish", &["da"]),
    L("de-DE", "German", &["de"]),
    L("dv-MV", "Divehi", &[]),
    L("el-GR", "Greek", &["gk", "el-GK"]),
    L("en-GB", "British English", &["en_GB"]),
    L("en-US", "English", &["en"]),
    L("es-ES", "Spanish", &["es"]),
    L("es-MX", "Latin American Spanish", &["es_mx"]),
    L("et-EE", "Estonian", &["et"]),
    L("eu-ES", "Basque", &[]),
    L("fa-IR", "Persian", &["fa"]),
    L("fi-FI", "Finnish", &["fi"]),
    L("fo-FO", "Faroese", &[]),
    L("fr-FR", "French", &["fr"]),
    L("gl-ES", "Galician", &[]),
    L("gu-IN", "Gujarati", &["gu"]),
    L("he-IL", "Hebrew", &["he"]),
    L("hi-IN", "Hindi", &["hi"]),
    L("hr-HR", "Croatian", &[]),
    L("hu-HU", "Hungarian", &["hu"]),
    L("hy-AM", "Armenian", &[]),
    L("id-ID", "Indonesian", &[]),
    L("is-IS", "Icelandic", &["is"]),
    L("it-IT", "Italian", &["it"]),
    L("ja-JP", "Japanese", &["jp"]),
    L("jv-ID", "Javanese", &["jv"]),
    L("ka-GE", "Georgian", &[]),
    L("kk-KZ", "Kazakh", &[]),
    L("kn-IN", "Kannada", &[]),
    L("ko-KR", "Korean", &["ko"]),
    L("kok-IN", "Konkani", &[]),
    L("ky-KG", "Kyrgyz", &[]),
    L("la", "Latin", &[]),
    L("lt-LT", "Lithuanian", &[]),
    L("lv-LV", "Latvian", &[]),
    L("ml-IN", "Malayalam", &["ml"]),
    L("mi-NZ", "Maori", &[]),
    L("mk-MK", "Macedonian", &[]),
    L("mn-MN", "Mongolian", &[]),
    L("mr-IN", "Marathi", &["mr"]),
    L("ms-MY", "Malay", &[]),
    L("mt-MT", "Maltese", &[]),
    L("nb-NO", "Norwegian", &["no"]),
    L("nl-NL", "Dutch", &["nl"]),
    L("ns-ZA", "Northern Sotho", &[]),
    L("pa-IN", "Punjabi", &[]),
    L("pl-PL", "Polish", &["pl"]),
    L("ps-AR", "Pashto", &[]),
    L("pt-BR", "Portuguese (Brazilian)", &["br"]),
    L("pt-PT", "Portuguese", &["pt"]),
    L("ro-RO", "Romanian", &["ro"]),
    L("ru-RU", "Russian", &["ru"]),
    L("sa-IN", "Sanskrit", &[]),
    L("sk-SK", "Slovak", &["sk"]),
    L("sl-SI", "Slovenian", &[]),
    L("sq-AL", "Albanian", &[]),
    L("sr-SP", "Serbian", &["sb"]),
    L("sv-SE", "Swedish", &["sv"]),
    L("sw-KE", "Kiswahili", &[]),
    L("ta-IN", "Tamil", &["ta_IN"]),
    L("te-IN", "Telugu", &["te"]),
    L("th-TH", "Thai", &["th"]),
    L("tl-PH", "Tagalog", &[]),
    L("tn-ZA", "Setswana", &[]),
    L("tr-TR", "Turkish", &["tr"]),
    L("tt-RU", "Tatar", &[]),
    L("uk-UA", "Ukrainian", &["uk"]),
    L("ur-PK", "Urdu", &["ur_PK"]),
    L("uz-UZ", "Uzbek", &[]),
    L("vi-VN", "Vietnamese", &["vi"]),
    L("xh-ZA", "isiXhosa", &[]),
    L("zh-Hans", "Chinese (Simplified)", &["zh_Hans", "zh", "cn"]),
    L("zh-Hant", "Chinese (Traditional)", &["zh_Hant"]),
    L("zu-ZA", "isiZulu", &[]),
];

/// gogdl `Language.parse`: the first row the requested string matches. `None` for an unknown language
/// (and for `"*"`, which gogdl treats as "no language" on the REQUEST side and then crashes on).
fn parse_language(val: &str) -> Option<&'static L> {
    if val == "*" {
        return None;
    }
    LANGUAGES.iter().find(|l| l.matches(val))
}

/// gogdl `Depot.check_language`: a depot's advertised language string against the requested one. `"*"` is
/// the v2 manifest's language-NEUTRAL sentinel (matched exactly, as gogdl does) and selects the depot for
/// every request.
fn lang_matches(want: &L, depot_lang: &str) -> bool {
    depot_lang == "*" || want.matches(depot_lang)
}

/// Resolve a build into the exact set of files and empty directories its tree will contain.
/// Every call here is anonymous.
pub fn plan(
    product_id: &str,
    build_id: &str,
    os: &str,
    lang: &str,
    dlc_id: Option<&str>,
    deps: Option<&DepsPin>,
) -> R<Plan> {
    let builds = get_json(
        &format!("{CS}/products/{product_id}/os/{os}/builds?generation=2"),
        None,
    )?;
    let items = builds
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| GogError::Parse("builds list has no items".into()))?;
    let target_build = items
        .iter()
        .find(|b| b.get("build_id").and_then(Value::as_str) == Some(build_id))
        .ok_or_else(|| {
            GogError::Unsupported(format!(
                "build {build_id} is no longer listed for {product_id}/{os} (aged out or delisted)"
            ))
        })?;
    if target_build.get("generation").and_then(Value::as_u64) != Some(2) {
        return Err(GogError::Unsupported(format!(
            "build {build_id} is not generation 2"
        )));
    }
    let link = target_build
        .get("link")
        .and_then(Value::as_str)
        .ok_or_else(|| GogError::Parse("build has no link".into()))?;
    let meta = get_json(link, None)?;

    let base = meta
        .get("baseProductId")
        .and_then(Value::as_str)
        .ok_or_else(|| GogError::Parse("meta has no baseProductId".into()))?;
    let target = dlc_id.unwrap_or(base).to_string();
    if let Some(d) = dlc_id {
        let known = meta
            .get("products")
            .and_then(Value::as_array)
            .map(|ps| {
                ps.iter()
                    .any(|p| p.get("productId").and_then(Value::as_str) == Some(d))
            })
            .unwrap_or(false);
        if !known {
            return Err(GogError::Unsupported(format!(
                "DLC {d} is not among build {build_id}'s products"
            )));
        }
    }
    // gogdl `Language.parse`: resolve the pin's language ONCE against the real table, and refuse an
    // unknown one outright — gogdl itself dies on it (AttributeError on None.code), and silently
    // matching no depot would hash a truncated tree.
    let want_lang = parse_language(lang).ok_or_else(|| {
        GogError::Unsupported(format!(
            "language {lang:?} is not one GOG publishes (it is matched against gogdl's table by code, \
             English name or deprecated alias)"
        ))
    })?;

    let mut files: BTreeMap<String, FileInfo> = BTreeMap::new();
    let mut empty_dirs: BTreeSet<String> = BTreeSet::new();
    let mut links: Vec<String> = Vec::new();

    // objects/v2.py: backslashes to slashes, then strip leading and trailing slashes. Files and
    // directories are normalized IDENTICALLY — a directory that keeps a leading slash would land at a
    // different tree position than the files inside it.
    let norm = |raw: &str| -> String {
        raw.replace('\\', "/")
            .trim_start_matches('/')
            .trim_end_matches('/')
            .to_string()
    };

    let mut consume = |prod: &str, depot_items: &[Value]| -> R<()> {
        for i in depot_items {
            let t = i.get("type").and_then(Value::as_str).unwrap_or("");
            match t {
                "DepotFile" => {
                    let raw = i.get("path").and_then(Value::as_str).unwrap_or("");
                    let mut p = norm(raw);
                    let flags: Vec<&str> = i
                        .get("flags")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().filter_map(Value::as_str).collect())
                        .unwrap_or_default();
                    // A `support` file is relocated out of the game dir proper.
                    if flags.contains(&"support") {
                        p = format!("gog-support/{prod}/{p}");
                    }
                    let base_name = p.rsplit('/').next().unwrap_or(&p);
                    if is_pruned(base_name) {
                        return Err(GogError::Unsupported(format!(
                            "depot file {p:?} matches the fetcher's prune patterns, so the real tree \
                             would not contain it"
                        )));
                    }
                    let ch = chunks_of(i, &p)?;
                    let info = FileInfo {
                        size: ch.iter().map(|c| c.size).sum(),
                        path: p.clone(),
                        executable: flags.contains(&"executable"),
                        chunks: ch,
                        product: prod.to_string(),
                    };
                    if files.insert(p.clone(), info).is_some() {
                        return Err(GogError::Unsupported(format!(
                            "two depot entries claim {p:?}; which one wins depends on download order"
                        )));
                    }
                }
                "DepotDirectory" => {
                    let p = norm(i.get("path").and_then(Value::as_str).unwrap_or(""));
                    if !p.is_empty() {
                        empty_dirs.insert(p);
                    }
                }
                "DepotLink" => {
                    links.push(i.get("path").and_then(Value::as_str).unwrap_or("").to_string())
                }
                other => {
                    return Err(GogError::Unsupported(format!(
                        "unknown depot item type {other:?}"
                    )))
                }
            }
        }
        Ok(())
    };

    for d in meta
        .get("depots")
        .and_then(Value::as_array)
        .unwrap_or(&Vec::new())
    {
        if d.get("productId").and_then(Value::as_str) != Some(target.as_str()) {
            continue;
        }
        let langs: Vec<&str> = d
            .get("languages")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        if !langs.iter().any(|l| lang_matches(want_lang, l)) {
            continue;
        }
        let manifest = d
            .get("manifest")
            .and_then(Value::as_str)
            .ok_or_else(|| GogError::Parse("depot has no manifest".into()))?;
        let dm = get_json(
            &format!("{CDN}/content-system/v2/meta/{}", galaxy_path(manifest)?),
            None,
        )?;
        let items = dm
            .get("depot")
            .and_then(|d| d.get("items"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        consume(&target, &items)?;
    }

    // Dependencies whose executable does NOT live under __redist/ are installed INTO the game dir, so
    // they are part of the hashed tree (proven by homeworld-rm's language_setup). Those come from the
    // GLOBAL dependency repository, which the build id does NOT pin — so the tree is not fully
    // determined by (productId, buildId) alone. Which repository build was used is therefore recorded
    // alongside the hash (`depsBuildId` in versions.json), and the caller says how to treat it.
    let mut deps_build_id: Option<String> = None;
    if let Some(ids) = meta.get("dependencies").and_then(Value::as_array) {
        let ids: Vec<&str> = ids.iter().filter_map(Value::as_str).collect();
        if !ids.is_empty() {
            let repo = get_json(&format!("{CS}/dependencies/repository?generation=2"), None)?;
            let repo_build = repo
                .get("build_id")
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                })
                .unwrap_or_default();
            let rm = repo
                .get("repository_manifest")
                .and_then(Value::as_str)
                .ok_or_else(|| GogError::Parse("dependency repo has no manifest".into()))?;
            let rmeta = get_json(rm, None)?;
            for d in rmeta
                .get("depots")
                .and_then(Value::as_array)
                .unwrap_or(&Vec::new())
            {
                let dep_id = d.get("dependencyId").and_then(Value::as_str).unwrap_or("");
                if !ids.contains(&dep_id) {
                    continue;
                }
                let exe_path = d
                    .get("executable")
                    .and_then(|e| e.get("path"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if exe_path.starts_with("__redist") {
                    continue; // installed to a shared redist tree, not into the game dir
                }
                match deps {
                    // `propnix hash gog` with no --deps-build-id: the harness contract is to be
                    // EXPLICIT about a tree the build id does not pin, so say what the repository is
                    // at and make the caller repeat it back.
                    None => {
                        return Err(GogError::Unsupported(format!(
                            "build {build_id} pulls dependency {dep_id:?} INTO the game directory from \
                             the global dependency repository, which buildId does not pin — so this \
                             tree can change without the build changing. Re-run with \
                             --deps-build-id {repo_build} to state the repository build you expect."
                        )))
                    }
                    Some(DepsPin::Expect(want)) if *want != repo_build => {
                        return Err(GogError::Unsupported(format!(
                            "dependency repository is at build {repo_build}, but --deps-build-id said \
                             {want}; {dep_id:?} is installed into the game directory, so the hash would \
                             not be the one you asked to reproduce"
                        )))
                    }
                    // UseCurrent never refuses: `propnix pin` MAINTAINS the recorded value, and drift
                    // between runs surfaces as an FOD hash mismatch, which is the loud failure we want.
                    Some(_) => {}
                }
                deps_build_id = Some(repo_build.clone());
                let manifest = d
                    .get("manifest")
                    .and_then(Value::as_str)
                    .ok_or_else(|| GogError::Parse("dependency depot has no manifest".into()))?;
                let m = get_json(
                    &format!(
                        "{CDN}/content-system/v2/dependencies/meta/{}",
                        galaxy_path(manifest)?
                    ),
                    None,
                )?;
                let items: Vec<Value> = m
                    .get("depot")
                    .and_then(|d| d.get("items"))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|i| i.get("type").and_then(Value::as_str) == Some("DepotFile"))
                    .collect();
                consume("redist", &items)?;
            }
        }
    }

    if !links.is_empty() {
        return Err(GogError::Unsupported(format!(
            "build contains {} DepotLink entries ({:?}…); gogdl writes those as ABSOLUTE symlinks into \
             the install directory, so the tree embeds a build-specific path and is not reproducible",
            links.len(),
            &links[..links.len().min(3)]
        )));
    }

    // A plan with no files hashes to the EMPTY-DIRECTORY NAR — a perfectly valid-looking hash for a
    // game that was never planned. The realistic cause is a language that matched no depot, so say so.
    if files.is_empty() {
        return Err(GogError::Unsupported(format!(
            "build {build_id} of {product_id}/{os} planned ZERO files for lang {lang:?} — every depot \
             was skipped, and hashing that would silently produce the empty-directory hash"
        )));
    }

    Ok(Plan {
        install_directory: meta
            .get("installDirectory")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        files: files.into_values().collect(),
        empty_dirs,
        deps_build_id,
    })
}

/// Every case-only collision in a plan, at ANY path depth.
///
/// gogdl resolves each path component case-insensitively against what is already on disk, so
/// `Data/a.dat` and `data/b.dat` land in ONE directory while a naive plan carries two — a whole-path
/// comparison never sees it, and the resulting hash is plausible but wrong. Which casing survives
/// depends on which entry gogdl happens to create first, so the real tree is not even well defined:
/// refuse. Every PREFIX of every file path, plus the empty-directory entries, is checked.
fn case_collision(plan: &Plan) -> Option<(String, String)> {
    let mut seen: BTreeMap<String, String> = BTreeMap::new();
    let mut check = |path: &str| -> Option<(String, String)> {
        let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
        for depth in 1..=parts.len() {
            let prefix = parts[..depth].join("/");
            if let Some(prev) = seen.insert(prefix.to_lowercase(), prefix.clone()) {
                if prev != prefix {
                    return Some((prev, prefix));
                }
            }
        }
        None
    };
    for f in &plan.files {
        if let Some(hit) = check(&f.path) {
            return Some(hit);
        }
    }
    for d in &plan.empty_dirs {
        if let Some(hit) = check(d) {
            return Some(hit);
        }
    }
    None
}

/// Build the NAR tree. Payload is an index into `plan.files`.
pub fn tree(plan: &Plan) -> Result<nar::Node<usize>, Box<dyn std::error::Error>> {
    if let Some((a, b)) = case_collision(plan) {
        return Err(Box::new(GogError::Unsupported(format!(
            "case-only collision between {a:?} and {b:?}; gogdl coalesces these onto one path in \
             os.listdir order, so the real tree is not well defined"
        ))));
    }
    let mut root: nar::Node<usize> = nar::Node::dir();
    for d in &plan.empty_dirs {
        let parts: Vec<Vec<u8>> = d.split('/').map(|s| s.as_bytes().to_vec()).collect();
        root.insert(&parts, nar::Node::dir())?;
    }
    for (idx, f) in plan.files.iter().enumerate() {
        let parts: Vec<Vec<u8>> = f.path.split('/').map(|s| s.as_bytes().to_vec()).collect();
        root.insert(
            &parts,
            nar::Node::Reg {
                executable: f.executable,
                size: f.size,
                payload: idx,
            },
        )?;
    }
    Ok(root)
}

// ───────────────────────────────────────── chunk transport ────────────────────────────────────────
/// Resolves chunk URLs. `secure_link` is per-product and OAuth-gated; the dependency store is open.
pub struct Cdn {
    /// The stored REFRESH token, not a single access token.
    ///
    /// A GOG access token lives about an hour; hashing a large title takes SEVERAL. So the token minted
    /// at the start of a run WILL age out mid-stream, and `secure_link` then answers 401 — which, taken
    /// at face value, ended a five-hour download with a false "the account does not own this title"
    /// issue. Holding the refresh token means the access token can simply be re-minted (GOG does not
    /// rotate refresh tokens), and only a SECOND refusal is believed.
    refresh_token: Option<String>,
    access: Mutex<Option<String>>,
    /// All endpoints a product's link response offers, not just the first.
    ///
    /// CDNs rate-limit PER CONNECTION and, above roughly sixteen connections, per host as well —
    /// measured on Steam's CDN: 9 Mbit/s on one connection, 91 Mbit/s over 16 to a single host, but
    /// 169 Mbit/s over 32 spread across hosts. So chunk requests are round-robined over every endpoint
    /// offered rather than pinned to `urls[0]`.
    endpoints: Mutex<BTreeMap<String, Vec<Endpoint>>>,
    rr: std::sync::atomic::AtomicUsize,
}

#[derive(Clone)]
enum Endpoint {
    Plain(String),
    Format {
        url_format: String,
        params: BTreeMap<String, String>,
    },
}

impl Cdn {
    pub fn new(refresh_token: Option<String>) -> Self {
        Self {
            refresh_token,
            access: Mutex::new(None),
            endpoints: Mutex::new(BTreeMap::new()),
            rr: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    /// The current access token, minting one on first use.
    fn access(&self) -> R<String> {
        if let Some(t) = self.access.lock().unwrap().clone() {
            return Ok(t);
        }
        self.mint_access()
    }

    /// Mint a FRESH access token from the refresh token, replacing any cached one. Two threads racing
    /// here is harmless: GOG does not rotate refresh tokens, so both mint a valid access token.
    fn mint_access(&self) -> R<String> {
        let refresh = self.refresh_token.as_deref().ok_or_else(|| {
            GogError::NotOwned("game chunks need a GOG token (secure_link is OAuth-gated)".into())
        })?;
        let t = access_token(refresh)?;
        *self.access.lock().unwrap() = Some(t.clone());
        Ok(t)
    }

    /// One `secure_link` resolution with a given access token.
    fn secure_link(&self, product: &str, token: &str) -> R<Value> {
        get_json(
            &format!("{CS}/products/{product}/secure_link?_version=2&generation=2&path=/"),
            Some(token),
        )
    }

    /// Resolve every product's endpoints UP FRONT, before a byte of content is fetched.
    ///
    /// `secure_link` is the ownership gate, so doing it eagerly is what makes "this account does not own
    /// the title" a fast, cheap failure the caller can answer by trying the NEXT stored account — the
    /// same try-all behaviour the fetchers have. Resolved lazily inside a worker thread it would instead
    /// surface mid-stream as an opaque string, long after the point where switching accounts is free.
    pub fn warm(&self, products: &[String]) -> R<()> {
        for p in products {
            self.endpoint(p)?;
        }
        Ok(())
    }

    fn endpoint(&self, product: &str) -> R<Endpoint> {
        {
            let map = self.endpoints.lock().unwrap();
            if let Some(v) = map.get(product) {
                let i = self.rr.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                return Ok(v[i % v.len()].clone());
            }
        }
        let eps = self.fetch_endpoints(product)?;
        let mut map = self.endpoints.lock().unwrap();
        let v = map.entry(product.to_string()).or_insert(eps);
        let i = self.rr.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        Ok(v[i % v.len()].clone())
    }

    /// Forget a product's cached endpoints, so the next request re-resolves `secure_link`. The URLs it
    /// hands out carry a signed expiry, and a multi-hour hash outlives one.
    fn drop_endpoints(&self, product: &str) {
        self.endpoints.lock().unwrap().remove(product);
    }

    fn fetch_endpoints(&self, product: &str) -> R<Vec<Endpoint>> {
        let eps = if product == "redist" {
            let js = get_json(
                &format!("{CS}/open_link?generation=2&_version=2&path=/dependencies/store/"),
                None,
            )?;
            let v: Vec<Endpoint> = js
                .get("urls")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|u| u.get("url").and_then(Value::as_str))
                        .map(|s| Endpoint::Plain(s.to_string()))
                        .collect()
                })
                .unwrap_or_default();
            if v.is_empty() {
                return Err(GogError::Parse("dependency link had no urls".into()));
            }
            v
        } else {
            // A 401 here is ambiguous: either the account really does not own the product, or the
            // ACCESS TOKEN simply aged out — which it will, on any title big enough to take more than
            // an hour. Re-mint once and ask again; only the second refusal is an ownership answer.
            let js = match self.secure_link(product, &self.access()?) {
                Err(GogError::NotOwned(_)) => {
                    eprintln!("  {product}: secure_link refused the access token — re-minting it");
                    self.secure_link(product, &self.mint_access()?)?
                }
                other => other?,
            };
            let v: Vec<Endpoint> = js
                .get("urls")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|u| {
                            let url_format =
                                u.get("url_format").and_then(Value::as_str)?.to_string();
                            let params = u
                                .get("parameters")
                                .and_then(Value::as_object)
                                .map(|o| {
                                    o.iter()
                                        .map(|(k, v)| {
                                            (
                                                k.clone(),
                                                match v {
                                                    Value::String(s) => s.clone(),
                                                    other => other.to_string(),
                                                },
                                            )
                                        })
                                        .collect()
                                })
                                .unwrap_or_default();
                            Some(Endpoint::Format { url_format, params })
                        })
                        .collect()
                })
                .unwrap_or_default();
            if v.is_empty() {
                return Err(GogError::NotOwned(format!(
                    "no secure_link URLs for {product} — the account may not own it"
                )));
            }
            v
        };
        Ok(eps)
    }

    fn url(&self, product: &str, compressed_md5: &str) -> R<String> {
        Ok(match self.endpoint(product)? {
            Endpoint::Plain(base) => format!("{base}/{}", galaxy_path(compressed_md5)?),
            Endpoint::Format { url_format, params } => {
                // task_executor: the `path` parameter gains the chunk's galaxy path, then every
                // {placeholder} in url_format is substituted.
                let mut out = url_format;
                let mut p = params;
                let joined = format!(
                    "{}/{}",
                    p.get("path").cloned().unwrap_or_default(),
                    galaxy_path(compressed_md5)?
                );
                p.insert("path".into(), joined);
                for (k, v) in p {
                    out = out.replace(&format!("{{{k}}}"), &v);
                }
                out
            }
        })
    }

    /// Fetch one chunk and verify it both compressed and decompressed.
    ///
    /// Retried patiently (see `pin::retry`): a hash of a large title runs for hours and cannot be
    /// resumed, so a dropped connection — a laptop changing network, a CDN recycling a pooled socket —
    /// must not throw the whole run away. An immediate 4-shot retry was four failures rather than four
    /// chances; riding out a real outage takes minutes, and is counted in ATTEMPTS so that time the
    /// machine spends suspended does not consume them.
    pub fn chunk(&self, product: &str, c: &Chunk) -> R<Vec<u8>> {
        let label = format!("chunk {}", c.compressed_md5);
        crate::pin::retry::with_retry(
            &label,
            &crate::pin::retry::CONTENT,
            // Everything transport-shaped, INCLUDING a body that failed its md5: a truncated response is
            // exactly what a dropped connection looks like once it has been decompressed. Ownership and
            // parse failures are the server's considered answer and are returned at once.
            |e: &GogError| matches!(e, GogError::Http(_)),
            || self.try_chunk(product, c),
        )
        .map_err(|e| match e {
            GogError::Http(m) => GogError::Http(format!("{label} unrecoverable: {m}")),
            other => other,
        })
    }

    fn try_chunk(&self, product: &str, c: &Chunk) -> R<Vec<u8>> {
        // `warm()` already PROVED ownership before a single content byte moved, so a refusal from
        // re-resolving `secure_link` now cannot mean "you do not own this". Keep it transport-shaped so
        // the retry loop gets its chances and a persistent failure is a red run — never a false
        // not-owned issue against an account that demonstrably owns the title.
        let url = self.url(product, &c.compressed_md5).map_err(|e| match e {
            GogError::NotOwned(m) => {
                GogError::Http(format!("re-resolving secure_link for {product}: {m}"))
            }
            other => other,
        })?;
        let raw = match get_bytes_raw(&url, None) {
            Ok(v) => v,
            // A secure_link URL carries a SIGNED EXPIRY, and a large title takes hours to hash — so a
            // 401/403 mid-stream means the link aged out, NOT that the account lost the game. Mapping it
            // to NotOwned (as the product endpoints do) filed a false "account does not own this title"
            // issue. Re-resolve the product's endpoints and let the retry loop try again.
            Err(HttpFail {
                status: Some(code @ (401 | 403)),
                ..
            }) => {
                self.drop_endpoints(product);
                return Err(GogError::Http(format!(
                    "HTTP {code} for {} — the signed chunk URL expired; re-resolving secure_link",
                    redact_chunk(&url)
                )));
            }
            Err(e) => {
                return Err(GogError::Http(format!("{e} for {}", redact_chunk(&url))));
            }
        };
        if md5_hex(&raw) != c.compressed_md5 {
            return Err(GogError::Http("compressedMd5 mismatch".into()));
        }
        let out = inflate(&raw).map_err(|e| GogError::Http(format!("inflate: {e}")))?;
        if out.len() as u64 != c.size || md5_hex(&out) != c.md5 {
            return Err(GogError::Http("chunk md5/size mismatch".into()));
        }
        Ok(out)
    }
}

fn md5_hex(b: &[u8]) -> String {
    use md5::Digest;
    let d = md5::Md5::digest(b);
    d.iter().map(|x| format!("{x:02x}")).collect()
}


/// One entry from a product's build list.
#[derive(Clone, Debug)]
pub struct BuildRef {
    pub build_id: String,
    pub version_name: String,
    /// GOG's branch name. `None` is the default/public branch; named branches (e.g. "Experimental")
    /// are separate release tracks.
    pub branch: Option<String>,
    pub date_published: String,
    pub public: bool,
}

/// The product's build list, newest first. Anonymous.
pub fn builds(product_id: &str, os: &str) -> R<Vec<BuildRef>> {
    let v = get_json(
        &format!("{CS}/products/{product_id}/os/{os}/builds?generation=2"),
        None,
    )?;
    let items = v
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| GogError::Parse("builds list has no items".into()))?;
    Ok(items
        .iter()
        .map(|b| BuildRef {
            build_id: b.get("build_id").and_then(Value::as_str).unwrap_or("").to_string(),
            version_name: b.get("version_name").and_then(Value::as_str).unwrap_or("").to_string(),
            branch: b.get("branch").and_then(Value::as_str).map(str::to_string),
            date_published: b
                .get("date_published")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            public: b.get("public").and_then(Value::as_bool).unwrap_or(false),
        })
        .collect())
}

/// The newest build on the SAME BRANCH as the one currently pinned.
///
/// Picking "the newest public build" outright is wrong and actively dangerous: a pin may sit on a named
/// release track. Factorio is pinned to `Experimental` 2.1.14, while the newest default-branch build is
/// 2.0.77 — so the naive rule would have silently DOWNGRADED it. A pin's branch is not recorded in
/// versions.json, so it is inferred from the pinned build itself; if that build is no longer listed we
/// refuse rather than guess which track it belonged to.
pub fn newest_on_pinned_branch(product_id: &str, os: &str, pinned: &str) -> R<(BuildRef, BuildRef)> {
    let all = builds(product_id, os)?;
    let cur = all
        .iter()
        .find(|b| b.build_id == pinned)
        .cloned()
        .ok_or_else(|| {
            GogError::Unsupported(format!(
                "build {pinned} is no longer listed for {product_id}/{os}, so its release branch cannot \
                 be determined (GOG returns only the most recent builds). Re-pin this game by hand."
            ))
        })?;
    let branch = cur.branch.clone();
    let newest = all
        .iter()
        .find(|b| b.branch == branch && b.public)
        .cloned()
        .ok_or_else(|| {
            GogError::Unsupported(format!(
                "{product_id}/{os} has no public build on branch {branch:?}"
            ))
        })?;
    Ok((newest, cur))
}

/// The newest DEFAULT-branch build, for the human-facing `gog latest` command.
/// Shared knobs for a streaming hash run.
pub struct HashOpts {
    pub workers: usize,
    pub window_bytes: u64,
    pub credential_dir: std::path::PathBuf,
    /// Which stored GOG account to use. `None` = try every stored account until one owns the title,
    /// exactly as `fetchGogGalaxyBuild` does.
    pub gog_account: Option<String>,
    /// Which stored Steam account to use. Same semantics; consumed by `pin::steam`.
    pub steam_account: Option<String>,
    /// Write a percentage line to stderr. Kept off stdout, which may be a machine-readable document.
    pub progress: bool,
}

/// Resolve a build and stream it into a NAR hash. Nothing touches disk.
pub fn hash_build(
    product_id: &str,
    build_id: &str,
    os: &str,
    lang: &str,
    dlc_id: Option<&str>,
    deps: Option<&DepsPin>,
    opts: &HashOpts,
) -> Result<(String, nar::Stats, Plan), Box<dyn std::error::Error>> {
    let plan = plan(product_id, build_id, os, lang, dlc_id, deps)?;
    let total: u64 = plan.files.iter().map(|f| f.size).sum();
    let tree = tree(&plan)?;

    // The prefetch queue must be built in NAR emission order — nar_hash consumes strictly sequentially.
    let order = nar::flatten(&tree);
    let mut work = Vec::new();
    for &&idx in &order {
        let f = &plan.files[idx];
        for c in &f.chunks {
            work.push((f.product.clone(), c.clone()));
        }
    }

    // TRY EVERY STORED ACCOUNT, like the fetcher does (see `pin::try_accounts` for the policy).
    // `Cdn::warm` is what makes this cheap: `secure_link` IS the ownership gate, so resolving it here
    // settles the question before a single content byte moves.
    let products: Vec<String> = plan
        .files
        .iter()
        .map(|f| f.product.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let creds = gog_credentials(&opts.credential_dir, opts.gog_account.as_deref())?;
    let cdn = crate::pin::try_accounts(
        &creds,
        |c| c.account.clone(),
        |e: &GogError| matches!(e, GogError::NotOwned(_)),
        |tried, last| {
            GogError::NotOwned(format!(
                "no stored GOG account can fetch build {build_id} of {product_id}{} (tried: {}). Last \
                 refusal: {last}",
                dlc_id.map(|d| format!(" DLC {d}")).unwrap_or_default(),
                tried.join(", ")
            ))
        },
        |c| {
            // The Cdn holds the REFRESH token: an access token minted now would expire long before a
            // large title finishes hashing.
            let cdn = Cdn::new(Some(c.refresh_token.clone()));
            cdn.warm(&products)?;
            Ok(cdn)
        },
    )?;

    let cdn = std::sync::Arc::new(cdn);
    let pf = crate::pin::prefetch::Prefetcher::new(
        work,
        opts.workers,
        opts.window_bytes,
        Box::new(move |(product, chunk): &(String, Chunk)| {
            cdn.chunk(product, chunk).map_err(|e| e.to_string())
        }),
    );

    let mut seen = 0u64;
    let mut last_pct = 0u64;
    let progress = opts.progress;
    let (sri, stats) = nar::nar_hash(&tree, |idx, w| {
        let f = &plan.files[*idx];
        for _ in 0..f.chunks.len() {
            let data = pf.next_chunk().map_err(nar::NarError::Fetch)?;
            seen += data.len() as u64;
            w.write_all(&data)?;
        }
        if progress {
            let pct = seen.checked_mul(100).and_then(|n| n.checked_div(total)).unwrap_or(100);
            if pct > last_pct {
                last_pct = pct;
                eprint!("\r  {pct:3}%  {} / {} MiB", seen >> 20, total >> 20);
            }
        }
        Ok(())
    })?;
    if progress {
        eprintln!();
    }
    Ok((sri, stats, plan))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan_of(files: &[(&str, u64)], dirs: &[&str]) -> Plan {
        Plan {
            install_directory: String::new(),
            files: files
                .iter()
                .map(|(p, size)| FileInfo {
                    path: (*p).to_string(),
                    executable: false,
                    size: *size,
                    chunks: Vec::new(),
                    product: "1".into(),
                })
                .collect(),
            empty_dirs: dirs.iter().map(|d| d.to_string()).collect(),
            deps_build_id: None,
        }
    }

    #[test]
    fn languages_match_gogdls_whole_table_not_just_english() {
        // The bug this exists for: a `"lang": "de"` pin against depots that list `de-DE` used to match
        // NOTHING, silently dropping every localized file and emitting a hash that never verifies.
        let de = parse_language("de").expect("gogdl accepts the deprecated code");
        assert!(lang_matches(de, "de-DE"));
        assert!(lang_matches(de, "DE-de"), "the comparison is case-insensitive");
        assert!(!lang_matches(de, "en-US"));

        // A code, an English NAME and a deprecated alias all resolve to the same row.
        for spelling in ["en", "en-US", "EN-us", "English"] {
            let l = parse_language(spelling).unwrap_or_else(|| panic!("{spelling} must resolve"));
            assert_eq!(l.0, "en-US", "{spelling}");
        }
        assert!(parse_language("Simplified Chinese").is_none(), "no fuzzy naming");
        assert_eq!(parse_language("zh").map(|l| l.0), Some("zh-Hans"));
        assert_eq!(parse_language("cn").map(|l| l.0), Some("zh-Hans"));
        assert_eq!(parse_language("pt").map(|l| l.0), Some("pt-PT"));
        assert_eq!(parse_language("br").map(|l| l.0), Some("pt-BR"));
        // gogdl has no BCP-47 prefix fallback, and "*" is not a requestable language.
        assert!(parse_language("en-AU").is_none());
        assert!(parse_language("*").is_none());

        // Japanese's deprecated code is "jp", not "ja" — gogdl has no two-letter fallback rule, which
        // is precisely why the whole table has to be ported rather than approximated.
        assert_eq!(parse_language("jp").map(|l| l.0), Some("ja-JP"));
        assert!(parse_language("ja").is_none());

        // "*" on the DEPOT side is the language-neutral sentinel and matches every request.
        assert!(lang_matches(parse_language("jp").unwrap(), "*"));
        assert!(lang_matches(parse_language("en").unwrap(), "*"));

        // No alias collides with another row's code or name, so first-match-wins is unambiguous.
        assert_eq!(LANGUAGES.len(), 84, "the ported table must stay complete");
        for l in LANGUAGES {
            for d in l.2 {
                let hit = parse_language(d).expect("every alias resolves");
                assert_eq!(hit.0, l.0, "alias {d:?} must resolve to its own row");
            }
        }
    }

    #[test]
    fn case_collisions_are_caught_at_every_depth() {
        // gogdl folds EVERY path component against what is already on disk, so `Data/` and `data/`
        // become one directory holding both files while the plan carries two — the whole-path guard
        // this replaces never saw it.
        assert!(case_collision(&plan_of(&[("Data/a.dat", 1), ("data/b.dat", 1)], &[])).is_some());
        assert!(case_collision(&plan_of(&[("Game/Bin/x", 1), ("Game/BIN/y", 1)], &[])).is_some());
        // …including a directory-only entry colliding with a file's parent.
        assert!(case_collision(&plan_of(&[("Data/a.dat", 1)], &["DATA"])).is_some());
        assert!(case_collision(&plan_of(&[], &["Empty/Sub", "empty/SUB"])).is_some());
        // A plain filename collision is still caught.
        assert!(case_collision(&plan_of(&[("A.dat", 1), ("a.dat", 1)], &[])).is_some());
        // …and a tree with no collision is not flagged, including repeated identical prefixes.
        assert!(case_collision(&plan_of(&[("Data/a.dat", 1), ("Data/b.dat", 1)], &["Data"])).is_none());
        assert!(case_collision(&plan_of(&[("a", 1), ("b", 1)], &[])).is_none());
    }

    #[test]
    fn manifest_strictness_refuses_what_it_cannot_reproduce() {
        let md5 = "0123456789abcdef0123456789abcdef";
        let ok: Value = serde_json::json!({ "chunks": [ { "compressedMd5": md5, "md5": md5, "size": 7 } ] });
        assert_eq!(chunks_of(&ok, "f").unwrap().len(), 1);
        // An empty ARRAY is a legal zero-byte file…
        assert!(chunks_of(&serde_json::json!({ "chunks": [] }), "f").unwrap().is_empty());
        // …but an ABSENT key is a shape we have never seen; it used to plan as an empty file.
        assert!(chunks_of(&serde_json::json!({}), "f").is_err());
        // A missing/short md5 used to become "" and then PANIC in galaxy_path inside a worker thread.
        assert!(chunks_of(&serde_json::json!({ "chunks": [ { "md5": md5, "size": 7 } ] }), "f").is_err());
        assert!(chunks_of(
            &serde_json::json!({ "chunks": [ { "compressedMd5": "", "md5": md5, "size": 7 } ] }),
            "f"
        )
        .is_err());
        assert!(chunks_of(
            &serde_json::json!({ "chunks": [ { "compressedMd5": md5, "md5": md5, "size": 0 } ] }),
            "f"
        )
        .is_err());
        // A small-files-container item is ORDINARY as long as its own chunks cover what the container
        // declares — which is how every real one looks (32 of homeworld-rm's files, and its pinned hash
        // was computed from exactly these chunks). gogdl ignores `sfcRef` outright.
        let sfc = |size: u64| {
            serde_json::json!({
                "sfcRef": { "offset": 159, "size": size },
                "chunks": [ { "compressedMd5": md5, "md5": md5, "size": 907 } ]
            })
        };
        assert_eq!(chunks_of(&sfc(907), "f").unwrap().len(), 1);
        // …but a container that declares MORE than the chunks cover would mean the bytes come from the
        // container itself, which this planner never reads.
        assert!(chunks_of(&sfc(908), "f").is_err());
        assert!(chunks_of(&serde_json::json!({ "sfcRef": {}, "chunks": [] }), "f").is_err());
    }

    #[test]
    fn galaxy_path_errors_instead_of_slicing_blind() {
        let md5 = "0123456789abcdef0123456789abcdef";
        assert_eq!(galaxy_path(md5).unwrap(), format!("01/23/{md5}"));
        assert_eq!(galaxy_path("already/a/path").unwrap(), "already/a/path");
        assert!(galaxy_path("").is_err(), "this used to panic on &h[0..2]");
        assert!(galaxy_path("ab").is_err());
        assert!(galaxy_path("zzzz").is_err());
    }

    #[test]
    fn stored_gog_accounts_are_deterministic_and_selectable() {
        let root = std::env::temp_dir().join(format!(
            "propnix-gogcred-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        // Written in an order the filesystem is free to hand back either way round.
        for (who, tok) in [("zoe", "tok-z"), ("alice", "tok-a")] {
            let d = root.join("gog").join(who);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(
                d.join("galaxy_tokens.json"),
                format!("{{\"refresh_token\":\"{tok}\"}}"),
            )
            .unwrap();
        }

        // SORTED BY NAME, so a multi-account run tries them in the same order every time.
        let all = gog_credentials(&root, None).unwrap();
        assert_eq!(
            all.iter().map(|c| c.account.as_str()).collect::<Vec<_>>(),
            vec!["alice", "zoe"]
        );
        assert_eq!(all[0].refresh_token, "tok-a");

        // A named account narrows to exactly that one…
        let one = gog_credentials(&root, Some("zoe")).unwrap();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].refresh_token, "tok-z");

        // …and a name the store does not hold lists what it does, rather than silently using someone
        // else's account.
        let Err(e) = gog_credentials(&root, Some("nobody")) else {
            panic!("an absent account must be an error");
        };
        assert!(matches!(e, GogError::NoCredential(_)), "got {e:?}");
        let msg = e.to_string();
        assert!(msg.contains("alice") && msg.contains("zoe"), "got: {msg}");

        // An empty store is NoCredential, not NotOwned — different problem, different instruction.
        let empty = root.join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        assert!(matches!(
            gog_credentials(&empty, None),
            Err(GogError::NoCredential(_))
        ));

        // The legacy single-file layout still works, under a synthetic name so it stays selectable.
        std::fs::write(empty.join("galaxy_tokens.json"), "{\"refresh_token\":\"old\"}").unwrap();
        let legacy = gog_credentials(&empty, None).unwrap();
        assert_eq!(legacy.len(), 1);
        assert_eq!(legacy[0].refresh_token, "old");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_chunk_url_never_leaks_its_signed_path() {
        // secure_link's url_format can put signed parameters in PATH segments, so stripping the query
        // string is not enough.
        assert_eq!(
            redact_chunk("https://cdn.gog.com/token=abc123/expires=99/ab/cd/abcd"),
            "https://cdn.gog.com/<redacted>"
        );
        assert_eq!(redact_chunk("https://h/x?q=1"), "https://h/<redacted>");
    }
}
