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
    /// The account does not own this depot — a REAL answer from a healthy session (depot-key eresult,
    /// missing request code). NOT a failure: the multi-account walkers advance on it.
    NotOwned(String),
    /// The LOGIN itself was refused (bad/expired token, or Steam's logon rate limiter — which reports
    /// throttling as "invalid credentials"). Distinct from `NotOwned` because it says nothing about
    /// ownership: the account walkers still advance on it (a dead account must not strand the others),
    /// but `probe_depots` must NOT record it as "unowned" — that conflation is how a throttled probe
    /// run once misclassified 19 depots.
    LoginFailed(String),
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
            SteamError::LoginFailed(m) => write!(f, "Steam login failed: {m}"),
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
        // OVERALL deadline per call, on top of the per-operation ones above. The per-read timeout only
        // bounds the wait for the NEXT byte, so a connection that trickles — or one left half-open when the
        // machine changes network or resumes from suspend — can hang a request forever without ever
        // tripping it, and then no retry policy gets a chance to run. Not hypothetical: that stranded a
        // 95%-complete depot twice in one day, with the process burning zero CPU. This agent now serves
        // only METADATA (build lists, manifests, appinfo); bulk chunks go through pin::engine, which
        // enforces its own deadline. 120s is far longer than any healthy metadata call.
        .timeout(std::time::Duration::from_secs(120))
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

/// Read (account, refresh token) pairs out of every stored credential tar. The wire-format decoding
/// (tar → account.config → protobuf-net `LoginTokens` → JWT filter) lives in the `propnix-steam-cred`
/// crate — kept separate so that undocumented format is testable on its own. What stays here is POLICY —
/// the expiry check, the `--steam-account` narrowing, and the error taxonomy.
///
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
    let tars = propnix_steam_cred::store_tars(cred_dir);
    if tars.is_empty() {
        return Err(SteamError::NoCredential(format!(
            "no Steam credential under {} — run `propnix cred add steam`",
            cred_dir.display()
        )));
    }

    let mut all: BTreeMap<String, String> = BTreeMap::new();
    for t in &tars {
        // SKIP a token we cannot USE, never fail the whole set on one bad account. Two kinds of unusable:
        //   * unreadable — another user's (0640, owned by them): `store_tars` enumerates every account on
        //     a shared host, but a human's own credentials stay private, and it is never OURS (we read our
        //     own via the owner bits). Never "repair" it — that would chown a stranger's token to us.
        //   * corrupt — openable but the inner account.config is truncated/uninflatable (e.g. a token left
        //     partial by an interrupted `cred add` on an OLD propnix without the atomic write).
        // Either way, warn and try the next; a healthy account must not be stranded by a broken sibling.
        // If EVERY account fails, the empty-check below reports it.
        let f = match std::fs::File::open(t) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => continue,
            Err(e) => {
                eprintln!("propnix: skipping unreadable Steam credential {}: {e}", t.display());
                continue;
            }
        };
        match propnix_steam_cred::login_tokens_in_tar(f) {
            Ok(tokens) => all.extend(tokens),
            Err(e) => {
                eprintln!("propnix: skipping malformed Steam credential {}: {e}", t.display());
                continue;
            }
        }
    }

    // BTreeMap: sorted by account name, so the try-all order is deterministic.
    let jwts = all;
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
        if let Some(exp) = propnix_steam_cred::jwt_expiry(&token) {
            if exp != 0 && now >= exp {
                expired.push(account);
                continue;
            }
        }
        out.push(Credential {
            account,
            refresh_token: token,
        });
    }
    if out.is_empty() {
        // (Reachable only with expired non-empty: an empty store and an unknown --steam-account both
        // errored above, so everything the filter admitted was expired.)
        // A credential-class failure, NOT ownership: an expired token says nothing about who owns what,
        // so it must classify as "add a credential" (LoginFailed → Blocked::NoCredential), never a false
        // "no account owns this". Word it for what was actually examined: with `--steam-account`/env
        // narrowing, only the SELECTED account was checked — other stored tokens may be fine.
        let msg = match want_account {
            Some(w) => format!(
                "the selected Steam account {w:?}'s stored refresh token has expired — re-run \
                 `propnix cred add steam`, or pick another stored account"
            ),
            None => format!(
                "every stored Steam refresh token has expired ({}) — re-run `propnix cred add steam` \
                 (a CI runner also needs its secret re-set from the new tar)",
                expired.join(", ")
            ),
        };
        return Err(SteamError::LoginFailed(msg));
    }
    for a in &expired {
        eprintln!("  Steam account {a:?}: stored refresh token has expired — skipping it");
    }
    Ok(out)
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

/// A live CM session: the authenticated connection plus the tokio runtime that drives it (a
/// multi-thread runtime's workers keep running between `block_on` calls, so heartbeats keep flowing
/// while we hash or download between control-plane requests).
///
/// Sessions live in a process-global registry keyed by account, so ONE LOGIN serves every depot of
/// every product a run touches. That is not an optimization nicety: Steam rate-limits logons harshly —
/// a burst of ~90 (an agent probing DLC ownership depot-by-depot) had every subsequent logon refused as
/// "invalid credentials" for the better part of an hour, and a multi-depot pin used to pay one logon
/// per depot, so a 4-depot pin could stream 147 GiB and then die on the logon for a 573-byte depot.
struct CmSession {
    rt: tokio::runtime::Runtime,
    conn: steam_vent::Connection,
}

fn session_key(auth: &Auth) -> String {
    match auth {
        Auth::Anonymous => "<anonymous>".to_string(),
        Auth::Account(c) => c.account.clone(),
    }
}

fn sessions() -> &'static std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<CmSession>>> {
    static SESSIONS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<CmSession>>>,
    > = std::sync::OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

/// Accounts whose login Steam REFUSED (`LoginFailed` class) — the negative side of the session registry,
/// and like it strictly PROCESS-LIFETIME. Without this, a dead (revoked-but-unexpired) token re-pays one
/// failed logon per `control()` call: a large probe or multi-depot pin with one dead account rebuilds the
/// very logon burst the shared-session design exists to prevent. With it, the first refusal is remembered
/// and every later request for that account fails fast, no network touched.
///
/// Deliberately NEVER persisted — not even in `<store>/cache`: that directory is world-writable by design,
/// so a persistent "this account is dead" marker would be forgeable by any local user or builder, silently
/// skipping a HEALTHY account (negative-cache poisoning, strictly worse than the burst). Process lifetime
/// also self-corrects the one ambiguity Steam forces on us — throttling is reported as invalid credentials
/// — because a throttle mistaken for a dead token costs only the remainder of one run, and the cross-run
/// cost of no persistence is a single failed logon per invocation, which the limiter tolerates.
fn refused_logins() -> &'static std::sync::Mutex<std::collections::HashMap<String, String>> {
    static REFUSED: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, String>>> =
        std::sync::OnceLock::new();
    REFUSED.get_or_init(Default::default)
}

/// The session for `auth`, logging in only if this process has none yet. Built OUTSIDE the registry
/// lock: a login is a network round-trip, and another thread may want a different account meanwhile.
fn session_for(auth: &Auth) -> R<std::sync::Arc<CmSession>> {
    use steam_vent::{Connection, ServerList};
    let key = session_key(auth);
    if let Some(s) = sessions().lock().unwrap_or_else(std::sync::PoisonError::into_inner).get(&key) {
        return Ok(s.clone());
    }
    // An account this process already saw refused fails fast — same class, no fresh logon attempt.
    if let Some(prev) = refused_logins()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&key)
    {
        return Err(SteamError::LoginFailed(format!(
            "account {key:?}'s login was already refused in this run — not retrying ({prev})"
        )));
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .build()
        .map_err(|e| SteamError::Http(format!("tokio: {e}")))?;
    let is_account = matches!(auth, Auth::Account(_));
    let auth = auth.clone();
    let conn = rt.block_on(async move {
        let servers = ServerList::discover()
            .await
            .map_err(|e| SteamError::Http(format!("server discovery: {e}")))?;
        match &auth {
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
            // NB: this arm also catches steam-vent's non-Network login failures that are really
            // Steam-side transients (TryAnotherCM/ServiceUnavailable-class eresults, Aborted). Those
            // classify as "a human should look" rather than a red run — imperfect, but strictly better
            // than the transport bucket (which would abort the whole account walk) and the message
            // hedges accordingly.
            other => SteamError::LoginFailed(format!(
                "{other} — a refused login is usually a stale token (re-run `propnix cred add steam`) \
                 or Steam's logon rate limiter, which reports throttling as invalid credentials; when \
                 in doubt, wait an hour before re-adding anything"
            )),
        })
    });
    let conn = match conn {
        Ok(c) => c,
        Err(e) => {
            // Remember a REFUSAL for the rest of the process (see `refused_logins`); transport failures
            // are not remembered — they say nothing about the credential and retrying them is correct.
            // Neither is an ANONYMOUS refusal: there is no credential to be dead there, only a CM having
            // a bad moment, and blocking anonymous for the whole run over one transient would be wrong.
            if is_account {
                if let SteamError::LoginFailed(msg) = &e {
                    refused_logins()
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .insert(key, msg.clone());
                }
            }
            return Err(e);
        }
    };
    let s = std::sync::Arc::new(CmSession { rt, conn });
    Ok(sessions().lock().unwrap_or_else(std::sync::PoisonError::into_inner).entry(key).or_insert(s).clone())
}

/// Forget a (presumably stale) session so the next `session_for` logs in afresh. Called on TRANSPORT
/// failures of a control-plane request; `control()`'s retry-on-Http then re-enters with a new login,
/// which is how a connection Steam dropped between depots self-heals without a retry ladder here.
fn drop_session(auth: &Auth) {
    sessions().lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&session_key(auth));
}

fn control_once(
    app_id: u32,
    depot_id: u32,
    manifest_ids: &[u64],
    branch: &str,
    auth: Auth,
) -> R<Control> {
    use steam_vent::ConnectionTrait;
    use steam_vent_proto_steam::steammessages_clientserver_2::{
        CMsgClientGetDepotDecryptionKey, CMsgClientGetDepotDecryptionKeyResponse,
    };
    use steam_vent_proto_steam::steammessages_contentsystem_steamclient::CContentServerDirectory_GetManifestRequestCode_Request;

    let session = session_for(&auth)?;
    let conn = &session.conn;

    let result: R<([u8; 32], BTreeMap<u64, u64>, u32)> = session.rt.block_on(async move {
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
    });
    let (depot_key, codes, cell_id) = match result {
        Ok(t) => t,
        Err(e) => {
            // A transport-class failure may mean Steam dropped this connection between requests;
            // forget the session so `control()`'s retry-on-Http re-enters through a fresh login.
            // Refusals (NotOwned/eresult) keep the session — it is healthy, the answer was just no.
            if matches!(e, SteamError::Http(_)) {
                drop_session(&auth);
            }
            return Err(e);
        }
    };
    let hosts = content_hosts(cell_id)?;
    Ok(Control {
        depot_key,
        codes,
        hosts,
    })
}

/// Everything a depot fetch needs, however it was obtained: the CM path (one process-wide login) or
/// the ANCHOR-VERIFIED cache (no login at all — chunk downloads are anonymous HTTP). `manifest()` is
/// the single reader both paths share, so decode behavior cannot diverge between them, and the CM path
/// writes back what it fetched (best-effort) so the next run can take the loginless path.
pub struct DepotAccess {
    pub depot_key: [u8; 32],
    pub hosts: Vec<String>,
    depot_id: u32,
    codes: BTreeMap<u64, u64>,
    cached: BTreeMap<u64, Vec<u8>>,
}

/// One requested manifest plus its pin-recorded trust anchor, if the caller has one (only anchored
/// artifacts may come from the cache — see pin/steamcache.rs for the trust model).
pub struct Want<'a> {
    pub manifest: u64,
    pub manifest_sha256: Option<&'a str>,
}

/// A decoded manifest plus the sha256 of its RAW bytes — the anchor `pin` records in versions.json.
pub struct ManifestData {
    pub files: Vec<FileEntry>,
    pub created: u32,
    pub sha256: String,
}

/// The cache trust anchors a hash run produces, destined for the versions.json row (`depotKeySha256`,
/// `manifestSha256`). With both recorded, the FOD that fetches this pin can run with ZERO Steam logins.
pub struct PinAnchors {
    pub depot_key_sha256: String,
    pub manifest_sha256: String,
}

/// Depot access from the CACHE ALONE — no CM connection, and crucially NO CREDENTIAL: a warm anchored
/// cache lets a fetch skip not just the login but reading the token at all (which is what lets a
/// sandboxed FOD fetch a depot whose token it cannot even read). `None` on any gap — no depot-key
/// anchor, a manifest with no anchor, a missing or wrong-content entry, or the host-directory lookup
/// failing — so the caller falls through to the credentialed CM path, never to an error.
///
/// Every wanted manifest must be anchored AND present: a partial cache is a miss, because the CM path
/// is all-or-nothing (one login yields every manifest) and mixing the two would gain nothing.
pub fn acquire_cached(
    depot_id: u32,
    wants: &[Want],
    depot_key_sha256: Option<&str>,
) -> Option<DepotAccess> {
    let key = crate::pin::steamcache::read_key(depot_id, depot_key_sha256?)?;
    let mut cached = BTreeMap::new();
    for w in wants {
        let bytes = crate::pin::steamcache::read_manifest(depot_id, w.manifest, w.manifest_sha256?)?;
        cached.insert(w.manifest, bytes);
    }
    // Cell 0 = the global content-server directory. The session's cell id would give marginally better
    // hosts, but a CACHED cell id would be unverifiable input — and a wrong one yields a dud host list,
    // which is exactly the wedge the contract forbids.
    let hosts = content_hosts(0).ok()?;
    Some(DepotAccess {
        depot_key: key,
        hosts,
        depot_id,
        codes: BTreeMap::new(),
        cached,
    })
}

/// Obtain depot access, cache-first: `acquire_cached` when the anchors and cache allow it (no login),
/// otherwise the CM path (one login, whose depot key is written back to warm the cache for next time).
/// Used by the HASHER, which always has `auth` in hand; the DOWNLOADER instead calls `acquire_cached`
/// directly first, so a cache hit needs no credential AT ALL — see `download_depot_any`.
pub fn acquire(
    app_id: u32,
    depot_id: u32,
    wants: &[Want],
    depot_key_sha256: Option<&str>,
    branch: &str,
    auth: Auth,
) -> R<DepotAccess> {
    if let Some(access) = acquire_cached(depot_id, wants, depot_key_sha256) {
        return Ok(access);
    }
    let ids: Vec<u64> = wants.iter().map(|w| w.manifest).collect();
    let ctl = control(app_id, depot_id, &ids, branch, auth)?;
    crate::pin::steamcache::write_key(depot_id, &ctl.depot_key);
    Ok(DepotAccess {
        depot_key: ctl.depot_key,
        hosts: ctl.hosts,
        depot_id,
        codes: ctl.codes,
        cached: BTreeMap::new(),
    })
}

impl DepotAccess {
    pub fn manifest(&self, agent: &ureq::Agent, manifest_id: u64) -> R<ManifestData> {
        let raw = match self.cached.get(&manifest_id) {
            Some(bytes) => bytes.clone(),
            None => {
                let code = self.codes.get(&manifest_id).copied().ok_or_else(|| {
                    SteamError::Parse(format!("no request code for manifest {manifest_id}"))
                })?;
                let raw =
                    fetch_manifest_raw(agent, &self.hosts, self.depot_id, manifest_id, code)?;
                crate::pin::steamcache::write_manifest(self.depot_id, manifest_id, &raw);
                raw
            }
        };
        let (files, created) = decode_manifest(&raw, &self.depot_key)?;
        Ok(ManifestData {
            files,
            created,
            sha256: crate::pin::steamcache::sha256_hex(&raw),
        })
    }

    /// The anchor for the key this access carries (recorded by `pin` beside the manifest anchor).
    pub fn depot_key_sha256(&self) -> String {
        crate::pin::steamcache::sha256_hex(&self.depot_key)
    }
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
        // Steam reports these as fractional for some cells (e.g. "weighted_load":151.5).
        #[serde(default)]
        load: f64,
        #[serde(default)]
        weighted_load: f64,
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
    servers.sort_by(|a, b| {
        a.weighted_load
            .total_cmp(&b.weighted_load)
            .then(a.load.total_cmp(&b.load))
    });
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
    let body = fetch_manifest_raw(agent, hosts, depot_id, manifest_id, request_code)?;
    decode_manifest(&body, depot_key)
}

/// The transport half of a manifest fetch, returning the RAW zip bytes — split out so the cache can
/// store exactly what came off the wire (its sha256 is the trust anchor `pin` records). A DECODE
/// failure is deliberately outside the retry: the bytes arrived and we could not make sense of them,
/// which more hosts will not fix (`read_to_end` failing IS transport, so it stays inside).
pub fn fetch_manifest_raw(
    agent: &ureq::Agent,
    hosts: &[String],
    depot_id: u32,
    manifest_id: u64,
    request_code: u64,
) -> R<Vec<u8>> {
    // Every host, then the whole sweep again after a pause: a manifest fetch that fails because the
    // network blinked should not fail the run before any content has been transferred.
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
                            Ok(_) => return Ok(body),
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
/// A chunk's id, hex — it is both the URL path and what the integrity check compares against.
fn chunk_hex(sha: &[u8; 20]) -> String {
    sha.iter().map(|b| format!("{b:02x}")).collect()
}

pub struct ChunkSource {
    pub hosts: Vec<String>,
    pub depot_id: u32,
    pub key: [u8; 32],
    /// Host choice, scored by the throughput each server actually delivers (pin::hosts). Replaced a
    /// round-robin counter, which spread requests evenly over servers that are not equally good — and
    /// kept feeding a downed one its full share, so every one of those requests had to fail first.
    pool: crate::pin::hosts::HostPool,
}

impl ChunkSource {
    pub fn new(hosts: Vec<String>, depot_id: u32, key: [u8; 32]) -> Self {
        Self {
            pool: crate::pin::hosts::HostPool::new(hosts.len()),
            hosts,
            depot_id,
            key,
        }
    }

    fn decode_body(&self, ct: &[u8], c: &ChunkRef, hex: &str) -> Result<Vec<u8>, String> {
        // See `decrypt_filename`: the decryptor panics on anything shorter than one AES block, and a
        // panic in a decode task would end the run rather than being retried.
        if ct.len() < AES_BLOCK {
            return Err(format!("truncated chunk body ({} bytes)", ct.len()));
        }
        let plain =
            steam_vent_crypto::symmetric_decrypt_without_hmac(bytes::BytesMut::from(ct), &self.key)
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

/// The engine's view of a Steam depot: which host to ask, and how to turn a body into content.
///
/// There is no retry ladder here on purpose — the engine requeues a failed block, which re-enters
/// `target()` and so lands on whatever host the scorer now prefers. See `pin::engine`.
impl crate::pin::engine::ChunkIo for ChunkSource {
    type Item = ChunkRef;

    fn target(&self, c: &ChunkRef) -> Result<crate::pin::engine::Target, String> {
        let idx = self.pool.pick();
        Ok(crate::pin::engine::Target {
            url: format!(
                "https://{}/depot/{}/chunk/{}",
                self.hosts[idx % self.hosts.len()],
                self.depot_id,
                chunk_hex(&c.sha)
            ),
            endpoint: idx,
        })
    }

    fn decode(&self, c: &ChunkRef, body: Vec<u8>) -> Result<Vec<u8>, String> {
        self.decode_body(&body, c, &chunk_hex(&c.sha))
    }

    fn observe(&self, _c: &ChunkRef, endpoint: usize, outcome: crate::pin::engine::Outcome) {
        match outcome {
            crate::pin::engine::Outcome::Ok { bytes, elapsed } => {
                self.pool.record_success(endpoint, bytes, elapsed)
            }
            crate::pin::engine::Outcome::Failed => self.pool.record_failure(endpoint),
        }
    }

    fn label(&self, c: &ChunkRef) -> String {
        format!("chunk {}", chunk_hex(&c.sha))
    }
}

/// The 7-Zip LZMA SDK's one-shot LZMA1 decoder, as an alternative to liblzma for the VZ container.
///
/// Takes the 5 raw property bytes and the payload DIRECTLY — which is exactly how the VZ container ships
/// them, so no `.lzma` header has to be fabricated to satisfy a container-oriented API.
mod sdk_lzma {
    use lzma_sdk_sys::{ELzmaFinishMode, ELzmaStatus, ISzAlloc, ISzAllocPtr, LzmaDecode, SZ_OK};

    unsafe extern "C" fn alloc(_p: ISzAllocPtr, size: usize) -> *mut core::ffi::c_void {
        if size == 0 {
            return core::ptr::null_mut();
        }
        libc::malloc(size)
    }
    unsafe extern "C" fn free(_p: ISzAllocPtr, addr: *mut core::ffi::c_void) {
        libc::free(addr);
    }
    static ALLOC: ISzAlloc = ISzAlloc {
        Alloc: Some(alloc),
        Free: Some(free),
    };

    /// `props` = the 5 LZMA1 property bytes; `payload` = the raw LZMA1 stream; `expect` = exact output size.
    pub fn decode(props: &[u8], payload: &[u8], expect: usize) -> Result<Vec<u8>, String> {
        if props.len() < 5 {
            return Err("lzma: short property block".into());
        }
        let mut out = vec![0u8; expect];
        let mut dest_len = expect;
        let mut src_len = payload.len();
        let mut status: ELzmaStatus = ELzmaStatus::LZMA_STATUS_NOT_SPECIFIED;
        // SAFETY: all four buffers are live for the call; the lengths are in/out and read back below.
        let res = unsafe {
            LzmaDecode(
                out.as_mut_ptr(),
                &mut dest_len,
                payload.as_ptr(),
                &mut src_len,
                props.as_ptr(),
                5,
                ELzmaFinishMode::LZMA_FINISH_END,
                &mut status,
                &ALLOC,
            )
        };
        if res != SZ_OK as i32 {
            return Err(format!("lzma: SDK decode failed (SRes {res}, status {status:?})"));
        }
        if dest_len != expect {
            return Err(format!("lzma: SDK produced {dest_len} bytes, manifest says {expect}"));
        }
        Ok(out)
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
        // Legacy: raw LZMA1, which is the ONLY container an older depot uses — and the hot path when one
        // is pinned, at ~95% of the whole tool's CPU. The container hands over the 5 LZMA1 property bytes
        // and the raw stream separately, which is precisely the shape the LZMA SDK's one-shot decoder
        // takes, so nothing has to be reframed. VZ_MIN, not 12: the payload slice below is
        // `raw[12..raw.len()-10]`, so a 12..21-byte body would slice with start > end and panic.
        if !raw.ends_with(b"zv") {
            return Err("VZ footer is not 'zv'".into());
        }
        sdk_lzma::decode(&raw[7..12], &raw[12..raw.len() - 10], expect)?
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

    // (The JWT and protobuf-walk decoders are tested where they live now: propnix-steam-cred.)

    #[test]
    fn the_ordered_and_unordered_assemblies_agree_on_a_cross_file_deduped_tree() {
        // The two-writer test below covers ONE file. This covers what a real base depot has and no other
        // test does: MANY files sharing chunks (cross-file dedup), leading/trailing/interior holes, an
        // explicit empty dir, an executable, all assembled two ways — the ordered streamer the PIN hashes
        // vs the pre-sized pwrite the DOWNLOAD writes — and hashed with the SAME serializer, so any
        // difference is pure content/structure divergence between the two assemblies (a serializer vs Nix
        // difference is a separate axis and cannot show up here).
        use std::os::unix::fs::{FileExt, OpenOptionsExt};
        // Deterministic content per chunk identity: same (sha) => same bytes everywhere it appears.
        fn content(c: &ChunkRef) -> Vec<u8> {
            (0..c.cb_original)
                .map(|i| c.sha[(i as usize) % 20].wrapping_add(i as u8))
                .collect()
        }
        let ch = |seed: u8, off: u64, len: u32| ChunkRef {
            sha: [seed; 20],
            offset: off,
            cb_original: len,
        };
        // A pool of chunk seeds reused across files, plus holes (gaps between chunk end and next offset)
        // and tails (file size beyond the last chunk).
        let files = vec![
            FileEntry { path: "dir".into(), size: u64::MAX, executable: false, chunks: vec![] },
            FileEntry { path: "dir/empty_sub".into(), size: u64::MAX, executable: false, chunks: vec![] },
            // leading hole (first chunk at offset 8), interior hole, shared seeds 1 & 2
            FileEntry {
                path: "dir/a.dat".into(), size: 4096, executable: false,
                chunks: vec![ch(1, 8, 100), ch(2, 2000, 100)],
            },
            // seed 1 again (cross-file dup), plus a trailing hole (size 900 > 300+100)
            FileEntry {
                path: "dir/b.dat".into(), size: 900, executable: true,
                chunks: vec![ch(3, 0, 100), ch(1, 300, 100)],
            },
            // same seed 2 twice within one file (intra-file dup) at different offsets
            FileEntry {
                path: "c.dat".into(), size: 500, executable: false,
                chunks: vec![ch(2, 0, 100), ch(2, 200, 100), ch(3, 400, 100)],
            },
            FileEntry { path: "z_empty.dat".into(), size: 0, executable: false, chunks: vec![] },
        ];

        // ORDERED (pin): nar_hash over the manifest tree, each file streamed in offset order by write_file.
        let tree = tree(&files).unwrap();
        let (pin_hash, _) = nar::nar_hash(&tree, |idx: &usize, w| {
            let f = &files[*idx];
            let mut cs: Vec<&ChunkRef> = f.chunks.iter().collect();
            cs.sort_by_key(|c| c.offset);
            let mut it = cs.into_iter();
            write_file(f, || Ok(content(it.next().expect("chunk"))), w).map_err(nar::NarError::Fetch)
        })
        .unwrap();

        // UNORDERED (download): create each file at its declared size, pwrite each chunk at its offset,
        // then hash the real on-disk tree with the same serializer.
        let dir = std::env::temp_dir().join(format!("propnix-xdedup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for f in &files {
            let p = dir.join(&f.path);
            if f.size == u64::MAX {
                std::fs::create_dir_all(&p).unwrap();
                continue;
            }
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            let h = std::fs::OpenOptions::new()
                .write(true).create(true).truncate(true)
                .mode(if f.executable { 0o755 } else { 0o644 })
                .open(&p).unwrap();
            h.set_len(f.size).unwrap();
            for c in &f.chunks {
                h.write_all_at(&content(c), c.offset).unwrap();
            }
        }
        let local = nar::local_tree(&dir).unwrap();
        let (fetch_hash, _) = nar::nar_hash(&local, |p: &std::path::PathBuf, w| {
            let mut file = std::fs::File::open(p).map_err(|e| nar::NarError::Fetch(e.to_string()))?;
            std::io::copy(&mut file, w).map_err(|e| nar::NarError::Fetch(e.to_string()))?;
            Ok(())
        })
        .unwrap();
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(
            pin_hash, fetch_hash,
            "the ordered (pin) and unordered (download) assemblies produced different content for a \
             cross-file-deduped tree"
        );
    }

    #[test]
    fn the_two_write_paths_agree_on_a_file_past_4_gib() {
        // win-data is the first depot this tree pins that holds files over 4 GiB (seven at ~8 GiB), and
        // it is the first whose ordered hash and unordered download disagree. Every depot that verified
        // clean tops out below the boundary (win-binaries 2.83 GB, dlcpacks 2.88 GB, Hollow Knight far
        // less), so a 32-bit step somewhere in the offset arithmetic is the first thing to rule out.
        //
        // A chunk's LENGTH is legitimately u32 — chunks are ~1 MiB — but its OFFSET must stay u64 on
        // both paths: the ordered writer reaches it by accumulating a running position and zero-filling
        // the gaps, the unordered one pwrites there directly. This checks the two produce identical
        // bytes for chunks placed either side of 4 GiB, using a sparse file so it costs no real disk.
        use std::os::unix::fs::FileExt;
        const G: u64 = 1 << 30;
        const CH: u32 = 4096;
        let f = FileEntry {
            path: "big.rpf".into(),
            size: 5 * G,
            executable: false,
            chunks: vec![
                ChunkRef { sha: [1u8; 20], offset: 0, cb_original: CH },
                ChunkRef { sha: [2u8; 20], offset: 4 * G - CH as u64, cb_original: CH },
                ChunkRef { sha: [3u8; 20], offset: 4 * G, cb_original: CH },
                ChunkRef { sha: [4u8; 20], offset: 5 * G - CH as u64, cb_original: CH },
            ],
        };
        let payload = |n: u8| vec![n; CH as usize];

        // Ordered: stream the file's bytes the way the NAR hasher consumes them.
        struct Digest(sha2::Sha256);
        impl std::io::Write for Digest {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                use sha2::Digest as _;
                self.0.update(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
        }
        let mut seq = 1u8;
        let mut d = Digest(<sha2::Sha256 as sha2::Digest>::new());
        write_file(&f, || { let v = payload(seq); seq += 1; Ok(v) }, &mut d).unwrap();
        let ordered_digest = {
            use sha2::Digest as _;
            d.0.finalize().to_vec()
        };

        // Unordered: pre-size the file, then pwrite each chunk at its declared offset.
        let dir = std::env::temp_dir().join(format!("propnix-4gib-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("big.rpf");
        {
            let h = std::fs::File::create(&path).unwrap();
            h.set_len(f.size).unwrap();
            for (i, c) in f.chunks.iter().enumerate() {
                h.write_all_at(&payload(i as u8 + 1), c.offset).unwrap();
            }
            h.sync_all().unwrap();
        }
        let unordered_digest = {
            use sha2::Digest as _;
            let mut h = <sha2::Sha256 as sha2::Digest>::new();
            let mut file = std::fs::File::open(&path).unwrap();
            let mut buf = vec![0u8; 1 << 20];
            loop {
                let n = std::io::Read::read(&mut file, &mut buf).unwrap();
                if n == 0 { break; }
                h.update(&buf[..n]);
            }
            h.finalize().to_vec()
        };
        let _ = std::fs::remove_dir_all(&dir);

        assert_eq!(
            ordered_digest, unordered_digest,
            "the ordered writer and the unordered pwrite disagree about a file spanning 4 GiB"
        );
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

    /// A JWT-shaped token whose payload really is JSON (the shared crate's JWT filter checks that), optionally
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
        let exhausted = |tried: Vec<String>, refusals: Vec<Box<dyn std::error::Error>>| {
            Box::new(SteamError::NotOwned(format!(
                "none of {} ({})",
                tried.join(", "),
                last_refusal(&refusals)
            ))) as Box<dyn std::error::Error>
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
    fn a_refused_login_is_remembered_for_the_process() {
        // Seed the memo the way a refused logon would; the next session_for for that account must fail
        // fast with the same class and NO network attempt — this test runs offline, so even reaching
        // server discovery would fail with a different (Http) class than the one asserted here.
        refused_logins()
            .lock()
            .unwrap()
            .insert("dead-test-account".into(), "token revoked".into());
        let auth = Auth::Account(Credential {
            account: "dead-test-account".into(),
            refresh_token: "x".into(),
        });
        let Err(err) = session_for(&auth) else {
            panic!("a remembered refusal must fail the login");
        };
        assert!(matches!(err, SteamError::LoginFailed(_)), "got: {err}");
        assert!(err.to_string().contains("already refused"), "got: {err}");
    }

    #[test]
    fn an_exhausted_walk_keeps_the_login_failure_class() {
        // The bug this pins: when EVERY account is turned away by a login failure (a stale token, or the
        // rate limiter reporting throttling as "invalid credentials"), the aggregate must classify as a
        // credential problem — NOT as a definitive "no account owns this", which would file a false
        // not-owned issue and, in the walker aggregate, is how 19 depots were once misclassified.
        let refusals: Vec<Box<dyn std::error::Error>> = vec![
            Box::new(SteamError::LoginFailed("throttled".into())),
            Box::new(SteamError::LoginFailed("throttled".into())),
        ];
        let agg = exhausted_steam("all logins refused".into(), &refusals);
        assert!(
            matches!(agg.downcast_ref::<SteamError>(), Some(SteamError::LoginFailed(_))),
            "all-login-failed must aggregate to LoginFailed, got: {agg}"
        );

        // A single login failure mixed with a genuine refusal is still inconclusive — that throttled
        // account might be the owner — so the class stays LoginFailed.
        let mixed: Vec<Box<dyn std::error::Error>> = vec![
            Box::new(SteamError::NotOwned("eresult 2".into())),
            Box::new(SteamError::LoginFailed("throttled".into())),
        ];
        assert!(matches!(
            exhausted_steam("m".into(), &mixed).downcast_ref::<SteamError>(),
            Some(SteamError::LoginFailed(_))
        ));

        // Only when every account genuinely refused a title it could see is it truly NotOwned.
        let owned: Vec<Box<dyn std::error::Error>> = vec![
            Box::new(SteamError::NotOwned("eresult 2".into())),
            Box::new(SteamError::NotOwned("eresult 2".into())),
        ];
        assert!(matches!(
            exhausted_steam("o".into(), &owned).downcast_ref::<SteamError>(),
            Some(SteamError::NotOwned(_))
        ));
    }

    #[test]
    fn truncated_bodies_error_instead_of_panicking() {
        // All three would otherwise abort the process — and a panic inside a decode task ends the run.
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

    /// The 'VZ' framing math, round-tripped through a real LZMA1 stream.
    ///
    /// The container hoists the 5 LZMA1 property bytes into its own header and leaves the raw stream after
    /// them, so the decode side has to slice both back out at exactly the right offsets and supply the
    /// output size from the manifest. Get any of that wrong and chunks decode to garbage — which the sha1
    /// check would catch in production, but only after a download, and only as an opaque mismatch. This is
    /// also what pins the decoder itself: swap the backend and this test says whether it still agrees.
    #[test]
    fn a_vz_container_round_trips_through_the_lzma_decoder() {
        // Compressible, but not so uniform that a bug could coincidentally produce it.
        let original: Vec<u8> = (0..64_000u32).map(|i| (i.wrapping_mul(2654435761) >> 13) as u8).collect();

        // Encode to the `.lzma` alone format, whose first 13 bytes are <5 props><8 size>.
        let opts = liblzma::stream::LzmaOptions::new_preset(6).unwrap();
        let stream = liblzma::stream::Stream::new_lzma_encoder(&opts).unwrap();
        let mut enc =
            liblzma::read::XzEncoder::new_stream(std::io::Cursor::new(original.clone()), stream);
        let mut alone = Vec::new();
        enc.read_to_end(&mut alone).unwrap();
        assert!(alone.len() > 13);

        // Reframe as Steam does: "VZ", 5 bytes we ignore, the 5 property bytes, the raw payload, then a
        // 10-byte footer ending "zv". The 8-byte size field of the alone header is DROPPED — the decoder
        // has to put it back from `expect`, which is the part worth guarding.
        let mut vz = Vec::new();
        vz.extend_from_slice(b"VZ");
        vz.extend_from_slice(&[b'a', 0, 0, 0, 0]);
        vz.extend_from_slice(&alone[0..5]);
        vz.extend_from_slice(&alone[13..]);
        vz.extend_from_slice(&[0u8; 8]);
        vz.extend_from_slice(b"zv");

        let got = decompress_chunk(&vz, original.len()).expect("a well-formed VZ chunk must decode");
        assert_eq!(got, original, "VZ round-trip must be byte-identical");

        // A wrong declared size must be an error, not a silently short buffer.
        assert!(decompress_chunk(&vz, original.len() - 1).is_err());
    }

    /// Per-stage cost accounting for a chunk, in ms of CPU per MiB of depot content.
    ///
    /// Not a correctness test and `#[ignore]`d so it never runs in CI — it exists because "the pin uses a
    /// lot of CPU" is only answerable with absolute numbers per stage. Run it on an OTHERWISE IDLE machine:
    ///
    ///     PROPNIX_BENCH_SAMPLE=/path/to/a/real/game/file \
    ///       cargo test --release bench_chunk_pipeline -- --ignored --nocapture
    ///
    /// Uses real game bytes. Synthetic pseudo-random data is useless here: it compresses to almost
    /// nothing, so LZMA decode degenerates into a memcpy and measures 50x too fast.
    #[test]
    #[ignore]
    fn bench_chunk_pipeline() {
        // Point PROPNIX_BENCH_SAMPLE at any real game file (>= 8 MiB).
        let Some(sample) = std::env::var_os("PROPNIX_BENCH_SAMPLE") else {
            eprintln!("SKIP: set PROPNIX_BENCH_SAMPLE to a real game file (>= 8 MiB)");
            return;
        };
        let Ok(all) = std::fs::read(&sample) else {
            eprintln!("SKIP: cannot read {sample:?}");
            return;
        };
        if all.len() < (8 << 20) {
            eprintln!("SKIP: {sample:?} is under 8 MiB");
            return;
        }
        let plain: Vec<u8> = all[(2 << 20)..(6 << 20)].to_vec();
        let mib = plain.len() as f64 / 1048576.0;

        // Build the VZ container the fetcher actually receives.
        let opts = liblzma::stream::LzmaOptions::new_preset(6).unwrap();
        let stream = liblzma::stream::Stream::new_lzma_encoder(&opts).unwrap();
        let mut enc = liblzma::read::XzEncoder::new_stream(std::io::Cursor::new(plain.clone()), stream);
        let mut alone = Vec::new();
        enc.read_to_end(&mut alone).unwrap();
        let mut vz = Vec::new();
        vz.extend_from_slice(b"VZ");
        vz.extend_from_slice(&[b'a', 0, 0, 0, 0]);
        vz.extend_from_slice(&alone[0..5]);
        vz.extend_from_slice(&alone[13..]);
        vz.extend_from_slice(&[0u8; 8]);
        vz.extend_from_slice(b"zv");
        let key = [7u8; 32];
        let ct = steam_vent_crypto::symmetric_encrypt(bytes::BytesMut::from(&vz[..]), &key);

        let time = |label: &str, reps: usize, mut f: Box<dyn FnMut()>| {
            let t0 = std::time::Instant::now();
            for _ in 0..reps {
                f();
            }
            let ms_per_mib = t0.elapsed().as_secs_f64() * 1000.0 / (mib * reps as f64);
            eprintln!("  {label:<28} {ms_per_mib:>7.2} ms/MiB");
            ms_per_mib
        };

        eprintln!(
            "\nchunk pipeline, {:.0} MiB real sample (compression ratio {:.2}x):",
            mib,
            plain.len() as f64 / vz.len() as f64
        );
        let a = time("AES-256 decrypt (ECB+CBC)", 24, {
            let ct = ct.clone();
            Box::new(move || {
                steam_vent_crypto::symmetric_decrypt_without_hmac(ct.clone(), &key).unwrap();
            })
        });
        let l = time("LZMA decode (VZ)", 12, {
            let vz = vz.clone();
            let n = plain.len();
            Box::new(move || {
                decompress_chunk(&vz, n).unwrap();
            })
        });
        let s1 = time("SHA-1 (chunk id verify)", 24, {
            let plain = plain.clone();
            Box::new(move || {
                use sha1::Digest;
                std::hint::black_box(sha1::Sha1::digest(&plain));
            })
        });
        let s2 = time("SHA-256 (NAR digest)", 24, {
            let plain = plain.clone();
            Box::new(move || {
                use sha2::Digest;
                std::hint::black_box(sha2::Sha256::digest(&plain));
            })
        });
        eprintln!("  {:<28} {:>7.2} ms/MiB", "SUM", a + l + s1 + s2);
        eprintln!(
            "  (LZMA is {:.0}% of the total; a copy of the plaintext is unavoidable on top)",
            l / (a + l + s1 + s2) * 100.0
        );
    }

    /// liblzma vs the 7-Zip LZMA SDK on the SAME container — and a proof they agree byte for byte.
    ///
    ///     PROPNIX_BENCH_SAMPLE=/path/to/a/real/game/file \
    ///       cargo test --release bench_lzma_backends -- --ignored --nocapture
    #[test]
    #[ignore]
    fn bench_lzma_backends() {
        let Some(sample) = std::env::var_os("PROPNIX_BENCH_SAMPLE") else {
            eprintln!("SKIP: set PROPNIX_BENCH_SAMPLE to a real game file (>= 8 MiB)");
            return;
        };
        let Ok(all) = std::fs::read(&sample) else {
            eprintln!("SKIP: cannot read {sample:?}");
            return;
        };
        let plain: Vec<u8> = all[(2 << 20)..(6 << 20)].to_vec();
        let mib = plain.len() as f64 / 1048576.0;

        let opts = liblzma::stream::LzmaOptions::new_preset(6).unwrap();
        let stream = liblzma::stream::Stream::new_lzma_encoder(&opts).unwrap();
        let mut enc = liblzma::read::XzEncoder::new_stream(std::io::Cursor::new(plain.clone()), stream);
        let mut alone = Vec::new();
        enc.read_to_end(&mut alone).unwrap();
        let mut vz = Vec::new();
        vz.extend_from_slice(b"VZ");
        vz.extend_from_slice(&[b'a', 0, 0, 0, 0]);
        vz.extend_from_slice(&alone[0..5]);
        vz.extend_from_slice(&alone[13..]);
        vz.extend_from_slice(&[0u8; 8]);
        vz.extend_from_slice(b"zv");
        let props = &vz[7..12];
        let payload = &vz[12..vz.len() - 10];

        // Correctness first: a faster decoder that disagrees is worthless.
        let a = decompress_chunk(&vz, plain.len()).unwrap();
        let b = sdk_lzma::decode(props, payload, plain.len()).unwrap();
        assert_eq!(a, plain, "liblzma path must reproduce the input");
        assert_eq!(b, plain, "SDK path must reproduce the input");

        let reps = 12;
        let t0 = std::time::Instant::now();
        for _ in 0..reps {
            std::hint::black_box(decompress_chunk(&vz, plain.len()).unwrap());
        }
        let liblzma_ms = t0.elapsed().as_secs_f64() * 1000.0 / (mib * reps as f64);
        let t1 = std::time::Instant::now();
        for _ in 0..reps {
            std::hint::black_box(sdk_lzma::decode(props, payload, plain.len()).unwrap());
        }
        let sdk_ms = t1.elapsed().as_secs_f64() * 1000.0 / (mib * reps as f64);

        eprintln!("\nLZMA1 decode, {mib:.0} MiB real sample:");
        eprintln!("  liblzma (xz 5.8.3)      {liblzma_ms:>7.2} ms/MiB");
        eprintln!("  7-Zip LZMA SDK 25.01    {sdk_ms:>7.2} ms/MiB   ({:.2}x)", liblzma_ms / sdk_ms);
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
) -> Result<(String, nar::Stats, Vec<FileEntry>, PinAnchors), Box<dyn std::error::Error>> {
    // Request codes are single-use and short-lived, so they are fetched together immediately before
    // use. Asking for the previous manifest's code in the same session is what makes the rollback
    // check cost one small extra GET rather than a second login. No cache anchors here on purpose:
    // hashing is what CREATES the anchors, so it always takes the CM path (and warms the cache for the
    // FOD that follows).
    let mut wants = vec![Want { manifest: manifest_id, manifest_sha256: None }];
    if let Some(p) = previous.filter(|p| *p != manifest_id) {
        wants.push(Want { manifest: p, manifest_sha256: None });
    }
    let access = acquire(app_id, depot_id, &wants, None, branch, auth)?;
    let agent = http_agent();
    let m = access.manifest(&agent, manifest_id)?;
    let (files, created) = (m.files, m.created);
    let anchors = PinAnchors {
        depot_key_sha256: access.depot_key_sha256(),
        manifest_sha256: m.sha256,
    };
    // NEVER MOVE BACKWARDS. Steam manifest ids are not ordered, so the only honest comparison is the
    // creation time each manifest carries in its own metadata.
    if let Some(prev) = previous.filter(|p| *p != manifest_id) {
        let prev_created = access.manifest(&agent, prev)?.created;
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
    let mut occ: Vec<ChunkRef> = Vec::new();
    for &&idx in &order {
        let mut cs: Vec<ChunkRef> = files[idx].chunks.clone();
        cs.sort_by_key(|c| c.offset);
        occ.extend(cs);
    }

    // Fetch each DISTINCT chunk once (pin::dedup): a Steam chunk's id IS the sha1 of its plaintext, so
    // equal ids are equal bytes (declared size included out of paranoia). Duplicates the byte budget can
    // hold are served from memory at their later occurrences; the rest simply refetch.
    let keys: Vec<([u8; 20], u32)> = occ.iter().map(|c| (c.sha, c.cb_original)).collect();
    let occ_sizes: Vec<u64> = occ.iter().map(|c| c.cb_original as u64).collect();
    let (mut dedup, fetch) = crate::pin::dedup::plan(&keys, &occ_sizes, opts.window_bytes);
    let (dups, saved) = dedup.stats();
    if dups > 0 {
        eprintln!(
            "  {dups} duplicate chunks will be served from memory ({} MiB of refetch avoided)",
            saved >> 20
        );
    }
    let items: Vec<ChunkRef> = fetch.iter().map(|&i| occ[i].clone()).collect();
    let sizes: Vec<u64> = fetch.iter().map(|&i| occ_sizes[i]).collect();
    let src = std::sync::Arc::new(ChunkSource::new(
        access.hosts.clone(),
        depot_id,
        access.depot_key,
    ));
    let pf = crate::pin::engine::ordered(
        src,
        crate::pin::engine::Work { items, sizes },
        opts.workers,
        opts.window_bytes,
        crate::pin::engine::Tuning::default(),
    )?;

    let mut seen = 0u64;
    let mut last_pct = 0u64;
    let progress = opts.progress;
    let mut next = || dedup.next(|| pf.next_chunk());
    let (sri, stats) = nar::nar_hash(&tree, |idx, w| {
        steam_write(&files[*idx], &mut next, &mut seen, w)?;
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
    // Supersede ONCE, keeping the manifest just pinned — AFTER the hash succeeded. Earlier and a failed
    // hash run would have already evicted the still-current pin's manifest (the rollback probe warmed the
    // cache with `prev`), making every FOD of the unchanged pin pay a login until a successful re-pin.
    // A supersede is deliberately last: worst case on failure is the cache briefly holding both manifests.
    // (No-op when this run took the cache path — nothing new was written — but harmless.)
    crate::pin::steamcache::supersede_manifests(depot_id, &[manifest_id]);
    Ok((sri, stats, files, anchors))
}

/// Download a pinned depot to `dir` — the same pipeline as `hash_depot`, with files as the sink.
///
/// This is what replaces DepotDownloader in the FOD. The tree it writes is the one `tree()` describes,
/// which is exactly what the existing pins hash, so the FOD's content address does not move; see
/// `pin::download` for why that is trustworthy and how to re-check it.
///
/// UNORDERED, unlike hashing. A NAR is one byte stream, so `hash_depot` must receive chunks in tree order
/// and a slow block stalls everything behind it. A file tree has no such constraint: every chunk knows its
/// file and offset, so it can be written with `pwrite` the moment it lands, in whatever order the CDN
/// happens to answer. That removes head-of-line blocking altogether. The byte window survives, but as a
/// MEMORY bound rather than an ordering one: admission stays within `window_bytes` of what the sink has
/// written, so in-flight decoded chunks cannot grow with the governor's limit.
///
/// Sparse regions come free as a result: files are pre-sized with `set_len`, so a range no chunk covers is
/// a hole that reads as zeros — the same bytes `write_file`'s explicit zero-fill produces for the hasher.
///
/// Deliberately NOT hashing as it goes: the FOD mechanism already verifies the result.
pub fn download_depot(
    app_id: u32,
    depot_id: u32,
    manifest_id: u64,
    branch: &str,
    auth: Auth,
    dir: &std::path::Path,
    // The pin's cache trust anchors (versions.json `depotKeySha256`/`manifestSha256`), when the caller
    // has them: with both present and the cache warm, this whole download makes NO Steam login — the
    // control plane is skipped and chunk fetches are anonymous HTTP.
    anchors: Option<(&str, &str)>,
    opts: &crate::pin::gog::HashOpts,
) -> Result<crate::pin::download::Written, Box<dyn std::error::Error>> {
    let (key_sha, manifest_sha) = (anchors.map(|a| a.0), anchors.map(|a| a.1));
    let access = acquire(
        app_id,
        depot_id,
        &[Want { manifest: manifest_id, manifest_sha256: manifest_sha }],
        key_sha,
        branch,
        auth,
    )?;
    write_depot(access, manifest_id, dir, opts)
}

/// Write an already-acquired depot to disk. Split out of `download_depot` so the cache-hit path can be
/// reached WITHOUT a credential: `download_depot_any` calls `acquire_cached` (no auth, no token read)
/// and hands the result straight here, falling back to the credentialed path only on a miss.
pub fn write_depot(
    access: DepotAccess,
    manifest_id: u64,
    dir: &std::path::Path,
    opts: &crate::pin::gog::HashOpts,
) -> Result<crate::pin::download::Written, Box<dyn std::error::Error>> {
    use crate::pin::download;
    use std::os::unix::fs::FileExt;

    let depot_id = access.depot_id;
    let agent = http_agent();
    let files = access.manifest(&agent, manifest_id)?.files;
    // A download fetches exactly this one manifest; drop any older cached manifest for the depot (e.g. the
    // rollback-probe entry a preceding pin left behind), so the cache converges to one manifest per depot.
    crate::pin::steamcache::supersede_manifests(depot_id, &[manifest_id]);

    // Built for its REFUSALS: `tree` is what rejects a malformed manifest, and download must refuse
    // exactly what hashing refuses or the two could disagree about a depot.
    let _ = tree(&files)?;
    let mut written = download::Written::default();
    // Explicit directory entries first: an EMPTY directory is part of the tree the pin hashes, so one
    // that no file happens to create must still exist.
    for f in files.iter().filter(|f| f.size == u64::MAX) {
        download::ensure_dir(dir, &f.path)?;
        written.dirs += 1;
    }

    // Create every file at its final size, and record where each chunk goes. A DISTINCT chunk is fetched
    // once and written to every (file, offset) that references it — a chunk's id IS the sha1 of its
    // plaintext, and manifests reuse ids freely across and within files (declared size in the key out of
    // paranoia).
    let mut handles: Vec<std::sync::Arc<std::fs::File>> = Vec::new();
    let mut work: Vec<ChunkRef> = Vec::new();
    let mut placement: Vec<Vec<(usize, u64)>> = Vec::new();
    let mut slot_of: std::collections::HashMap<([u8; 20], u32), usize> = std::collections::HashMap::new();
    let mut occurrences = 0usize;
    for f in files.iter().filter(|f| f.size != u64::MAX) {
        let file = download::create_file(dir, &f.path, f.executable)?;
        file.set_len(f.size)
            .map_err(|e| format!("set size of {}: {e}", f.path))?;
        let slot = handles.len();
        handles.push(std::sync::Arc::new(file));

        // The overlap/range checks `write_file` performs for the hasher; unordered writes would
        // otherwise silently accept a manifest that describes an impossible file.
        let mut cs: Vec<&ChunkRef> = f.chunks.iter().collect();
        cs.sort_by_key(|c| c.offset);
        let mut pos = 0u64;
        for c in cs {
            if c.offset < pos {
                return Err(format!("{}: chunks overlap at offset {}", f.path, c.offset).into());
            }
            let end = c.offset + c.cb_original as u64;
            if end > f.size {
                return Err(format!(
                    "{}: chunk at {} runs {} bytes past the file's {}",
                    f.path,
                    c.offset,
                    end - f.size,
                    f.size
                )
                .into());
            }
            pos = end;
            occurrences += 1;
            match slot_of.entry((c.sha, c.cb_original)) {
                std::collections::hash_map::Entry::Occupied(e) => {
                    placement[*e.get()].push((slot, c.offset));
                }
                std::collections::hash_map::Entry::Vacant(v) => {
                    v.insert(work.len());
                    placement.push(vec![(slot, c.offset)]);
                    work.push((*c).clone());
                }
            }
        }
        written.files += 1;
        written.bytes += f.size;
    }
    if occurrences > work.len() {
        eprintln!(
            "  {} duplicate chunk references collapse into {} fetches",
            occurrences - work.len(),
            work.len()
        );
    }

    struct DepotSink {
        handles: Vec<std::sync::Arc<std::fs::File>>,
        placement: Vec<Vec<(usize, u64)>>,
    }
    impl crate::pin::engine::Sink for DepotSink {
        fn accept(&self, index: usize, data: Vec<u8>) -> Result<(), String> {
            for &(slot, offset) in &self.placement[index] {
                self.handles[slot]
                    .write_all_at(&data, offset)
                    .map_err(|e| format!("write at offset {offset}: {e}"))?;
            }
            Ok(())
        }
    }

    let sizes: Vec<u64> = work.iter().map(|c| c.cb_original as u64).collect();
    // Progress counts bytes FETCHED (what crosses the wire), so neither deduplicated references nor
    // sparse ranges no chunk covers can leave the bar short of 100%.
    let fetch_total: u64 = sizes.iter().sum();
    let src = std::sync::Arc::new(ChunkSource::new(
        access.hosts.clone(),
        depot_id,
        access.depot_key,
    ));
    let sink = std::sync::Arc::new(DepotSink { handles, placement });
    let mut progress = download::Progress::new(fetch_total.max(1), opts.progress);
    crate::pin::engine::unordered(
        src,
        crate::pin::engine::Work { items: work, sizes },
        opts.workers,
        opts.window_bytes,
        sink,
        crate::pin::engine::Tuning::default(),
        |n| progress.add(n),
    )?;
    progress.finish();
    download::sync_dir(dir)?;
    Ok(written)
}

/// `download_depot` over every stored account, mirroring `hash_depot_any`.
///
/// Ownership is settled by the depot-key request inside `control()`, before a content byte moves, so a
/// wrong account costs a round trip rather than a download.
pub fn download_depot_any(
    app_id: u32,
    depot_id: u32,
    manifest_id: u64,
    branch: &str,
    anonymous: bool,
    dir: &std::path::Path,
    anchors: Option<(&str, &str)>,
    opts: &crate::pin::gog::HashOpts,
) -> Result<crate::pin::download::Written, Box<dyn std::error::Error>> {
    // Cache-first, BEFORE any credential: a warm anchored cache fetches with no login AND no token read
    // at all. This is what the whole cache exists for — and it means a sandboxed FOD can fetch a depot
    // whose credential it cannot even read (e.g. a store whose token ACL the userns builder can't use),
    // as long as a host-side pin has warmed the cache. A miss falls straight through to the CM path.
    if let (Some((ks, ms)), false) = (anchors, anonymous) {
        let wants = [Want { manifest: manifest_id, manifest_sha256: Some(ms) }];
        if let Some(access) = acquire_cached(depot_id, &wants, Some(ks)) {
            return write_depot(access, manifest_id, dir, opts);
        }
    }
    if anonymous {
        return download_depot(
            app_id, depot_id, manifest_id, branch, Auth::Anonymous, dir, anchors, opts,
        );
    }
    let creds = credentials_from_store(&opts.credential_dir, opts.steam_account.as_deref())?;
    // Cache missed (or unanchored): the credentialed account walk. `download_depot` still re-checks the
    // cache per account, but that only matters on a miss, where it is one stat.
    crate::pin::try_accounts(
        &creds,
        |c| c.account.clone(),
        is_not_owned,
        |tried, refusals| {
            exhausted_steam(
                format!(
                    "no stored Steam account can fetch app {app_id} depot {depot_id} manifest \
                     {manifest_id} (tried: {}). Last refusal: {}",
                    tried.join(", "),
                    last_refusal(&refusals)
                ),
                &refusals,
            )
        },
        |c| {
            download_depot(
                app_id,
                depot_id,
                manifest_id,
                branch,
                Auth::Account(c.clone()),
                dir,
                anchors,
                opts,
            )
        },
    )
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
) -> Result<(String, nar::Stats, Vec<FileEntry>, PinAnchors), Box<dyn std::error::Error>> {
    let creds = credentials_from_store(&opts.credential_dir, opts.steam_account.as_deref())?;
    crate::pin::try_accounts(
        &creds,
        |c| c.account.clone(),
        is_not_owned,
        |tried, refusals| {
            exhausted_steam(
                format!(
                    "no stored Steam account can fetch app {app_id} depot {depot_id} manifest \
                     {manifest_id} (tried: {}). Last refusal: {}",
                    tried.join(", "),
                    last_refusal(&refusals)
                ),
                &refusals,
            )
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

/// Is this the kind of Steam failure another stored account might not have? A LOGIN failure counts:
/// one dead/throttled account must not strand the others (though if ALL logons are throttled, the walk
/// reports every account's refusal, message included).
///
/// `&Box<_>` rather than `&dyn Error`: `try_accounts` is generic over its error type, which here IS
/// `Box<dyn Error>`, so the predicate's signature has to match that exactly.
#[allow(clippy::borrowed_box)]
fn is_not_owned(e: &Box<dyn std::error::Error>) -> bool {
    matches!(
        e.downcast_ref::<SteamError>(),
        Some(SteamError::NotOwned(_) | SteamError::LoginFailed(_))
    )
}

/// Aggregate an exhausted account walk into the correct CLASS, given every refusal it collected. If ANY
/// account was turned away by a LOGIN failure the walk says nothing definitive about ownership — that
/// account might own the title but could not log in (a stale token, or the rate limiter reporting
/// throttling as "invalid credentials") — so the aggregate is `LoginFailed`, which classifies as "a human
/// must add a credential or wait", never a false "no account owns this". Only when every account genuinely
/// refused a title it could see (all `NotOwned`) is the aggregate `NotOwned`. This is the same honesty
/// `probe_depots` applies; keeping the decision here means every walker path shares it.
fn exhausted_steam(msg: String, refusals: &[Box<dyn std::error::Error>]) -> Box<dyn std::error::Error> {
    let any_login = refusals
        .iter()
        .any(|e| matches!(e.downcast_ref::<SteamError>(), Some(SteamError::LoginFailed(_))));
    if any_login {
        Box::new(SteamError::LoginFailed(msg))
    } else {
        Box::new(SteamError::NotOwned(msg))
    }
}

/// The "Last refusal: …" tail every Steam exhaustion message carries — the final account's own words.
fn last_refusal(refusals: &[Box<dyn std::error::Error>]) -> String {
    refusals.last().map(|e| e.to_string()).unwrap_or_default()
}

/// Batch ownership probe: which stored account (if any) can fetch each of `depots`? One depot-key
/// request per (account, depot), all over the PROCESS-SHARED CM sessions — a probe costs one login per
/// healthy stored account and one FAILED logon attempt per dead one (`refused_logins` remembers a refusal
/// for the process lifetime, so a dead account never re-pays per depot), where probing depot-by-depot in
/// separate invocations cost one login EACH — the ~90-login burst that Steam's rate limiter shut down
/// mid-run. The fix for a dead account remains `propnix cred add steam`.
///
/// Distinguishes its three outcomes honestly: `Some(account)` = that account fetched the key;
/// `None` = every account that could log in got a genuine refusal (eresult-class, a real "not owned");
/// and a depot no account could both log into AND answer for ABORTS the probe rather than being recorded
/// as unowned — a throttled/stale logon says nothing about ownership, and one probe run misclassifying 19
/// depots as unowned is how we learned that. Crucially, ONE dead account never strands the rest: every
/// account is tried for every depot, and only if the whole set is inconclusive is the depot fatal.
///
/// One residual gap: an account whose stored token is already EXPIRED is dropped by
/// `credentials_from_store` before the walk (a deliberate defense against Steam's logon rate limiter — see
/// there), so a depot owned ONLY by that account is recorded unowned rather than inconclusive. Refreshing
/// the token (`propnix cred add steam`) is the fix; the rate-limit protection is judged worth this edge.
pub fn probe_depots(
    app_id: u32,
    depots: &[u32],
    branch: &str,
    opts: &crate::pin::gog::HashOpts,
) -> Result<Vec<(u32, Option<String>)>, Box<dyn std::error::Error>> {
    let creds = credentials_from_store(&opts.credential_dir, opts.steam_account.as_deref())?;
    let mut out = Vec::new();
    for &depot in depots {
        let mut owner: Option<String> = None;
        // A login failure from one account says nothing about ownership — but the NEXT account might own
        // the depot, so remember the failure and keep going rather than aborting on it. Only if no account
        // can answer definitively (some logon never succeeded, and none owned it) is the depot's ownership
        // genuinely unknowable. Deliberately NOT remembered across depots: a later depot re-tries every
        // account fresh, so a transient throttle on depot N does not poison depot N+1.
        let mut login_failure: Option<SteamError> = None;
        for c in &creds {
            match control(app_id, depot, &[], branch, Auth::Account(c.clone())) {
                Ok(_) => {
                    owner = Some(c.account.clone());
                    break;
                }
                // A logged-in account that genuinely doesn't own it: definitive for this account, advance.
                Err(SteamError::NotOwned(_)) => continue,
                // Could not log in (stale token / throttle): inconclusive for this account, try the rest.
                Err(e @ SteamError::LoginFailed(_)) => {
                    login_failure = Some(e);
                    continue;
                }
                // Transport/parse/etc: a real failure, not an ownership signal — abort now.
                Err(e) => return Err(Box::new(e)),
            }
        }
        match (&owner, login_failure) {
            (Some(_), _) => out.push((depot, owner)),
            // Every account that logged in refused it → genuinely not owned.
            (None, None) => out.push((depot, None)),
            // No account owned it AND at least one never logged in → cannot honestly call it unowned.
            (None, Some(e)) => {
                return Err(Box::new(SteamError::LoginFailed(format!(
                    "app {app_id} depot {depot}: no stored account could both log in and answer for it \
                     (last login failure: {e}); refusing to record it as unowned"
                ))))
            }
        }
    }
    Ok(out)
}

fn steam_write(
    f: &FileEntry,
    next: &mut dyn FnMut() -> Result<Vec<u8>, String>,
    seen: &mut u64,
    w: &mut dyn std::io::Write,
) -> Result<(), nar::NarError> {
    write_file(
        f,
        || {
            let v = next()?;
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

// ──────────────────────────────────── ground-truth tree verification ─────────────────────────────────
/// What `verify_depot` found. `problems` is capped — the first few are diagnostic, the thousandth is not.
#[derive(Default)]
pub struct VerifyReport {
    pub files: usize,
    pub dirs: usize,
    pub chunks: usize,
    pub bad_chunks: usize,
    pub bad_files: usize,
    pub gap_bytes: u64,
    pub problems: Vec<String>,
}

impl VerifyReport {
    fn note(&mut self, msg: String) {
        if self.problems.len() < 40 {
            self.problems.push(msg);
        }
    }
    pub fn ok(&self) -> bool {
        self.bad_chunks == 0 && self.bad_files == 0
    }
}

/// Check a tree ON DISK against the manifest, chunk by chunk — the arbiter when the ordered hasher and
/// the unordered downloader disagree about a depot.
///
/// Neither of those can settle such an argument: each is a candidate answer, and `hash_depot` computed
/// the pins, so "the pin matches the hasher" is very nearly a tautology. This is independent of both.
/// A Steam chunk's id IS the sha1 of its plaintext, so the manifest states, for every (file, offset),
/// exactly which bytes belong there — and that statement comes from Valve, not from this tool.
///
/// Note what this does NOT re-check: the transport already compares each delivered chunk's sha1 against
/// its id before either sink sees it, so chunk CONTENT is sound by construction in both paths. What can
/// still differ is PLACEMENT — which chunk was written where — which is precisely what reading the bytes
/// back and re-hashing them at each declared offset tests.
///
/// Costs one small metadata fetch plus a full sequential read of the tree; no content download.
pub fn verify_depot(
    app_id: u32,
    depot_id: u32,
    manifest_id: u64,
    branch: &str,
    auth: Auth,
    dir: &std::path::Path,
    progress: bool,
) -> Result<VerifyReport, Box<dyn std::error::Error>> {
    use sha1::Digest;
    use std::os::unix::fs::{FileExt, PermissionsExt};

    let ctl = control(app_id, depot_id, &[manifest_id], branch, auth)?;
    let agent = http_agent();
    let code = ctl
        .codes
        .get(&manifest_id)
        .copied()
        .ok_or_else(|| SteamError::Parse(format!("no request code for manifest {manifest_id}")))?;
    let (files, _created) =
        fetch_manifest(&agent, &ctl.hosts, depot_id, manifest_id, code, &ctl.depot_key)?;

    let mut rep = VerifyReport::default();
    let total: u64 = files.iter().filter(|f| f.size != u64::MAX).map(|f| f.size).sum();
    let mut read_so_far = 0u64;
    let mut last_pct = 0u64;

    for f in &files {
        let path = f.path.split('/').fold(dir.to_path_buf(), |p, part| p.join(part));
        if f.size == u64::MAX {
            if !path.is_dir() {
                rep.bad_files += 1;
                rep.note(format!("{}: manifest declares a directory, not present", f.path));
            }
            rep.dirs += 1;
            continue;
        }
        rep.files += 1;
        let file = match std::fs::File::open(&path) {
            Ok(h) => h,
            Err(e) => {
                rep.bad_files += 1;
                rep.note(format!("{}: cannot open: {e}", f.path));
                continue;
            }
        };
        let md = file.metadata()?;
        if md.len() != f.size {
            rep.bad_files += 1;
            rep.note(format!(
                "{}: on-disk size {} != manifest size {}",
                f.path,
                md.len(),
                f.size
            ));
        }
        let is_exec = md.permissions().mode() & 0o111 != 0;
        if is_exec != f.executable {
            rep.bad_files += 1;
            rep.note(format!(
                "{}: exec bit {} but manifest says {}",
                f.path, is_exec, f.executable
            ));
        }

        // Walk the chunks in offset order so gaps (ranges no chunk covers, which must read as zeros)
        // are visible as well as misplaced content.
        let mut cs: Vec<&ChunkRef> = f.chunks.iter().collect();
        cs.sort_by_key(|c| c.offset);
        let mut pos = 0u64;
        let mut buf = Vec::new();
        for c in cs {
            if c.offset > pos {
                rep.gap_bytes += c.offset - pos;
            }
            pos = c.offset + c.cb_original as u64;
            buf.resize(c.cb_original as usize, 0);
            if let Err(e) = file.read_exact_at(&mut buf, c.offset) {
                rep.bad_chunks += 1;
                rep.note(format!("{} @{}: read failed: {e}", f.path, c.offset));
                continue;
            }
            rep.chunks += 1;
            let got: [u8; 20] = sha1::Sha1::digest(&buf).into();
            if got != c.sha {
                rep.bad_chunks += 1;
                rep.note(format!(
                    "{} @{} ({} bytes): sha1 {} but the manifest says {}",
                    f.path,
                    c.offset,
                    c.cb_original,
                    chunk_hex(&got),
                    chunk_hex(&c.sha)
                ));
            }
            read_so_far += c.cb_original as u64;
            if progress {
                let pct = read_so_far
                    .checked_mul(100)
                    .and_then(|n| n.checked_div(total.max(1)))
                    .unwrap_or(100);
                if pct > last_pct {
                    last_pct = pct;
                    eprint!("\r  {pct:3}%  {} / {} MiB verified", read_so_far >> 20, total >> 20);
                }
            }
        }
        if pos < f.size {
            rep.gap_bytes += f.size - pos;
        }
    }
    if progress {
        eprintln!();
    }
    Ok(rep)
}

/// `verify_depot` over every stored account, mirroring `download_depot_any`.
pub fn verify_depot_any(
    app_id: u32,
    depot_id: u32,
    manifest_id: u64,
    branch: &str,
    anonymous: bool,
    dir: &std::path::Path,
    opts: &crate::pin::gog::HashOpts,
) -> Result<VerifyReport, Box<dyn std::error::Error>> {
    if anonymous {
        return verify_depot(app_id, depot_id, manifest_id, branch, Auth::Anonymous, dir, opts.progress);
    }
    let creds = credentials_from_store(&opts.credential_dir, opts.steam_account.as_deref())?;
    crate::pin::try_accounts(
        &creds,
        |c| c.account.clone(),
        is_not_owned,
        |tried, refusals| {
            exhausted_steam(
                format!(
                    "no stored Steam account can fetch app {app_id} depot {depot_id} manifest \
                     {manifest_id} (tried: {}). Last refusal: {}",
                    tried.join(", "),
                    last_refusal(&refusals)
                ),
                &refusals,
            )
        },
        |c| {
            verify_depot(
                app_id,
                depot_id,
                manifest_id,
                branch,
                Auth::Account(c.clone()),
                dir,
                opts.progress,
            )
        },
    )
}
