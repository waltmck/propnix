//! The Steam artifact cache: `<credential store>/cache/steam/` (so `/var/lib/propnix/cache` on the
//! host, `/propnix/cache` inside a build sandbox). It holds the two per-depot artifacts a fetch
//! otherwise needs a CM LOGIN to obtain — the depot decryption key and manifest zips (immutable,
//! content-addressed snapshots) — so a warm cache lets `propnix download steam` run with ZERO Steam
//! logins: chunk downloads themselves are anonymous HTTP. That matters because Steam rate-limits logons
//! harshly (a burst of ~90 reported "invalid credentials" for close to an hour), and every depot of
//! every FOD used to cost one.
//!
//! READ ACCESS matches a token's: the cache dir is setgid `nixbld` and NON-sticky (2777 where the module
//! creates it) and entries are 0640, so an entry is readable only by its creator and the build sandbox,
//! never world-readable. A depot key is a
//! Steam-ownership-gated content-decryption key (the same value for everyone who owns the app, but you
//! must own it to obtain the key) — leaving it world-readable would let any local user reconstruct the
//! game from the public CDN without owning it, so it gets the two-reader treatment credentials get.
//!
//! NEVER TRUSTED ON ITS OWN. The cache is WRITABLE BY EVERY SANDBOXED BUILD on the host — the /propnix
//! bind is global, so any malfunctioning builder may leave arbitrary bytes, wrong lengths, stray
//! symlinks, or half-written files here, and correctness cannot depend on anything read back. So:
//!
//!   * an artifact is used ONLY when its sha256 matches a TRUST ANCHOR recorded in versions.json by the
//!     host-side pin (`depotKeySha256` / `manifestSha256` on the row — the same provenance level as
//!     `outputHash` itself);
//!   * reads refuse symlinks (O_NOFOLLOW — a link left where a cache file belongs would otherwise read
//!     some unrelated file, credentials included), cap sizes BEFORE reading (a runaway builder may have
//!     written something enormous), and treat EVERY irregularity — missing, malformed, wrong hash,
//!     wrong length, IO error — identically: as a cache miss.
//!
//! THE CONTRACT that follows: no cache state, however wrong, can do worse than a MISS — the caller then
//! takes the normal CM login path, which is exactly the status quo. Cache contents can never fail a
//! build, wedge a retry loop, or alter what is fetched (the output stays gated by the FOD hash, and the
//! artifacts are additionally gated by the pin's anchors before use).
//!
//! Writes are strictly best-effort: a read-only store (`cred add` via sudo, no NixOS module, missing
//! dir) silently degrades to the status quo. First writer wins — entries are immutable content, so an
//! existing file is never replaced (and a builder that raced us wrote the same bytes or something the
//! anchor check will reject).

use std::io::Read;
use std::path::PathBuf;

/// Manifests are tens of MB for the largest depots; anything bigger than this is not a manifest we
/// wrote, so don't even read it (the cap bounds the time a wrongly enormous entry can cost a reader).
const MANIFEST_CAP: u64 = 512 << 20;

/// The cache root, derived from the credential-store root exactly like `CredStore::from_env` derives
/// its own (the fetchers export PROPNIX_CRED_DIR=/propnix inside the sandbox, so both sides agree).
fn dir() -> PathBuf {
    let root = std::env::var_os("PROPNIX_CRED_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/propnix"));
    root.join("cache").join("steam")
}

fn key_path(depot: u32) -> PathBuf {
    dir().join(format!("depot-{depot}.key"))
}

fn manifest_path(depot: u32, manifest: u64) -> PathBuf {
    dir().join(format!("manifest-{depot}-{manifest}.zip"))
}

/// Lowercase hex sha256 — the anchor format `pin` records in versions.json. Hex rather than SRI to keep
/// the two anchor fields visually distinct from `outputHash` (which names a whole NAR, not an artifact).
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest;
    let d = sha2::Sha256::digest(bytes);
    let mut s = String::with_capacity(64);
    for b in d {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Read a cache file with the full distrust treatment: O_NOFOLLOW, a size cap checked BEFORE reading,
/// and None for anything that is not a plain, small-enough, readable regular file.
/// Can the current process open this path for reading? (Decides whether a build should keep an existing
/// cache entry or replace it — see `write`.) O_NOFOLLOW so a symlink an entry name was replaced with is
/// treated as unreadable, never followed to some other file.
fn readable(path: &PathBuf) -> bool {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .is_ok()
}

fn read_capped(path: &PathBuf, cap: u64) -> Option<Vec<u8>> {
    use std::os::unix::fs::OpenOptionsExt;
    let f = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let meta = f.metadata().ok()?;
    if !meta.is_file() || meta.len() > cap {
        return None;
    }
    let mut buf = Vec::with_capacity(meta.len() as usize);
    // take(cap+1): even if the file grows between stat and read (a writer racing us), never read past
    // the cap — the hash check below rejects whatever we got either way.
    f.take(cap + 1).read_to_end(&mut buf).ok()?;
    if buf.len() as u64 > cap {
        return None;
    }
    Some(buf)
}

/// The depot key, ONLY if it hashes to the pin-recorded anchor. `want_hex` comes from versions.json.
pub fn read_key(depot: u32, want_hex: &str) -> Option<[u8; 32]> {
    let bytes = read_capped(&key_path(depot), 64)?;
    if bytes.len() != 32 || sha256_hex(&bytes) != want_hex {
        return None;
    }
    bytes.as_slice().try_into().ok()
}

/// Raw manifest zip bytes, ONLY if they hash to the pin-recorded anchor.
pub fn read_manifest(depot: u32, manifest: u64, want_hex: &str) -> Option<Vec<u8>> {
    let bytes = read_capped(&manifest_path(depot, manifest), MANIFEST_CAP)?;
    if sha256_hex(&bytes) != want_hex {
        return None;
    }
    Some(bytes)
}

/// Best-effort write: temp file (O_EXCL, unpredictable name, mode 0640) + rename, every failure
/// swallowed. Two permission properties matter here, mirroring the token contract exactly:
///
///   * the cache DIR is world-writable + NON-sticky (a module store also setgid `nixbld`) — so the NEXT
///     writer (a different human's pin, or a sandboxed builder as `nixbldN`) can warm the same cache. NO privilege
///     is ever required (a sandboxed FOD cannot sudo), so the dir is not root-managed: a module store
///     pre-creates it setgid `nixbld` (left untouched); a plain store gets a self-created 1777 dir.
///   * each ENTRY is 0640, owned by its WRITER, group = the writer's primary group. A depot key is an
///     ownership-gated content-decryption key, so it must NOT be world-readable. It is not chgrp'd to
///     any group (that would need privilege): a build user's primary group is already `nixbld`, so an
///     entry a build writes is readable by every build; an entry a human's pin writes stays the human's
///     (a build then simply misses it and logs in). On a module store the setgid dir additionally lands
///     even host-written entries in `nixbld`, so there the pin→build handoff is cache-hot too.
fn write(path: &PathBuf, bytes: &[u8]) {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if path.exists() {
        // An entry already exists. Keep it UNLESS we are a build that cannot read it: a host-side pin's
        // entry carries the human's group, unreadable by a build, and would otherwise permanently block
        // the build from warming its own readable copy (self-heal, non-sticky dir makes the unlink
        // possible). A host-side pin, by contrast, NEVER clobbers — that keeps a good build-written entry
        // from ping-ponging with a futile host rewrite. `NIX_BUILD_TOP` marks the in-build case.
        let in_build = std::env::var_os("NIX_BUILD_TOP").is_some();
        if !in_build || readable(path) || std::fs::remove_file(path).is_err() {
            return;
        }
    }
    let Some(parent) = path.parent() else { return };
    // Only perm a dir WE create, never one that already exists — a module-managed store pre-creates
    // `cache/steam` setgid `nixbld`, and re-chmod'ing it (could we) would strip that. On our own dir we
    // set 0777: world-writable so any writer adds an entry, and NON-sticky so a build can replace a
    // host's unreadable entry (see above). NOT setgid, so each entry takes its WRITER'S primary group —
    // a build user's is `nixbld`, so build-written entries are shared across all builds unprivileged; a
    // host pin's stay the human's (a build misses them, replaces with its own).
    let leaf_new = !parent.is_dir();
    if std::fs::create_dir_all(parent).is_err() {
        return;
    }
    if leaf_new {
        let _ = std::fs::set_permissions(parent, PermissionsExt::from_mode(0o0777));
        if let Some(gp) = parent.parent() {
            let _ = std::fs::set_permissions(gp, PermissionsExt::from_mode(0o0777));
        }
    }
    // A per-process counter plus the sub-second nonce keeps two writers of the SAME entry from picking the
    // same temp name (pid can repeat across sandboxes). Load-bearing together with the ownership rule
    // below: we must only ever remove a temp WE created, never unlink one an O_EXCL collision means belongs
    // to another writer mid-flight.
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = parent.join(format!(
        ".tmp-{}-{nonce:09}-{seq}-{}",
        std::process::id(),
        path.file_name().and_then(|n| n.to_str()).unwrap_or("cache")
    ));
    // mode 0640: owner (the writer) + group only, never `other`. The group is the writer's — a build's is
    // `nixbld`, so builds share; a human's stays private. Not world-readable either way. `create_new`
    // (O_EXCL) means a name collision returns AlreadyExists WITHOUT opening — we did not create that file,
    // so we must not remove it (it is another writer's temp; the non-sticky dir would otherwise let us
    // delete it out from under them).
    let f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o640)
        .open(&tmp);
    let Ok(mut f) = f else { return };
    use std::io::Write;
    if f.write_all(bytes).is_ok() && std::fs::rename(&tmp, path).is_ok() {
        return;
    }
    let _ = std::fs::remove_file(&tmp); // ours — write or rename failed, clean it up
}

pub fn write_key(depot: u32, key: &[u8; 32]) {
    write(&key_path(depot), key);
}

pub fn write_manifest(depot: u32, manifest: u64, bytes: &[u8]) {
    write(&manifest_path(depot, manifest), bytes);
}

/// A depot keeps only its CURRENT manifest(s) in the cache: unlink every `manifest-<depot>-*.zip` whose id
/// is not in `keep`. Without this the cache would grow by one entry every time a game shipped an update
/// (each a new manifest id), unbounded over a title's lifetime. With it — plus the single per-depot key,
/// which never versions — the cache holds ~1 manifest + 1 key per DEPOT, independent of how many users or
/// accounts touched it.
///
/// `keep` is a SET, not a single id, and this is called ONCE by the caller AFTER it has finished fetching
/// every manifest it needs this run — NOT from `write_manifest`. That is load-bearing: a re-pin fetches
/// two manifests for one depot (the new one, plus the previously-pinned one for the never-move-backwards
/// check), and a per-write supersede would have the second write delete the first — silently leaving the
/// cache holding the OLD manifest and defeating the pin→build handoff on every update.
///
/// Also sweeps orphaned `.tmp-*` staging files older than an hour (a crash between create and rename
/// leaves one; nothing else reaps them). Best-effort throughout: the non-sticky dir lets any writer unlink
/// a stale entry, and one we cannot remove is at worst a stale file a later run supersedes — never a
/// correctness issue, since reads are anchor-verified.
pub fn supersede_manifests(depot: u32, keep: &[u64]) {
    let prefix = format!("manifest-{depot}-");
    let keep_names: Vec<String> = keep
        .iter()
        .map(|m| format!("manifest-{depot}-{m}.zip"))
        .collect();
    let Ok(rd) = std::fs::read_dir(dir()) else {
        return;
    };
    let hour_ago = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(3600));
    for e in rd.flatten() {
        let p = e.path();
        let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let is_stale_manifest =
            name.starts_with(&prefix) && name.ends_with(".zip") && !keep_names.iter().any(|k| k == name);
        let is_old_temp = name.starts_with(".tmp-")
            && hour_ago.is_some_and(|cut| {
                e.metadata()
                    .and_then(|m| m.modified())
                    .map(|t| t < cut)
                    .unwrap_or(false)
            });
        if is_stale_manifest || is_old_temp {
            let _ = std::fs::remove_file(&p);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Point the cache at a private root for one test, restoring after. Tests that mutate the env are
    /// serialized by this lock so parallel tests cannot see each other's roots.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn with_root<R>(tag: &str, f: impl FnOnce() -> R) -> R {
        let _guard = ENV_LOCK.lock().unwrap();
        let root = std::env::temp_dir().join(format!(
            "propnix-steamcache-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let old = std::env::var_os("PROPNIX_CRED_DIR");
        std::env::set_var("PROPNIX_CRED_DIR", &root);
        let out = f();
        match old {
            Some(v) => std::env::set_var("PROPNIX_CRED_DIR", v),
            None => std::env::remove_var("PROPNIX_CRED_DIR"),
        }
        out
    }

    #[test]
    fn cache_dir_is_world_writable_and_non_sticky() {
        use std::os::unix::fs::PermissionsExt;
        with_root("dirperms", || {
            write_key(1, &[0u8; 32]);
            let mode = std::fs::metadata(dir()).unwrap().permissions().mode() & 0o7777;
            assert_eq!(
                mode, 0o777,
                "a self-created cache dir must be world-writable (any writer warms it) and NON-sticky \
                 (a build can replace an entry it can't read), got {mode:o}"
            );
        })
    }

    #[test]
    fn a_host_pin_never_clobbers_but_a_build_replaces_an_unreadable_entry() {
        use std::os::unix::fs::PermissionsExt;
        with_root("clobber", || {
            // Not in a build: an existing entry is kept, never overwritten (avoids a host pin ping-
            // ponging a good build-written entry).
            std::env::remove_var("NIX_BUILD_TOP");
            let first = [1u8; 32];
            write_key(3, &first);
            write_key(3, &[2u8; 32]); // must NOT replace
            assert_eq!(read_key(3, &sha256_hex(&first)), Some(first), "host pin must not clobber");

            // A build, meeting an entry it cannot read (here simulated by chmod 0000 — unreadable even to
            // the owner), replaces it with its own readable copy.
            std::fs::set_permissions(&super::key_path(3), PermissionsExt::from_mode(0o000)).unwrap();
            assert!(!super::readable(&super::key_path(3)), "0000 entry must read as unreadable");
            std::env::set_var("NIX_BUILD_TOP", "/build/x");
            let healed = [7u8; 32];
            write_key(3, &healed);
            std::env::remove_var("NIX_BUILD_TOP");
            assert_eq!(
                read_key(3, &sha256_hex(&healed)),
                Some(healed),
                "a build must self-heal an entry it could not read"
            );
        })
    }

    #[test]
    fn supersede_keeps_the_named_manifests_and_prunes_the_rest() {
        with_root("supersede", || {
            std::env::remove_var("NIX_BUILD_TOP");
            // A depot with two live manifests THIS run fetched (the pinned one + the rollback probe), a
            // stale older one, and an unrelated depot's manifest that must survive.
            write_manifest(5, 100, b"keep-a");
            write_manifest(5, 200, b"keep-b");
            std::fs::write(super::manifest_path(5, 99), b"stale").unwrap();
            std::fs::write(super::manifest_path(6, 42), b"other-depot").unwrap();
            // Supersede is CALLER-driven and takes the full keep-set — crucially it must NOT delete a
            // manifest this same run just wrote (the re-pin double-fetch bug).
            supersede_manifests(5, &[100, 200]);
            assert!(super::manifest_path(5, 100).exists(), "a kept manifest stays");
            assert!(super::manifest_path(5, 200).exists(), "the second kept manifest stays too");
            assert!(!super::manifest_path(5, 99).exists(), "depot 5's stale manifest is pruned");
            assert!(super::manifest_path(6, 42).exists(), "another depot's manifest is untouched");
        })
    }

    #[test]
    fn write_manifest_alone_does_not_prune_a_sibling() {
        with_root("no-prune-on-write", || {
            std::env::remove_var("NIX_BUILD_TOP");
            // Two manifests for one depot written back-to-back (the re-pin case): the SECOND write must
            // not delete the first — supersede is no longer coupled to write_manifest.
            write_manifest(7, 100, b"first");
            write_manifest(7, 200, b"second");
            assert!(super::manifest_path(7, 100).exists(), "write_manifest must not prune a sibling");
            assert!(super::manifest_path(7, 200).exists());
        })
    }

    #[test]
    fn roundtrip_is_anchored_and_wrong_bytes_are_a_miss() {
        with_root("rt", || {
            let key = [7u8; 32];
            let want = sha256_hex(&key);
            assert!(read_key(1, &want).is_none(), "empty cache must miss");
            write_key(1, &key);
            assert_eq!(read_key(1, &want), Some(key), "anchored read must hit");
            assert!(
                read_key(1, &sha256_hex(b"something else")).is_none(),
                "an anchor mismatch must be a miss, never an error"
            );

            let m = b"not really a manifest, the anchor is the only judge".to_vec();
            let want_m = sha256_hex(&m);
            write_manifest(1, 42, &m);
            assert_eq!(read_manifest(1, 42, &want_m), Some(m));
            // What a malfunctioning builder leaves behind: some other bytes under the same name.
            std::fs::write(super::manifest_path(1, 42), b"scribble").unwrap();
            assert!(
                read_manifest(1, 42, &want_m).is_none(),
                "wrong bytes must read as a miss, never an error"
            );
        })
    }

    #[test]
    fn a_symlinked_cache_entry_is_never_followed() {
        with_root("sym", || {
            // A link left where a cache file belongs would otherwise read whatever it points at —
            // possibly an unrelated file whose bytes happen to verify. Refuse the link itself.
            let elsewhere = std::env::temp_dir().join(format!("propnix-cache-elsewhere-{}", std::process::id()));
            std::fs::write(&elsewhere, [9u8; 32]).unwrap();
            let kp = super::key_path(3);
            std::fs::create_dir_all(kp.parent().unwrap()).unwrap();
            std::os::unix::fs::symlink(&elsewhere, &kp).unwrap();
            let want = sha256_hex(&[9u8; 32]);
            assert!(read_key(3, &want).is_none(), "a symlink is a miss, not a readable entry");
            let _ = std::fs::remove_file(&elsewhere);
        })
    }

    #[test]
    fn oversize_and_short_entries_miss() {
        with_root("size", || {
            let kp = super::key_path(5);
            std::fs::create_dir_all(kp.parent().unwrap()).unwrap();
            std::fs::write(&kp, [1u8; 16]).unwrap(); // wrong length
            assert!(read_key(5, &sha256_hex(&[1u8; 16])).is_none(), "a 16-byte key is not a key");
            std::fs::write(&kp, [1u8; 65]).unwrap(); // over the key cap
            assert!(read_key(5, &sha256_hex(&[1u8; 65])).is_none());
        })
    }

    #[test]
    fn first_writer_wins() {
        with_root("fww", || {
            let a = [1u8; 32];
            let b = [2u8; 32];
            write_key(9, &a);
            write_key(9, &b); // must NOT replace
            assert_eq!(read_key(9, &sha256_hex(&a)), Some(a));
            assert!(read_key(9, &sha256_hex(&b)).is_none());
        })
    }
}
