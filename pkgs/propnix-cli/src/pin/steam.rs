//! Steam depots: read a manifest, plan the tree, stream the bytes.
//!
//! Reproduces byte-for-byte the tree `fetchSteamDepot` produces via DepotDownloader — which is
//! DepotDownloader's install dir minus its `.DepotDownloader/` bookkeeping — without writing the depot
//! to disk.
//!
//! WHAT NEEDS THE CM PROTOCOL, AND WHAT DOESN'T. Only three operations speak Steam's client protocol:
//! logging in, `GetDepotDecryptionKey`, and `GetManifestRequestCode`. The content-server list, the
//! manifest download and every chunk download are plain HTTPS. So steam-vent (async, tokio) runs only
//! the short control plane; the bulk transfer stays on blocking threads, where the measured throughput
//! lives.
//!
//! Note the depot key is required even to READ THE FILE LIST: live CDN manifests always ship with
//! `filenames_encrypted` set (the plaintext ones you see in a local `depotcache` were re-serialized by
//! a client). So unlike GOG, nothing here can be planned anonymously for an owned title.
//!
//! MATCHING DepotDownloader — RE-VERIFIED against the PINNED source (DepotDownloader 3.4.0, which links
//! SteamKit2 3.2.0; `DepotDownloader/ContentDownloader.cs` and `SteamKit2/Types/DepotManifest.cs`):
//!   * flag 0x40 Directory is checked FIRST, and is the ONLY flag that changes what gets created:
//!     `if (file.Flags.HasFlag(EDepotFileFlag.Directory)) Directory.CreateDirectory(...)`
//!     (ContentDownloader.cs:884-888), and the download pass filters those out
//!     (ContentDownloader.cs:920). A directory may be EMPTY and must still appear in the NAR.
//!   * flag 0x20 Executable is applied LAST and unconditionally from the flag — no size test, so a
//!     zero-byte file is chmod +x too (ContentDownloader.cs:1160-1168, PlatformUtilities.cs:12-29).
//!   * flag 0x200 Symlink is NEVER READ. DepotDownloader has no symlink support at all: SteamKit2
//!     parses `LinkTarget` (DepotManifest.cs:113,420) but DD's own ProtoManifest copy drops it
//!     (ProtoManifest.cs:40-47,171) and nothing calls File.CreateSymbolicLink. A Symlink-flagged entry
//!     therefore falls through to the ordinary file path and is materialized as a regular file of its
//!     declared size. So EVERY non-Directory entry is a regular file here — matching the fetcher
//!     exactly beats being more faithful to Steam than the fetcher is. (0x80 is CustomExecutable and
//!     means nothing here.) If DD ever grows symlink support, this comment is the tripwire.
//!   * Parent directories are created for every file even when the manifest never lists them — most
//!     manifests omit some. `nar::Node::insert` synthesizes them.
//!   * Files are pre-allocated to their declared size, so a range no chunk covers is a hole of zeros.
//!   * Manifest paths use '\' separators, normalized to '/' — and that is DD's ONLY normalization
//!     (DepotManifest.cs:25,133-140). It has no traversal guard whatsoever, so a path with an empty,
//!     `.` or `..` component escapes `-dir` and we could not reproduce it: we refuse instead.

use std::collections::BTreeMap;
use std::io::Read;

use crate::pin::nar;

/// EDepotFileFlag (SteamKit2 3.2.0, SteamLanguage.cs:2882-2895).
const F_EXECUTABLE: u32 = 0x20;
const F_DIRECTORY: u32 = 0x40;

/// Section magics inside a manifest (SteamKit2 DepotManifest.cs).
const MAGIC_PAYLOAD: u32 = 0x71F6_17D0;
const MAGIC_METADATA: u32 = 0x1F48_12BE;
const MAGIC_SIGNATURE: u32 = 0x1B81_B817;
const MAGIC_EOM: u32 = 0x32C4_15AB;

static ZERO: [u8; 1 << 16] = [0u8; 1 << 16];

/// `symmetric_decrypt_without_hmac` recovers the IV from the first AES block and PANICS on a shorter
/// input (`BytesMut::split_off(16)`), so every call site length-checks first.
const AES_BLOCK: usize = 16;
/// Smallest well-formed 'VZ' chunk container: a 12-byte header, then a 10-byte footer whose last two
/// bytes are "zv". The payload slice is `raw[12..len-10]`, which needs `len >= 22` to be a valid range.
const VZ_MIN: usize = 22;

#[derive(Debug)]
pub enum SteamError {
    /// No usable Steam credential in the store at all — its own variant, not a `NotOwned` substring,
    /// because the exit-code classifier reads the TYPE and the two need different instructions.
    NoCredential(String),
    /// The account does not own this depot, or the credential was rejected. NOT a failure: no-op.
    NotOwned(String),
    /// A construct we refuse to guess at rather than emit a possibly-wrong hash.
    Unsupported(String),
    Http(String),
    Parse(String),
}

impl std::fmt::Display for SteamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SteamError::NoCredential(m) => write!(f, "{m}"),
            SteamError::NotOwned(m) => write!(f, "not available to this Steam account: {m}"),
            SteamError::Unsupported(m) => write!(f, "refusing to hash: {m}"),
            SteamError::Http(m) => write!(f, "Steam request failed: {m}"),
            SteamError::Parse(m) => write!(f, "unexpected Steam response: {m}"),
        }
    }
}

impl std::error::Error for SteamError {}

type R<T> = Result<T, SteamError>;

/// A pooled agent for the plain-HTTPS half of Steam (appinfo, the content-server directory, manifests
/// and chunks).
///
/// The READ timeout is the point: NAR emission is strictly sequential, so one silently stalled
/// connection does not slow the hash down, it stops it — until CI's own 350-minute cap notices.
fn http_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .max_idle_connections(256)
        .max_idle_connections_per_host(256)
        .timeout_connect(std::time::Duration::from_secs(20))
        .timeout_read(std::time::Duration::from_secs(60))
        .build()
}

/// The same agent, shared by the one-shot metadata calls that used to go through bare `ureq::get`
/// (which builds a fresh, TIMEOUT-FREE agent per call).
fn meta_agent() -> &'static ureq::Agent {
    use std::sync::OnceLock;
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(http_agent)
}

// ───────────────────────────────────────────── credential ─────────────────────────────────────────
/// A Steam account name and its refresh token, read out of what `propnix cred add steam` stores.
#[derive(Clone)]
pub struct Credential {
    pub account: String,
    pub refresh_token: String,
}

/// Find `account.config` in the stored tar and pull (account, refresh token) out of it.
///
/// The file is DepotDownloader's `AccountSettingsStore`: **raw DEFLATE** (no zlib header — .NET's
/// `DeflateStream` uses windowBits -15) wrapping a protobuf-net message. protobuf-net encodes a
/// `Dictionary` as one length-delimited field per entry at the member's field number, each entry being
/// `field 1 = key, field 2 = value`. `LoginTokens` is member 4.
///
/// Rather than model the whole schema we walk the wire format and collect (string, string) pairs from
/// field 4, then keep only values shaped like a JWT. `ContentServerPenalty` (member 2) is not
/// mistakable for it: its entries carry a varint in field 2, not a string.
/// A LIST, not a single credential, because a propnix host may hold several Steam accounts and only one
/// of them owns a given depot — the caller tries each in turn, exactly as `fetchSteamDepot` does.
/// `want` (from `--steam-account` / `PROPNIX_STEAM_ACCOUNT`) narrows it to one; a name the store does
/// not hold is an error listing what it does.
///
/// Accounts come back in sorted-by-name order so a multi-account run is deterministic.
pub fn credentials_from_store(
    cred_dir: &std::path::Path,
    want_account: Option<&str>,
) -> R<Vec<Credential>> {
    let mut tars: Vec<std::path::PathBuf> = Vec::new();
    let steam = cred_dir.join("steam");
    if let Ok(rd) = std::fs::read_dir(&steam) {
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                tars.push(p.join("depotdownloader-store.tar"));
            } else if p.extension().map(|x| x == "tar").unwrap_or(false) {
                tars.push(p); // flat CI layout: <cred>/steam/store.tar
            }
        }
    }
    tars.retain(|p| p.exists());
    tars.sort();
    if tars.is_empty() {
        return Err(SteamError::NoCredential(format!(
            "no Steam credential under {} — run `propnix cred add steam`",
            cred_dir.display()
        )));
    }

    let mut all: BTreeMap<String, String> = BTreeMap::new();
    for t in &tars {
        let f = match std::fs::File::open(t) {
            Ok(f) => f,
            // A store from before user-ownership holds root-owned tokens: converge this one onto the
            // store contract (a one-off, sudo-escalated chown) and retry.
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                crate::cred::store::repair_unreadable_token(cred_dir, t)
                    .map_err(SteamError::NoCredential)?;
                std::fs::File::open(t).map_err(|e| SteamError::Parse(format!("{}: {e}", t.display())))?
            }
            Err(e) => return Err(SteamError::Parse(format!("{}: {e}", t.display()))),
        };
        let mut ar = tar::Archive::new(f);
        let entries = ar
            .entries()
            .map_err(|e| SteamError::Parse(format!("{}: {e}", t.display())))?;
        for entry in entries {
            let mut entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };
            let is_cfg = entry
                .path()
                .map(|p| p.file_name().map(|n| n == "account.config").unwrap_or(false))
                .unwrap_or(false);
            if !is_cfg {
                continue;
            }
            let mut raw = Vec::new();
            entry
                .read_to_end(&mut raw)
                .map_err(|e| SteamError::Parse(format!("reading account.config: {e}")))?;
            let mut plain = Vec::new();
            flate2::read::DeflateDecoder::new(&raw[..])
                .read_to_end(&mut plain)
                .map_err(|_| {
                    SteamError::Parse(
                        "account.config did not inflate — the stored credential is truncated or corrupt \
                         (if it came from a CI secret, the base64 did not round-trip)"
                            .into(),
                    )
                })?;
            for (k, v) in string_pairs_in_field(&plain, 4) {
                all.insert(k, v);
            }
        }
    }

    // BTreeMap: sorted by account name, so the try-all order is deterministic.
    let jwts: BTreeMap<&String, &String> = all.iter().filter(|(_, v)| looks_like_jwt(v)).collect();
    if jwts.is_empty() {
        return Err(SteamError::NoCredential(
            "the stored Steam credential holds no login token — re-run `propnix cred add steam` \
             (the login must be done with -remember-password for a token to be persisted)"
                .into(),
        ));
    }
    if let Some(w) = want_account {
        if !jwts.contains_key(&w.to_string()) {
            let have: Vec<&str> = jwts.keys().map(|k| k.as_str()).collect();
            return Err(SteamError::NoCredential(format!(
                "the credential holds no Steam account named {w:?} (it holds: {}) — pass \
                 --steam-account with one of those, or unset PROPNIX_STEAM_ACCOUNT to try them all",
                have.join(", ")
            )));
        }
    }

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut out = Vec::new();
    let mut expired: Vec<String> = Vec::new();
    for (account, token) in jwts {
        if want_account.is_some_and(|w| w != account) {
            continue;
        }
        // steam-vent does not check expiry, so we must: a stale token otherwise surfaces as an opaque
        // login failure. An expired token is an ownership-class skip, not a hard stop — a second
        // account may still be good — unless it is the only one, which the empty check below reports.
        if let Some(exp) = jwt_expiry(token) {
            if exp != 0 && now >= exp {
                expired.push(account.clone());
                continue;
            }
        }
        out.push(Credential {
            account: account.clone(),
            refresh_token: token.clone(),
        });
    }
    if out.is_empty() {
        return Err(SteamError::NotOwned(format!(
            "every stored Steam refresh token has expired ({}) — re-run `propnix cred add steam` \
             (and re-set the CI secret from the new tar)",
            expired.join(", ")
        )));
    }
    for a in &expired {
        eprintln!("  Steam account {a:?}: stored refresh token has expired — skipping it");
    }
    Ok(out)
}

/// Is this string a JWT? We are scanning an UNKNOWN protobuf for the token, so shape alone is not
/// enough — require the payload segment to actually base64url-decode into a JSON object, or a
/// coincidentally dotted string could be mistaken for the credential.
fn looks_like_jwt(s: &str) -> bool {
    use base64::Engine;
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() != 3 || parts.iter().any(|p| p.is_empty()) {
        return false;
    }
    let Ok(raw) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(parts[1]) else {
        return false;
    };
    matches!(
        serde_json::from_slice::<serde_json::Value>(&raw),
        Ok(serde_json::Value::Object(_))
    )
}

fn jwt_expiry(jwt: &str) -> Option<u64> {
    use base64::Engine;
    let payload = jwt.split('.').nth(1)?;
    let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .ok()?;
    let v: serde_json::Value = serde_json::from_slice(&raw).ok()?;
    v.get("exp").and_then(serde_json::Value::as_u64)
}

/// Walk protobuf wire format and collect (string, string) pairs from length-delimited entries at
/// `field`. Anything that does not parse as such an entry is skipped.
fn string_pairs_in_field(buf: &[u8], field: u32) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (f, bytes) in top_level_fields(buf) {
        if f != field {
            continue;
        }
        let mut k: Option<String> = None;
        let mut v: Option<String> = None;
        for (sub, sb) in top_level_fields(&bytes) {
            match sub {
                1 => k = String::from_utf8(sb.to_vec()).ok(),
                2 => v = String::from_utf8(sb.to_vec()).ok(),
                _ => {}
            }
        }
        if let (Some(k), Some(v)) = (k, v) {
            out.push((k, v));
        }
    }
    out
}

/// Yield (field number, payload) for every LENGTH-DELIMITED field; skip other wire types correctly so
/// the walk stays in sync.
fn top_level_fields(buf: &[u8]) -> Vec<(u32, Vec<u8>)> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < buf.len() {
        let (tag, n) = match varint(&buf[i..]) {
            Some(x) => x,
            None => break,
        };
        i += n;
        let field = (tag >> 3) as u32;
        match tag & 7 {
            0 => match varint(&buf[i..]) {
                Some((_, n)) => i += n,
                None => break,
            },
            1 => i += 8,
            5 => i += 4,
            2 => {
                let (len, n) = match varint(&buf[i..]) {
                    Some(x) => x,
                    None => break,
                };
                i += n;
                let end = match i.checked_add(len as usize) {
                    Some(e) if e <= buf.len() => e,
                    _ => break,
                };
                out.push((field, buf[i..end].to_vec()));
                i = end;
            }
            _ => break,
        }
    }
    out
}

fn varint(b: &[u8]) -> Option<(u64, usize)> {
    let mut v = 0u64;
    let mut shift = 0;
    for (i, byte) in b.iter().enumerate().take(10) {
        v |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Some((v, i + 1));
        }
        shift += 7;
    }
    None
}

// ─────────────────────────────────────────── control plane ────────────────────────────────────────
#[derive(Clone)]
pub enum Auth {
    Anonymous,
    Account(Credential),
}

pub struct Control {
    pub depot_key: [u8; 32],
    /// manifest id -> request code. Codes are single-use and short-lived, so they are fetched together
    /// immediately before use and never persisted.
    pub codes: BTreeMap<u64, u64>,
    pub hosts: Vec<String>,
}

/// Log in, fetch the depot key and a manifest request code, and list content servers.
///
/// Request codes are single-use and short-lived, so this runs immediately before the manifest GET and
/// the code is never persisted.
///
/// Retried as a WHOLE on a transport failure: the session is not resumable, so a dropped socket part way
/// through means logging in again from scratch. A refusal (bad credentials, no depot key, no request
/// code) is Steam's considered answer and is returned at once.
pub fn control(app_id: u32, depot_id: u32, manifest_ids: &[u64], branch: &str, auth: Auth) -> R<Control> {
    crate::pin::retry::with_retry(
        &format!("Steam control plane for app {app_id} depot {depot_id}"),
        &crate::pin::retry::METADATA,
        |e: &SteamError| matches!(e, SteamError::Http(_)),
        || control_once(app_id, depot_id, manifest_ids, branch, auth.clone()),
    )
}

fn control_once(
    app_id: u32,
    depot_id: u32,
    manifest_ids: &[u64],
    branch: &str,
    auth: Auth,
) -> R<Control> {
    use steam_vent::{Connection, ConnectionTrait, ServerList};
    use steam_vent_proto_steam::steammessages_clientserver_2::{
        CMsgClientGetDepotDecryptionKey, CMsgClientGetDepotDecryptionKeyResponse,
    };
    use steam_vent_proto_steam::steammessages_contentsystem_steamclient::CContentServerDirectory_GetManifestRequestCode_Request;

    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .build()
        .map_err(|e| SteamError::Http(format!("tokio: {e}")))?;

    let (depot_key, codes, cell_id): ([u8; 32], BTreeMap<u64, u64>, u32) = rt.block_on(async move {
        let servers = ServerList::discover()
            .await
            .map_err(|e| SteamError::Http(format!("server discovery: {e}")))?;
        let conn = match &auth {
            Auth::Anonymous => Connection::anonymous(&servers).await,
            Auth::Account(c) => Connection::access(&servers, &c.account, &c.refresh_token).await,
        }
        .map_err(|e| match e {
            // A dropped socket during login is NOT a credential problem. Telling the user to re-run
            // `propnix cred add steam` because their wifi blinked wastes their time, and — worse — the
            // multi-account loop would take it as "this account doesn't own it" and move on. Only a
            // genuine refusal (invalid credentials, Steam Guard, an access-token error) says that.
            steam_vent::ConnectionError::Network(n) => {
                SteamError::Http(format!("Steam login transport failed: {n}"))
            }
            other => SteamError::NotOwned(format!(
                "Steam login failed ({other}) — if this persists, re-run `propnix cred add steam` and \
                 re-set the CI secret"
            )),
        })?;

        let kreq = CMsgClientGetDepotDecryptionKey {
            depot_id: Some(depot_id),
            app_id: Some(app_id),
            ..Default::default()
        };
        let kresp: CMsgClientGetDepotDecryptionKeyResponse = conn
            .job(kreq)
            .await
            .map_err(|e| SteamError::Http(format!("depot key request: {e}")))?;
        if kresp.eresult() != 1 {
            return Err(SteamError::NotOwned(format!(
                "Steam refused the decryption key for depot {depot_id} (eresult {}) — the account \
                 most likely does not own app {app_id}",
                kresp.eresult()
            )));
        }
        let key_vec = kresp
            .depot_encryption_key
            .ok_or_else(|| SteamError::Parse("depot key response carried no key".into()))?;
        let depot_key: [u8; 32] = key_vec.as_slice().try_into().map_err(|_| {
            SteamError::Parse(format!("depot key is {} bytes, want 32", key_vec.len()))
        })?;

        let mut codes = BTreeMap::new();
        for manifest_id in manifest_ids {
            let creq = CContentServerDirectory_GetManifestRequestCode_Request {
                app_id: Some(app_id),
                depot_id: Some(depot_id),
                manifest_id: Some(*manifest_id),
                app_branch: Some(branch.to_owned()),
                ..Default::default()
            };
            let cresp = conn
                .service_method(creq)
                .await
                .map_err(|e| SteamError::Http(format!("manifest request code: {e}")))?;
            let code = cresp.manifest_request_code();
            if code == 0 {
                return Err(SteamError::NotOwned(format!(
                    "Steam returned no manifest request code for {app_id}/{depot_id} manifest \
                     {manifest_id} — the manifest may have been withdrawn, or the account lacks access"
                )));
            }
            codes.insert(*manifest_id, code);
        }

        Ok((depot_key, codes, conn.cell_id()))
    })?;
    let hosts = content_hosts(cell_id)?;
    Ok(Control {
        depot_key,
        codes,
        hosts,
    })
}

/// The content-server directory is a plain unauthenticated GET, so it needs no CM connection and no
/// async client — keeping reqwest out of our own code even though steam-vent pulls it in.
pub fn content_hosts(cell_id: u32) -> R<Vec<String>> {
    #[derive(serde::Deserialize)]
    struct Outer {
        response: Inner,
    }
    #[derive(serde::Deserialize)]
    struct Inner {
        servers: Vec<Server>,
    }
    #[derive(serde::Deserialize)]
    struct Server {
        #[serde(rename = "type")]
        kind: String,
        host: String,
        #[serde(default)]
        vhost: String,
        #[serde(default)]
        https_support: String,
        #[serde(default)]
        load: u32,
        #[serde(default)]
        weighted_load: u32,
    }
    let url = format!(
        "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id={cell_id}"
    );
    let body = crate::pin::retry::with_retry(
        "content server directory",
        &crate::pin::retry::METADATA,
        |_: &SteamError| true, // every failure here is the fetch itself; parsing happens below
        || {
            meta_agent()
                .get(&url)
                .call()
                .map_err(|e| SteamError::Http(format!("content server directory: {e}")))?
                .into_string()
                .map_err(|e| SteamError::Http(format!("content server directory: {e}")))
        },
    )?;
    let mut servers: Vec<Server> = serde_json::from_str::<Outer>(&body)
        .map_err(|e| SteamError::Parse(format!("content server directory: {e}")))?
        .response
        .servers;
    servers.retain(|s| (s.kind == "SteamCache" || s.kind == "CDN") && s.https_support != "none");
    servers.sort_by_key(|s| (s.weighted_load, s.load));
    let hosts: Vec<String> = servers
        .into_iter()
        .map(|s| if s.vhost.is_empty() { s.host } else { s.vhost })
        .collect();
    if hosts.is_empty() {
        return Err(SteamError::Http("Steam offered no content servers".into()));
    }
    Ok(hosts)
}

// ───────────────────────────────────────────── manifest ───────────────────────────────────────────
#[derive(Clone)]
pub struct ChunkRef {
    pub sha: [u8; 20],
    pub offset: u64,
    pub cb_original: u32,
}

#[derive(Clone)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    pub executable: bool,
    pub chunks: Vec<ChunkRef>,
}

/// Download and decode a manifest. The body is a ZIP holding exactly one deflate entry named "z";
/// inside it, magic-delimited protobuf sections.
pub fn fetch_manifest(
    agent: &ureq::Agent,
    hosts: &[String],
    depot_id: u32,
    manifest_id: u64,
    request_code: u64,
    depot_key: &[u8; 32],
) -> R<(Vec<FileEntry>, u32)> {
    // Every host, then the whole sweep again after a pause: a manifest fetch that fails because the
    // network blinked should not fail the run before any content has been transferred. A DECODE failure
    // is not retried — the bytes arrived and we could not make sense of them, which more hosts will not
    // fix (and `read_to_end` failing IS transport, so it stays inside the retry).
    crate::pin::retry::with_retry(
        &format!("manifest {manifest_id}"),
        &crate::pin::retry::METADATA,
        |e: &SteamError| matches!(e, SteamError::Http(_)),
        || {
            let mut last = String::new();
            for host in hosts.iter().take(6) {
                let url =
                    format!("https://{host}/depot/{depot_id}/manifest/{manifest_id}/5/{request_code}");
                match agent.get(&url).call() {
                    Ok(resp) => {
                        let mut body = Vec::new();
                        match resp.into_reader().read_to_end(&mut body) {
                            Ok(_) => return decode_manifest(&body, depot_key),
                            Err(e) => last = format!("reading manifest: {e}"),
                        }
                    }
                    Err(e) => last = e.to_string(),
                }
            }
            Err(SteamError::Http(format!(
                "could not download manifest {manifest_id} from any of {} hosts: {last}",
                hosts.len().min(6)
            )))
        },
    )
}

fn decode_manifest(zip: &[u8], depot_key: &[u8; 32]) -> R<(Vec<FileEntry>, u32)> {
    let raw = unzip_single_deflate_entry(zip)?;
    let mut payload: Option<Vec<u8>> = None;
    let mut metadata: Option<Vec<u8>> = None;
    let mut i = 0usize;
    while i + 4 <= raw.len() {
        let magic = u32::from_le_bytes(raw[i..i + 4].try_into().unwrap());
        i += 4;
        if magic == MAGIC_EOM {
            break; // the terminator carries NO length field
        }
        if i + 4 > raw.len() {
            return Err(SteamError::Parse("manifest section header is truncated".into()));
        }
        let len = u32::from_le_bytes(raw[i..i + 4].try_into().unwrap()) as usize;
        i += 4;
        let end = i
            .checked_add(len)
            .filter(|e| *e <= raw.len())
            .ok_or_else(|| SteamError::Parse("manifest section length overruns the body".into()))?;
        match magic {
            MAGIC_PAYLOAD => payload = Some(raw[i..end].to_vec()),
            MAGIC_METADATA => metadata = Some(raw[i..end].to_vec()),
            MAGIC_SIGNATURE => {}
            other => {
                return Err(SteamError::Parse(format!(
                    "unknown manifest section magic {other:#x}"
                )))
            }
        }
        i = end;
    }
    let payload = payload.ok_or_else(|| SteamError::Parse("manifest has no payload section".into()))?;
    let metadata =
        metadata.ok_or_else(|| SteamError::Parse("manifest has no metadata section".into()))?;

    use protobuf::Message;
    use steam_vent_proto_steam::content_manifest::{ContentManifestMetadata, ContentManifestPayload};
    let payload = ContentManifestPayload::parse_from_bytes(&payload)
        .map_err(|e| SteamError::Parse(format!("manifest payload: {e}")))?;
    let metadata = ContentManifestMetadata::parse_from_bytes(&metadata)
        .map_err(|e| SteamError::Parse(format!("manifest metadata: {e}")))?;
    let encrypted = metadata.filenames_encrypted();

    let mut out = Vec::new();
    for m in payload.mappings {
        let raw_name = m.filename();
        let name = if encrypted {
            decrypt_filename(raw_name, depot_key)?
        } else {
            raw_name.trim_end_matches('\0').to_string()
        };
        // DepotDownloader's ONLY normalization is the separator swap (SteamKit2 DepotManifest.cs:139).
        // The trailing-separator trim is ours and is safe — Directory.CreateDirectory and Path.Combine
        // both ignore one — but a LEADING separator is not: .NET's Path.Combine treats a rooted second
        // argument as absolute and discards `-dir` entirely, so DD would write outside the tree we are
        // modelling. `check_path` refuses that, and `..`/`.`, rather than trimming them away.
        let path = name.replace('\\', "/").trim_end_matches('/').to_string();
        if path.is_empty() {
            continue; // the depot root itself; DD's Path.Combine yields -dir unchanged
        }
        check_path(&path)?;
        let flags = m.flags();
        let size = m.size();
        let mut chunks: Vec<ChunkRef> = Vec::with_capacity(m.chunks.len());
        for c in &m.chunks {
            // A short sha used to be silently zero-filled, which turns into a confusing sha1 mismatch
            // thousands of chunks later instead of an error naming the file.
            let s = c.sha();
            let sha: [u8; 20] = s.try_into().map_err(|_| {
                SteamError::Parse(format!(
                    "{path:?}: a chunk id is {} bytes, want 20 — this manifest is not the shape we parse",
                    s.len()
                ))
            })?;
            chunks.push(ChunkRef {
                sha,
                offset: c.offset(),
                cb_original: c.cb_original(),
            });
        }

        // Directory FIRST and Executable LAST, exactly as ContentDownloader.cs:884/920/1160 does — and
        // nothing else. The Symlink flag is never read by DepotDownloader, so a Symlink-flagged entry
        // is an ordinary regular file here, chunks and exec bit included.
        if flags & F_DIRECTORY != 0 {
            out.push(FileEntry {
                path,
                size: u64::MAX, // sentinel: directory, handled in tree()
                executable: false,
                chunks: Vec::new(),
            });
            continue;
        }
        out.push(FileEntry {
            path,
            size,
            executable: flags & F_EXECUTABLE != 0,
            chunks,
        });
    }
    Ok((out, metadata.creation_time()))
}

/// DepotDownloader's bookkeeping directory (`ContentDownloader.CONFIG_DIR`), which `fetchSteamDepot`
/// deletes before publishing. Hashing a depot entry under it would guarantee divergence.
const DD_CONFIG_DIR: &str = ".DepotDownloader";

/// Refuse a manifest path we could not reproduce. DepotDownloader has NO path validation at all — it
/// hands `Path.Combine(installDir, FileName)` straight to the filesystem — so anything that escapes
/// `-dir`, or that resolves to a different place than the literal components suggest, would make our
/// planned tree and the real one disagree.
fn check_path(path: &str) -> R<()> {
    for c in path.split('/') {
        if c.is_empty() || c == "." || c == ".." {
            return Err(SteamError::Unsupported(format!(
                "manifest path {path:?} has a {} component; DepotDownloader joins it to -dir with no \
                 traversal guard, so the real tree would not be the one planned here",
                if c.is_empty() { "empty".to_string() } else { format!("{c:?}") }
            )));
        }
    }
    if path == DD_CONFIG_DIR || path.starts_with(&format!("{DD_CONFIG_DIR}/")) {
        return Err(SteamError::Unsupported(format!(
            "manifest path {path:?} is inside {DD_CONFIG_DIR}/, which the fetcher deletes before \
             publishing — hashing it would guarantee a mismatch"
        )));
    }
    Ok(())
}

/// The ZIP always holds exactly one deflate entry named "z", so parse the local header directly rather
/// than depending on a zip crate.
fn unzip_single_deflate_entry(b: &[u8]) -> R<Vec<u8>> {
    if b.len() < 30 || &b[0..4] != b"PK\x03\x04" {
        return Err(SteamError::Parse(
            "manifest body is not a ZIP (no PK\\x03\\x04)".into(),
        ));
    }
    let method = u16::from_le_bytes(b[8..10].try_into().unwrap());
    let comp_size = u32::from_le_bytes(b[18..22].try_into().unwrap()) as usize;
    let name_len = u16::from_le_bytes(b[26..28].try_into().unwrap()) as usize;
    let extra_len = u16::from_le_bytes(b[28..30].try_into().unwrap()) as usize;
    // Header-declared lengths are attacker/corruption controlled; a truncated body would otherwise
    // panic slicing at `start`.
    let start = 30usize
        .checked_add(name_len)
        .and_then(|n| n.checked_add(extra_len))
        .filter(|s| *s <= b.len())
        .ok_or_else(|| {
            SteamError::Parse(
                "ZIP local header declares a name/extra length past the end of the body".into(),
            )
        })?;
    if method != 8 {
        return Err(SteamError::Parse(format!(
            "manifest ZIP entry uses compression method {method}, expected 8 (deflate)"
        )));
    }
    // A zero size would mean a streaming entry with a trailing data descriptor; take the rest.
    let end = if comp_size == 0 {
        b.len()
    } else {
        (start + comp_size).min(b.len())
    };
    let mut out = Vec::new();
    flate2::read::DeflateDecoder::new(&b[start..end])
        .read_to_end(&mut out)
        .map_err(|e| SteamError::Parse(format!("inflating the manifest: {e}")))?;
    Ok(out)
}

/// base64 -> AES-256-ECB over the first block to recover the IV -> AES-256-CBC + PKCS7, then strip the
/// single trailing NUL. `symmetric_decrypt_without_hmac` is exactly that layout.
fn decrypt_filename(b64: &str, key: &[u8; 32]) -> R<String> {
    use base64::Engine;
    // The field holds MIME-style base64: wrapped at 64 columns, with a trailing newline. Strip all
    // whitespace rather than just trimming the end — short names fit one line and hide the problem,
    // longer ones do not.
    let compact: String = b64.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    let ct = base64::engine::general_purpose::STANDARD
        .decode(&compact)
        .map_err(|e| SteamError::Parse(format!("filename base64: {e}")))?;
    // `symmetric_decrypt_without_hmac` does `split_off(16)` to recover the IV block and PANICS on a
    // shorter input; a truncated CDN body must be an error, not an abort.
    if ct.len() < AES_BLOCK {
        return Err(SteamError::Parse(format!(
            "an encrypted filename is {} bytes, too short to carry an IV block",
            ct.len()
        )));
    }
    let plain = steam_vent_crypto::symmetric_decrypt_without_hmac(
        bytes::BytesMut::from(&ct[..]),
        key,
    )
    .map_err(|e| SteamError::Parse(format!("filename decryption: {e}")))?;
    let s = plain.strip_suffix(&[0u8]).unwrap_or(&plain[..]);
    String::from_utf8(s.to_vec()).map_err(|e| SteamError::Parse(format!("filename utf8: {e}")))
}

// ─────────────────────────────────────────────── tree ─────────────────────────────────────────────
/// Build the NAR tree. Payload is an index into `files`. Directory entries carry the `u64::MAX`
/// sentinel set by `decode_manifest`.
pub fn tree(files: &[FileEntry]) -> Result<nar::Node<usize>, Box<dyn std::error::Error>> {
    let mut root: nar::Node<usize> = nar::Node::dir();
    // Directories first, so an explicit entry can never lose to an implicitly created parent.
    for f in files.iter().filter(|f| f.size == u64::MAX) {
        let parts: Vec<Vec<u8>> = f.path.split('/').map(|s| s.as_bytes().to_vec()).collect();
        root.insert(&parts, nar::Node::dir())?;
    }
    for (idx, f) in files.iter().enumerate() {
        if f.size == u64::MAX {
            continue;
        }
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

// ────────────────────────────────────────── chunk transport ───────────────────────────────────────
pub struct ChunkSource {
    pub agent: ureq::Agent,
    pub hosts: Vec<String>,
    pub depot_id: u32,
    pub key: [u8; 32],
    rr: std::sync::atomic::AtomicUsize,
}

impl ChunkSource {
    pub fn new(agent: ureq::Agent, hosts: Vec<String>, depot_id: u32, key: [u8; 32]) -> Self {
        Self {
            agent,
            hosts,
            depot_id,
            key,
            rr: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    /// One chunk: GET, decrypt, decompress, verify. The chunk's id IS sha1 of the plaintext, so the
    /// integrity check is free and end-to-end.
    ///
    /// Retried patiently, rotating hosts as it goes (see `pin::retry`). A depot hash runs for hours and
    /// cannot be resumed, so a dropped connection must not discard it; and every failure here is
    /// transport-shaped — Steam's considered refusals (no depot key, no request code) all happened in
    /// `control()` before a byte moved.
    pub fn get(&self, c: &ChunkRef) -> Result<Vec<u8>, String> {
        let hex: String = c.sha.iter().map(|b| format!("{b:02x}")).collect();
        let label = format!("chunk {hex}");
        let mut attempt = 0usize;
        crate::pin::retry::with_retry(&label, &crate::pin::retry::CONTENT, |_: &String| true, || {
            let i = self
                .rr
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                .wrapping_add(attempt);
            attempt += 1;
            let host = &self.hosts[i % self.hosts.len()];
            let url = format!("https://{host}/depot/{}/chunk/{hex}", self.depot_id);
            self.fetch_one(&url, c, &hex)
        })
        .map_err(|e| format!("{label}: {e}"))
    }

    fn fetch_one(&self, url: &str, c: &ChunkRef, hex: &str) -> Result<Vec<u8>, String> {
        let resp = self.agent.get(url).call().map_err(|e| e.to_string())?;
        let mut ct = Vec::new();
        resp.into_reader()
            .read_to_end(&mut ct)
            .map_err(|e| e.to_string())?;
        // See `decrypt_filename`: the decryptor panics on anything shorter than one AES block, and a
        // panic in a prefetch worker is a HANG, not a failure.
        if ct.len() < AES_BLOCK {
            return Err(format!("truncated chunk body ({} bytes)", ct.len()));
        }
        let plain = steam_vent_crypto::symmetric_decrypt_without_hmac(
            bytes::BytesMut::from(&ct[..]),
            &self.key,
        )
        .map_err(|e| format!("decrypt: {e}"))?;
        let data = decompress_chunk(&plain, c.cb_original as usize)?;
        use sha1::Digest;
        let got = sha1::Sha1::digest(&data);
        if got.as_slice() != c.sha {
            return Err(format!("sha1 mismatch (chunk id {hex})"));
        }
        Ok(data)
    }
}

/// Steam wraps each chunk in one of three independently decodable containers.
fn decompress_chunk(raw: &[u8], expect: usize) -> Result<Vec<u8>, String> {
    let out = if raw.len() >= 8 && &raw[0..4] == b"VSZa" {
        // Current format: 'VSZa' + CRC, a raw zstd frame at offset 8, then a footer ending in 'zsv'.
        if !raw.ends_with(b"zsv") {
            return Err(format!("VSZa footer is {:?}", &raw[raw.len().saturating_sub(3)..]));
        }
        // Read EXACTLY the declared size rather than to end-of-input: the zstd frame is followed by
        // a footer (<crc><original size><reserved> then "zsv"), which decode_all would trip over.
        let mut dec = zstd::stream::read::Decoder::new(&raw[8..])
            .map_err(|e| format!("zstd init: {e}"))?;
        let mut o = vec![0u8; expect];
        dec.read_exact(&mut o).map_err(|e| format!("zstd: {e}"))?;
        o
    } else if raw.len() >= VZ_MIN && &raw[0..2] == b"VZ" {
        // Legacy: raw LZMA1. lzma-rs wants a .lzma header, so synthesize one from the 5 property
        // bytes plus the known output size. VZ_MIN, not 12: the payload slice below is
        // `raw[12..raw.len()-10]`, so a 12..21-byte body would slice with start > end and panic.
        if !raw.ends_with(b"zv") {
            return Err("VZ footer is not 'zv'".into());
        }
        let mut framed = Vec::with_capacity(13 + raw.len());
        framed.extend_from_slice(&raw[7..12]);
        framed.extend_from_slice(&(expect as u64).to_le_bytes());
        framed.extend_from_slice(&raw[12..raw.len() - 10]);
        let mut cur = std::io::Cursor::new(framed);
        let mut o = Vec::new();
        lzma_rs::lzma_decompress(&mut cur, &mut o).map_err(|e| format!("lzma: {e}"))?;
        o
    } else {
        let mut o = Vec::new();
        // A bare zip container.
        unzip_single_deflate_entry(raw)
            .map(|v| o = v)
            .map_err(|e| e.to_string())?;
        o
    };
    if out.len() != expect {
        return Err(format!(
            "chunk decoded to {} bytes, manifest says {expect}",
            out.len()
        ));
    }
    Ok(out)
}

/// Stream one file's bytes in offset order, zero-filling any range no chunk covers.
///
/// DepotDownloader pre-allocates every file to its declared size, so an uncovered range is a hole of
/// zeros — but an overlap or an overrun means our model of the manifest is wrong, and we fail rather
/// than emit a wrong hash.
pub fn write_file<W: std::io::Write + ?Sized>(
    f: &FileEntry,
    mut next: impl FnMut() -> Result<Vec<u8>, String>,
    out: &mut W,
) -> Result<(), String> {
    let mut ordered: Vec<&ChunkRef> = f.chunks.iter().collect();
    ordered.sort_by_key(|c| c.offset);
    let mut pos = 0u64;
    for c in ordered {
        if c.offset < pos {
            return Err(format!("{}: chunks overlap at offset {}", f.path, c.offset));
        }
        while pos < c.offset {
            let n = ((c.offset - pos) as usize).min(ZERO.len());
            out.write_all(&ZERO[..n]).map_err(|e| e.to_string())?;
            pos += n as u64;
        }
        let data = next()?;
        out.write_all(&data).map_err(|e| e.to_string())?;
        pos += data.len() as u64;
    }
    if pos > f.size {
        return Err(format!(
            "{}: chunks cover {pos} bytes, past the declared size {}",
            f.path, f.size
        ));
    }
    while pos < f.size {
        let n = ((f.size - pos) as usize).min(ZERO.len());
        out.write_all(&ZERO[..n]).map_err(|e| e.to_string())?;
        pos += n as u64;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jwt_expiry_is_read_from_the_payload() {
        // {"exp":1234567890} as base64url, with a dummy header and signature.
        let jwt = "eyJhbGciOiJFZERTQSJ9.eyJleHAiOjEyMzQ1Njc4OTB9.sig";
        assert_eq!(jwt_expiry(jwt), Some(1234567890));
        assert!(looks_like_jwt(jwt));
        assert!(!looks_like_jwt("not-a-jwt"));
        assert!(!looks_like_jwt("ey.only.two")); // right shape, but the payload is not JSON
    }

    #[test]
    fn protobuf_walk_finds_map_entries_and_skips_varint_valued_ones() {
        // field 4 (LoginTokens): {key:"alice", value:"tok"}      -> collected
        // field 2 (ContentServerPenalty): {key:"cache1", value:7} -> value is a varint, so skipped
        let mut b = Vec::new();
        let entry4 = {
            let mut e = Vec::new();
            e.push(0x0A);
            e.push(5);
            e.extend_from_slice(b"alice");
            e.push(0x12);
            e.push(3);
            e.extend_from_slice(b"tok");
            e
        };
        b.push(0x22); // field 4, wire type 2
        b.push(entry4.len() as u8);
        b.extend_from_slice(&entry4);
        let entry2 = {
            let mut e = Vec::new();
            e.push(0x0A);
            e.push(6);
            e.extend_from_slice(b"cache1");
            e.push(0x10); // field 2, VARINT
            e.push(7);
            e
        };
        b.push(0x12); // field 2, wire type 2
        b.push(entry2.len() as u8);
        b.extend_from_slice(&entry2);

        let got = string_pairs_in_field(&b, 4);
        assert_eq!(got, vec![("alice".to_string(), "tok".to_string())]);
        // The penalty entry has no string in field 2, so it yields nothing even if asked for.
        assert!(string_pairs_in_field(&b, 2).is_empty());
    }

    #[test]
    fn symlink_flagged_entries_become_ordinary_regular_files() {
        // DepotDownloader 3.4.0 never reads the Symlink flag (verified in ContentDownloader.cs: the
        // only flags it branches on are Directory and Executable), so such an entry is materialized as
        // a plain file of its declared size — never a NAR symlink node.
        let files = vec![FileEntry {
            path: "link".into(),
            size: 0,
            executable: false,
            chunks: vec![],
        }];
        let t = tree(&files).unwrap();
        let (sri, stats) = nar::nar_hash(&t, |_, _| Ok(())).unwrap();
        assert_eq!(stats.files, 1);
        assert_eq!(stats.links, 0, "must NOT be a NAR symlink node");
        assert!(sri.starts_with("sha256-"));
    }

    #[test]
    fn unreproducible_manifest_paths_are_refused() {
        // DepotDownloader joins the manifest path to -dir with NO traversal guard, so any of these
        // would put bytes somewhere our planned tree does not model.
        assert!(check_path("Game/Data/x.dat").is_ok());
        assert!(check_path("/rooted").is_err(), ".NET Path.Combine discards -dir for a rooted path");
        assert!(check_path("a//b").is_err());
        assert!(check_path("../escape").is_err());
        assert!(check_path("a/./b").is_err());
        assert!(check_path("a/../b").is_err());
        // The fetcher deletes this dir before publishing, so a depot entry inside it can never match.
        assert!(check_path(".DepotDownloader").is_err());
        assert!(check_path(".DepotDownloader/depot.config").is_err());
        assert!(check_path(".DepotDownloaderish/ok").is_ok(), "prefix match only, not substring");
    }

    #[test]
    fn appinfo_is_parsed_per_branch() {
        let body = r#"{"data":{"367520":{"depots":{
            "367521":{"manifests":{"public":{"gid":"111"},"beta":{"gid":"222"}},
                      "config":{"oslist":"windows"}},
            "367523":{"manifests":{"public":{"gid":"333"}},"config":{"oslist":"linux"},
                      "dlcappid":"999"},
            "branches":{"public":{"buildid":"18000000"},"beta":{"buildid":"18500000"}},
            "baselanguages":"english"
        }}}}"#;
        let pubinfo = parse_app_info(body, 367520, "public").unwrap();
        assert_eq!(pubinfo.build_id, "18000000");
        assert_eq!(pubinfo.depots[&367521].gid, "111");
        assert_eq!(pubinfo.depots[&367523].gid, "333");
        assert_eq!(pubinfo.depots[&367523].dlc_app, Some(999));
        assert_eq!(pubinfo.depots[&367521].oslist.as_deref(), Some("windows"));

        // A beta pin must resolve against ITS branch, not silently be "updated" onto public.
        let beta = parse_app_info(body, 367520, "beta").unwrap();
        assert_eq!(beta.build_id, "18500000");
        assert_eq!(beta.depots[&367521].gid, "222");
        assert!(
            !beta.depots.contains_key(&367523),
            "a depot this branch does not ship must be absent, not fall back to public"
        );

        // An unlisted branch names the ones on offer rather than guessing.
        let Err(e) = parse_app_info(body, 367520, "nope") else {
            panic!("an unlisted branch must not resolve");
        };
        assert!(matches!(e, SteamError::Unsupported(_)), "got {e:?}");
        let msg = e.to_string();
        assert!(msg.contains("public") && msg.contains("beta"), "got: {msg}");
        // A numeric buildid (some mirrors emit one) is still read.
        let numeric = r#"{"data":{"1":{"depots":{"2":{"manifests":{"public":{"gid":"9"}}},
            "branches":{"public":{"buildid":42}}}}}}"#;
        assert_eq!(parse_app_info(numeric, 1, "public").unwrap().build_id, "42");
    }

    /// A JWT-shaped token whose payload really is JSON (`looks_like_jwt` checks that), optionally
    /// already expired.
    fn fake_jwt(exp: u64) -> String {
        use base64::Engine;
        let b64 = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(s.as_bytes());
        format!(
            "{}.{}.sig",
            b64(r#"{"alg":"EdDSA"}"#),
            b64(&format!(r#"{{"exp":{exp}}}"#))
        )
    }

    /// A credential tar shaped exactly like the one `propnix cred add steam` stores: a path-preserving
    /// tar of DepotDownloader's `account.config`, itself raw DEFLATE over a protobuf-net message whose
    /// member 4 (`LoginTokens`) maps account name -> refresh token.
    fn write_cred_tar(path: &std::path::Path, accounts: &[(&str, &str)]) {
        use std::io::Write;
        let mut proto = Vec::new();
        for (k, v) in accounts {
            let mut entry = Vec::new();
            entry.push(0x0A); // field 1, len-delimited
            entry.push(k.len() as u8);
            entry.extend_from_slice(k.as_bytes());
            entry.push(0x12); // field 2, len-delimited
            // A token is longer than 127 bytes, so its length is a two-byte varint.
            let n = v.len();
            assert!(n < 1 << 14);
            if n < 128 {
                entry.push(n as u8);
            } else {
                entry.push((n & 0x7f) as u8 | 0x80);
                entry.push((n >> 7) as u8);
            }
            entry.extend_from_slice(v.as_bytes());

            proto.push(0x22); // field 4 (LoginTokens), len-delimited
            let m = entry.len();
            assert!(m < 1 << 14);
            if m < 128 {
                proto.push(m as u8);
            } else {
                proto.push((m & 0x7f) as u8 | 0x80);
                proto.push((m >> 7) as u8);
            }
            proto.extend_from_slice(&entry);
        }
        let mut enc = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::fast());
        enc.write_all(&proto).unwrap();
        let deflated = enc.finish().unwrap();

        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut ar = tar::Builder::new(std::fs::File::create(path).unwrap());
        let mut hdr = tar::Header::new_gnu();
        hdr.set_size(deflated.len() as u64);
        hdr.set_mode(0o600);
        hdr.set_cksum();
        ar.append_data(&mut hdr, "DepotDownloader/account.config", &deflated[..])
            .unwrap();
        ar.finish().unwrap();
    }

    #[test]
    fn stored_steam_accounts_are_deterministic_and_selectable() {
        let root = std::env::temp_dir().join(format!(
            "propnix-steamcred-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let live = fake_jwt(4_000_000_000);
        write_cred_tar(
            &root.join("steam/zoe/depotdownloader-store.tar"),
            &[("zoe", &live)],
        );
        write_cred_tar(
            &root.join("steam/alice/depotdownloader-store.tar"),
            &[("alice", &live)],
        );

        // SORTED BY NAME — the try-all order must not depend on readdir.
        let all = credentials_from_store(&root, None).unwrap();
        assert_eq!(
            all.iter().map(|c| c.account.as_str()).collect::<Vec<_>>(),
            vec!["alice", "zoe"],
            "more than one account is no longer an error; they are simply tried in order"
        );

        // A named account narrows to exactly that one.
        let one = credentials_from_store(&root, Some("zoe")).unwrap();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].account, "zoe");

        // …and a name the store does not hold lists what it does.
        let Err(e) = credentials_from_store(&root, Some("nobody")) else {
            panic!("an absent account must be an error");
        };
        assert!(matches!(e, SteamError::NoCredential(_)), "got {e:?}");
        let msg = e.to_string();
        assert!(msg.contains("alice") && msg.contains("zoe"), "got: {msg}");
        assert!(msg.contains("--steam-account"), "must name the flag that exists: {msg}");

        // An EXPIRED token is skipped rather than failing the run — another account may still be good.
        let mixed = root.join("mixed");
        write_cred_tar(
            &mixed.join("steam/stale/depotdownloader-store.tar"),
            &[("stale", &fake_jwt(1))],
        );
        write_cred_tar(
            &mixed.join("steam/good/depotdownloader-store.tar"),
            &[("good", &live)],
        );
        let usable = credentials_from_store(&mixed, None).unwrap();
        assert_eq!(usable.iter().map(|c| c.account.as_str()).collect::<Vec<_>>(), vec!["good"]);

        // …but if every token has expired, say so instead of reporting "no credential".
        let allstale = root.join("allstale");
        write_cred_tar(
            &allstale.join("steam/stale/depotdownloader-store.tar"),
            &[("stale", &fake_jwt(1))],
        );
        let Err(e) = credentials_from_store(&allstale, None) else {
            panic!("an all-expired store must be an error");
        };
        assert!(e.to_string().contains("expired"), "got: {e}");

        // An empty store is NoCredential, not NotOwned.
        let empty = root.join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        assert!(matches!(
            credentials_from_store(&empty, None),
            Err(SteamError::NoCredential(_))
        ));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn try_all_advances_past_an_account_that_does_not_own_it() {
        let creds = vec![
            Credential { account: "alice".into(), refresh_token: "a".into() },
            Credential { account: "zoe".into(), refresh_token: "z".into() },
        ];
        let exhausted = |tried: Vec<String>, last: String| {
            Box::new(SteamError::NotOwned(format!("none of {} ({last})", tried.join(", "))))
                as Box<dyn std::error::Error>
        };

        // The second account owns it: the first refusal must not be fatal.
        let mut seen: Vec<String> = Vec::new();
        let got = crate::pin::try_accounts(
            &creds,
            |c| c.account.clone(),
            is_not_owned,
            exhausted,
            |c| {
                seen.push(c.account.clone());
                if c.account == "alice" {
                    Err(Box::new(SteamError::NotOwned("eresult 2".into())) as Box<dyn std::error::Error>)
                } else {
                    Ok(42)
                }
            },
        )
        .unwrap();
        assert_eq!(got, 42);
        assert_eq!(seen, vec!["alice", "zoe"], "in stored order, and no further");

        // Nobody owns it: the error names every account tried.
        let none: Result<u32, Box<dyn std::error::Error>> = crate::pin::try_accounts(
            &creds,
            |c| c.account.clone(),
            is_not_owned,
            exhausted,
            |_| Err(Box::new(SteamError::NotOwned("eresult 2".into())) as Box<dyn std::error::Error>),
        );
        let Err(e) = none else {
            panic!("must fail when no account owns it");
        };
        let msg = e.to_string();
        assert!(msg.contains("alice") && msg.contains("zoe"), "got: {msg}");

        // A TRANSPORT failure aborts immediately — retrying it elsewhere would only bury it behind a
        // misleading "no account owns this".
        let mut n = 0;
        let transport: Result<u32, Box<dyn std::error::Error>> = crate::pin::try_accounts(
            &creds,
            |c| c.account.clone(),
            is_not_owned,
            exhausted,
            |_| {
                n += 1;
                Err(Box::new(SteamError::Http("connection reset".into())) as Box<dyn std::error::Error>)
            },
        );
        let Err(e) = transport else {
            panic!("a transport failure must not be swallowed");
        };
        assert_eq!(n, 1, "must not try the second account after a transport error");
        assert!(e.to_string().contains("connection reset"), "got: {e}");
    }

    #[test]
    fn truncated_bodies_error_instead_of_panicking() {
        // All three used to abort the process (or, in a prefetch worker, hang it forever).
        assert!(unzip_single_deflate_entry(b"PK\x03\x04").is_err());
        let mut hdr = vec![0u8; 30];
        hdr[0..4].copy_from_slice(b"PK\x03\x04");
        hdr[8..10].copy_from_slice(&8u16.to_le_bytes());
        hdr[26..28].copy_from_slice(&0xFFFFu16.to_le_bytes()); // name_len past the end
        assert!(unzip_single_deflate_entry(&hdr).is_err());
        // A 'VZ' body between 12 and 21 bytes would slice raw[12..len-10] with start > end.
        let mut vz = b"VZ\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07zv".to_vec();
        assert!(vz.len() < VZ_MIN);
        assert!(decompress_chunk(&vz, 1).is_err());
        vz.truncate(2);
        assert!(decompress_chunk(&vz, 1).is_err());
    }

    #[test]
    fn directory_entries_survive_as_empty_dirs() {
        let files = vec![
            FileEntry { path: "empty".into(), size: u64::MAX, executable: false, chunks: vec![] },
            FileEntry { path: "a/b.txt".into(), size: 0, executable: false, chunks: vec![] },
        ];
        let t = tree(&files).unwrap();
        let (_, stats) = nar::nar_hash(&t, |_, _| Ok(())).unwrap();
        // root + "empty" + the implied "a" — manifests often omit parent directories.
        assert_eq!(stats.dirs, 3);
        assert_eq!(stats.files, 1);
    }

    #[test]
    fn sparse_ranges_are_zero_filled() {
        let f = FileEntry {
            path: "f".into(),
            size: 16,
            executable: false,
            chunks: vec![ChunkRef { sha: [0; 20], offset: 8, cb_original: 4 }],
        };
        let mut out = Vec::new();
        write_file(&f, || Ok(vec![0xAB; 4]), &mut out).unwrap();
        assert_eq!(out.len(), 16);
        assert_eq!(&out[0..8], &[0u8; 8]); // hole before the chunk
        assert_eq!(&out[8..12], &[0xAB; 4]);
        assert_eq!(&out[12..16], &[0u8; 4]); // hole after it
    }
}

/// Resolve a depot manifest and stream it into a NAR hash. Nothing touches disk.
pub fn hash_depot(
    app_id: u32,
    depot_id: u32,
    manifest_id: u64,
    // The manifest currently pinned, if any. Used only to refuse a rollback.
    previous: Option<u64>,
    branch: &str,
    auth: Auth,
    opts: &crate::pin::gog::HashOpts,
) -> Result<(String, nar::Stats, Vec<FileEntry>), Box<dyn std::error::Error>> {
    // Request codes are single-use and short-lived, so they are fetched together immediately before
    // use. Asking for the previous manifest's code in the same session is what makes the rollback
    // check cost one small extra GET rather than a second login.
    let mut wanted = vec![manifest_id];
    if let Some(p) = previous.filter(|p| *p != manifest_id) {
        wanted.push(p);
    }
    let ctl = control(app_id, depot_id, &wanted, branch, auth)?;
    let agent = http_agent();
    let code = |m: u64| -> Result<u64, SteamError> {
        ctl.codes
            .get(&m)
            .copied()
            .ok_or_else(|| SteamError::Parse(format!("no request code for manifest {m}")))
    };
    let (files, created) = fetch_manifest(
        &agent,
        &ctl.hosts,
        depot_id,
        manifest_id,
        code(manifest_id)?,
        &ctl.depot_key,
    )?;
    // NEVER MOVE BACKWARDS. Steam manifest ids are not ordered, so the only honest comparison is the
    // creation time each manifest carries in its own metadata.
    if let Some(prev) = previous.filter(|p| *p != manifest_id) {
        let (_, prev_created) = fetch_manifest(
            &agent,
            &ctl.hosts,
            depot_id,
            prev,
            code(prev)?,
            &ctl.depot_key,
        )?;
        if created < prev_created {
            return Err(Box::new(SteamError::Unsupported(format!(
                "refusing to move depot {depot_id} backwards — Steam's current public manifest \
                 {manifest_id} was created at {created}, older than the pinned {prev} ({prev_created}). \
                 That usually means the build was rolled back; re-pin by hand if it is intended."
            ))));
        }
    }
    let total: u64 = files.iter().filter(|f| f.size != u64::MAX).map(|f| f.size).sum();
    let tree = tree(&files)?;

    let order = nar::flatten(&tree);
    let mut work: Vec<ChunkRef> = Vec::new();
    for &&idx in &order {
        let mut cs: Vec<ChunkRef> = files[idx].chunks.clone();
        cs.sort_by_key(|c| c.offset);
        work.extend(cs);
    }

    let src = std::sync::Arc::new(ChunkSource::new(agent, ctl.hosts, depot_id, ctl.depot_key));
    let pf = crate::pin::prefetch::Prefetcher::new(
        work,
        opts.workers,
        opts.window_bytes,
        Box::new(move |c: &ChunkRef| src.get(c)),
    );

    let mut seen = 0u64;
    let mut last_pct = 0u64;
    let progress = opts.progress;
    let (sri, stats) = nar::nar_hash(&tree, |idx, w| {
        steam_write(&files[*idx], &pf, &mut seen, w)?;
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
    Ok((sri, stats, files))
}

/// `hash_depot`, but TRYING EVERY STORED ACCOUNT until one can fetch the depot — the same behaviour
/// `fetchSteamDepot` has, so a host with several Steam accounts needs no per-game selection.
///
/// Advances only on an OWNERSHIP-class refusal (login rejected, depot key eresult != 1, no manifest
/// request code); a transport or parse failure aborts immediately, because retrying it against another
/// account would only bury it. All the ownership checks happen in `control()`, before a byte of content
/// moves, so a wrong account costs one round trip rather than a download.
pub fn hash_depot_any(
    app_id: u32,
    depot_id: u32,
    manifest_id: u64,
    previous: Option<u64>,
    branch: &str,
    opts: &crate::pin::gog::HashOpts,
) -> Result<(String, nar::Stats, Vec<FileEntry>), Box<dyn std::error::Error>> {
    let creds = credentials_from_store(&opts.credential_dir, opts.steam_account.as_deref())?;
    crate::pin::try_accounts(
        &creds,
        |c| c.account.clone(),
        is_not_owned,
        |tried, last| {
            Box::new(SteamError::NotOwned(format!(
                "no stored Steam account can fetch app {app_id} depot {depot_id} manifest {manifest_id} \
                 (tried: {}). Last refusal: {last}",
                tried.join(", ")
            ))) as Box<dyn std::error::Error>
        },
        |c| {
            hash_depot(
                app_id,
                depot_id,
                manifest_id,
                previous,
                branch,
                Auth::Account(c.clone()),
                opts,
            )
        },
    )
}

/// Is this the kind of Steam failure another stored account might not have?
///
/// `&Box<_>` rather than `&dyn Error`: `try_accounts` is generic over its error type, which here IS
/// `Box<dyn Error>`, so the predicate's signature has to match that exactly.
#[allow(clippy::borrowed_box)]
fn is_not_owned(e: &Box<dyn std::error::Error>) -> bool {
    matches!(e.downcast_ref::<SteamError>(), Some(SteamError::NotOwned(_)))
}

fn steam_write(
    f: &FileEntry,
    pf: &crate::pin::prefetch::Prefetcher<ChunkRef>,
    seen: &mut u64,
    w: &mut dyn std::io::Write,
) -> Result<(), nar::NarError> {
    write_file(
        f,
        || {
            let v = pf.next_chunk()?;
            *seen += v.len() as u64;
            Ok(v)
        },
        w,
    )
    .map_err(nar::NarError::Fetch)
}

/// The current manifest gid for every depot of an app ON ONE BRANCH, plus that branch's build id.
///
/// Anonymous — but say honestly where it comes from: `api.steamcmd.net` is a THIRD-PARTY mirror, because
/// Valve publishes no unauthenticated appinfo endpoint (an anonymous CM PICS session is the credential-
/// free alternative, and the fallback if the mirror ever dies). Detecting that a pin is stale therefore
/// costs no credential at all; only recomputing the hash does. What a bad mirror could do is bounded: the
/// never-move-backwards guard rejects a rollback, and Steam itself issues the manifest request codes, so
/// a fabricated manifest id simply fails to download. One response is an atomic snapshot across every
/// depot, which is exactly the "all current at the same moment" invariant a DLC-in-tandem update needs.
pub struct AppInfo {
    /// The branch's build id. Steam publishes no human version strings, so this is the only real
    /// version-ish label a Steam pin can carry — `propnix pin` writes it into the row's `version`.
    pub build_id: String,
    pub depots: BTreeMap<u32, DepotInfo>,
}

#[derive(Clone, Debug)]
pub struct DepotInfo {
    pub gid: String,
    /// Set when the depot belongs to a DLC rather than the base game. This is how a Steam DLC would be
    /// kept in tandem with its base game; no propnix game pins a Steam DLC yet.
    #[allow(dead_code)]
    pub dlc_app: Option<u32>,
    /// `config.oslist`, e.g. "windows" / "linux" — how a scaffolded pin picks its propnix platform.
    pub oslist: Option<String>,
}

pub fn app_info(app_id: u32, branch: &str) -> R<AppInfo> {
    let url = format!("https://api.steamcmd.net/v1/info/{app_id}");
    let body = crate::pin::retry::with_retry(
        &format!("appinfo for {app_id}"),
        &crate::pin::retry::METADATA,
        |_: &SteamError| true, // every failure here is the fetch itself; parsing happens below
        || {
            meta_agent()
                .get(&url)
                .call()
                .map_err(|e| SteamError::Http(format!("appinfo for {app_id}: {e}")))?
                .into_string()
                .map_err(|e| SteamError::Http(format!("appinfo for {app_id}: {e}")))
        },
    )?;
    parse_app_info(&body, app_id, branch)
}

/// The appinfo parser, split out from the fetch so it can be unit-tested against a canned body — the
/// branch handling below is exactly the kind of thing that must not be verified only in production.
pub fn parse_app_info(body: &str, app_id: u32, branch: &str) -> R<AppInfo> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| SteamError::Parse(format!("appinfo: {e}")))?;
    let app = v
        .get("data")
        .and_then(|d| d.get(app_id.to_string()))
        .ok_or_else(|| SteamError::Parse(format!("appinfo has no entry for {app_id}")))?;
    let depots_obj = app
        .get("depots")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| SteamError::Parse("appinfo has no depots".into()))?;
    let branches = depots_obj.get("branches");
    // A branch appinfo does not list is a human problem, not a tool bug: name the ones it does. This
    // also covers a passworded/hidden branch, which never appears here at all — out of scope on
    // purpose (DepotDownloader's `-betapassword` would be the hook if it is ever wanted).
    let Some(binfo) = branches.and_then(|b| b.get(branch)) else {
        let offered: Vec<&str> = branches
            .and_then(serde_json::Value::as_object)
            .map(|m| m.keys().map(String::as_str).collect())
            .unwrap_or_default();
        return Err(SteamError::Unsupported(format!(
            "app {app_id} lists no branch {branch:?} (it offers: {}); a passworded or hidden branch is \
             not visible in appinfo and needs a human",
            if offered.is_empty() { "none".to_string() } else { offered.join(", ") }
        )));
    };
    let build_id = binfo
        .get("buildid")
        .and_then(|b| match b {
            serde_json::Value::String(s) => Some(s.clone()),
            serde_json::Value::Number(n) => Some(n.to_string()),
            _ => None,
        })
        .unwrap_or_default();
    let mut depots = BTreeMap::new();
    for (k, d) in depots_obj {
        let Ok(depot_id) = k.parse::<u32>() else {
            continue; // "branches", "baselanguages", ...
        };
        let Some(gid) = d
            .get("manifests")
            .and_then(|m| m.get(branch))
            .and_then(|p| p.get("gid"))
            .and_then(serde_json::Value::as_str)
        else {
            continue; // legacy depot, or one this branch does not ship
        };
        let dlc_app = d
            .get("dlcappid")
            .and_then(|x| x.as_str().and_then(|s| s.parse().ok()).or_else(|| x.as_u64().map(|n| n as u32)));
        let oslist = d
            .get("config")
            .and_then(|c| c.get("oslist"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        depots.insert(
            depot_id,
            DepotInfo {
                gid: gid.to_string(),
                dlc_app,
                oslist,
            },
        );
    }
    Ok(AppInfo { build_id, depots })
}
