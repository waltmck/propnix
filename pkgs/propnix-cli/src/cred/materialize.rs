//! `propnix cred materialize <config.json>` — the root-run credential-store materializer the NixOS module
//! invokes at activation. It replaces the long shell script the module used to inline
//! (`systemd.services.propnix-credentials`): assemble the store root + pointer, copy every DECLARED token
//! into `<root>/<type>/<username>/<file>`, prune tokens a previous generation declared and this one does
//! not, record the world-readable manifest the CLI reads to answer "is this account declarative?", and
//! CONVERGE the whole store onto the group-ownership contract (type dirs setgid+sticky+world-writable,
//! account dirs 2750, tokens 0640, all group-owned by the build-users group, with any ACL-era xattrs
//! stripped).
//!
//! WHY RUST, AND WHY FILE DESCRIPTORS. The type dirs are world-writable (the `/tmp` model that lets any
//! human `cred add` without privilege), so every entry beneath them can be something another user created
//! — including a symlink pointing at an unrelated part of the system. The shell version guarded each step
//! with `[ ! -L ]` and `chgrp --no-dereference`, but a path-based `chmod` ALWAYS follows symlinks and has
//! no `--no-dereference`, leaving a check-then-chmod race the shell could not close: swap the entry for a
//! symlink between the test and the chmod and root re-modes whatever it points at. Here every mutation is
//! done on a FILE DESCRIPTOR opened with `O_NOFOLLOW` (`fchmod`/`fchown`/`fremovexattr`), and every
//! descent is an `openat` relative to the parent's descriptor. An `fd` is bound to the inode it was opened
//! on; a later path swap cannot redirect an `fchmod` on it, and a symlink at the moment of `openat`
//! fails with `ELOOP` and is skipped. The race is closed by construction, not by timing.
//!
//! PARAMETERIZED OWNERSHIP. The real service runs as root and stamps everything `root`-owned; the config
//! carries the owner uid and the group names so the whole pipeline can also run UNPRIVILEGED under `cargo
//! test`, stamping the test user's own uid/gid (an `fchown` to yourself and an `fchmod` that sets setgid
//! on a group you belong to both succeed without privilege, so the identical code path is exercised).

use serde::Deserialize;
use std::collections::BTreeSet;
use std::ffi::{CStr, CString, OsStr, OsString};
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;

/// The activation config the NixOS module renders (one JSON object). Group fields are names on the real
/// service (`propnix`, `nixbld`, `root`) and numeric gids under test; both resolve through `resolve_gid`.
#[derive(Deserialize)]
pub struct Config {
    /// The store root (`services.propnix.credentialsPath`).
    root: String,
    /// Who owns everything the materializer writes: 0 (root) on the service; the invoking uid under test.
    owner_uid: u32,
    /// Group of the store ROOT dir (2775) — the humans who may manage the store (`propnix`).
    root_group: String,
    /// Group every TYPE dir / account dir / token is owned by — the build-users group (`nixbld`), the one
    /// gid a user-namespaced builder keeps, so plain group bits are what let a sandboxed fetch read a token.
    build_group: String,
    /// Group of the non-secret, world-readable pointer + manifest (`root` on the service).
    meta_group: String,
    /// The `credentials.toml` body (names the in-sandbox root; holds no secret).
    pointer_body: String,
    /// `<root>-declarative-credentials` — the manifest, a SIBLING of the store (never inside it: the store
    /// is bound into the build sandbox and must carry only authentication).
    manifest_path: String,
    /// Known token types, for the convergence sweep (unioned with the declared types below).
    types: Vec<String>,
    /// The declared credentials to install this generation.
    credentials: Vec<CredEntry>,
}

#[derive(Deserialize)]
struct CredEntry {
    r#type: String,
    username: String,
    /// The token filename under `<root>/<type>/<username>/`.
    file: String,
    /// The already-decrypted source path (sops-nix/agenix runtime path) to copy from.
    source: String,
}

const UID_UNCHANGED: libc::uid_t = libc::uid_t::MAX; // (uid_t)-1 → fchown leaves the owner as-is

pub fn materialize(config_path: &Path) -> Result<(), String> {
    let raw = std::fs::read(config_path)
        .map_err(|e| format!("reading materialize config {}: {e}", config_path.display()))?;
    let cfg: Config = serde_json::from_slice(&raw)
        .map_err(|e| format!("parsing materialize config {}: {e}", config_path.display()))?;

    let root_gid = resolve_gid(&cfg.root_group)?;
    let build_gid = resolve_gid(&cfg.build_group)?;
    let meta_gid = resolve_gid(&cfg.meta_group)?;
    let uid = cfg.owner_uid;

    // Accumulate non-fatal failures (a single unreadable secret, a foreign entry we refuse to touch) the
    // way the shell set `rc=1` and kept going: do everything possible, then report failure at the end so a
    // sysadmin sees it without one bad account stranding the rest.
    let mut failed = false;
    macro_rules! soft {
        ($res:expr) => {
            if let Err(e) = $res {
                eprintln!("propnix: {e}");
                failed = true;
            }
        };
    }

    // 1. The store root. In /var/lib (root-controlled), so following the path here matches the old
    //    `install -d` and is not part of the world-writable danger zone.
    ensure_root_dir(&cfg.root, uid, root_gid)?;
    let root = open_dir_follow(Path::new(&cfg.root))
        .map_err(|e| format!("opening store root {}: {e}", cfg.root))?;

    // 2. The non-secret pointer, root-owned 0644.
    soft!(write_root_file(root.as_raw_fd(), "credentials.toml", cfg.pointer_body.as_bytes(), uid, meta_gid));

    // 3. Install every declared token, tracking which ones actually materialized. `declared` is the set the
    //    config NAMES; `installed` is the subset that reached disk as a real declarative (root-owned) token.
    //    The distinction is load-bearing for step 4: the manifest must reflect DECLARATIVE REALITY, not
    //    mere intent, or an imperative token that a declaration failed to displace would be mislabelled and
    //    later pruned.
    let declared: BTreeSet<String> = cfg
        .credentials
        .iter()
        .map(|c| format!("{}/{}/{}", c.r#type, c.username, c.file))
        .collect();
    let mut installed: BTreeSet<String> = BTreeSet::new();
    for c in &cfg.credentials {
        match install_cred(root.as_raw_fd(), c, uid, build_gid) {
            Ok(()) => {
                installed.insert(format!("{}/{}/{}", c.r#type, c.username, c.file));
            }
            Err(e) => {
                eprintln!("propnix: {e}");
                failed = true;
            }
        }
    }

    // 4. Prune tokens a previous generation declared and this one no longer does, then record the manifest.
    //    Read the OLD manifest first (prune compares against it). A dropped entry is one in the old manifest
    //    but NOT declared now; prune removes only those, and only from ROOT-OWNED account dirs, so a
    //    user-owned imperative token can never be deleted even if a manifest entry ever named its path.
    let old_manifest: BTreeSet<String> = std::fs::read_to_string(&cfg.manifest_path)
        .map(|s| s.lines().filter(|l| !l.is_empty()).map(str::to_string).collect())
        .unwrap_or_default();
    let to_remove: Vec<String> = old_manifest.difference(&declared).cloned().collect();
    // `kept` MUST reach the manifest even when the prune reports failure — keeping the unremovable entry
    // named is precisely how it gets retried next generation instead of orphaned (a `Result` here would
    // conflate "some failed" with "discard the survivors", which is exactly the bug it once had).
    let (kept_failed, prune_failed) = prune(&root, &to_remove, uid);
    if prune_failed {
        eprintln!(
            "propnix: {} dropped credential(s) could not be pruned — kept in the manifest to retry at \
             the next activation",
            kept_failed.len()
        );
        failed = true;
    }
    // The manifest = what is DECLARATIVE on disk now: entries still declared that were already declarative
    // (kept even if this run's re-copy transiently failed) ∪ freshly installed ∪ entries we tried to drop
    // but could not remove (still on disk, still managed — retried next generation). A newly-declared entry
    // whose install failed is deliberately absent: nothing was materialized, so it is not yet declarative.
    let mut manifest: BTreeSet<String> =
        old_manifest.intersection(&declared).cloned().collect();
    manifest.extend(installed);
    manifest.extend(kept_failed);
    soft!(write_manifest(&cfg.manifest_path, &manifest, uid, meta_gid));

    // 5. Converge the store onto the contract. First ensure every KNOWN type dir EXISTS (prune above may
    //    have tidied an emptied one away; the contract wants them always present so an unprivileged
    //    `cred add` needs no dir creation). Then sweep the dirs actually under the root — but apply the
    //    type-dir contract ONLY to (a) known/declared types and (b) dirs already carrying the build group,
    //    i.e. dirs a previous generation's sweep created (this is what keeps a custom type DROPPED from the
    //    config converged forever). Anything else at the root level is some member's own creation: stamping
    //    it 3777/build-group would make previously-private content world-creatable-into and build-readable,
    //    which no convergence should ever do. The `cache/` sibling has its own world-writable contract and
    //    is never touched; the pointer and this materializer's root-level temps are reaped/skipped by name.
    let mut known: BTreeSet<&str> = cfg.types.iter().map(String::as_str).collect();
    known.extend(cfg.credentials.iter().map(|c| c.r#type.as_str()));
    for t in &known {
        if let Err(e) = check_component("type", t) {
            eprintln!("propnix: {e}");
            failed = true;
            continue;
        }
        if *t == "cache" {
            eprintln!("propnix: 'cache' is the artifact cache, not a credential type — skipped");
            failed = true;
            continue;
        }
        soft!(ensure_type_dir(root.as_raw_fd(), t, uid, build_gid).map(|_| ()).map_err(|e| format!("{t}: {e}")));
    }
    let type_dirs = match read_dir_names(root.as_raw_fd()) {
        Ok(names) => names,
        Err(e) => {
            eprintln!("propnix: listing store root: {e}");
            failed = true;
            Vec::new()
        }
    };
    for name in type_dirs {
        if name == "cache" || name == "credentials.toml" {
            continue; // the artifact cache's own contract / the pointer we wrote ourselves
        }
        let lossy = name.to_string_lossy().into_owned();
        // Reap a crashed run's root-level temp (non-secret — the pointer body — but litter).
        if lossy.starts_with('.') && lossy.ends_with(".tmp") {
            if let Ok(_fd) = open_child_file_nofollow(root.as_raw_fd(), &name) {
                let _ = unlinkat(root.as_raw_fd(), &name, 0);
            }
            continue;
        }
        if !known.contains(lossy.as_str()) {
            // Converge an unknown dir only if a previous generation's sweep already made it a type dir —
            // recognizable as group = the build group AND world-writable (every shape the contract ever
            // stamps is; no member's private dir is). Anything else is a member's own creation: leave it
            // alone, or convergence would WIDEN it (3777, build-group contents) instead of tightening.
            match open_child_dir_nofollow(root.as_raw_fd(), &name) {
                Ok(fd) => match fstat(fd.as_raw_fd()) {
                    Ok(st) if st.st_gid == build_gid && st.st_mode & 0o002 != 0 => {}
                    Ok(_) => {
                        eprintln!("propnix: {lossy}: not a credential type dir — left alone");
                        continue;
                    }
                    Err(_) => continue,
                },
                Err(_) => continue, // not a real directory (a symlink, a stray file) — not a type dir
            }
        }
        soft!(converge_type(root.as_raw_fd(), &name, build_gid));
    }

    if failed {
        Err(format!(
            "one or more credential operations failed under {} (see the messages above)",
            cfg.root
        ))
    } else {
        Ok(())
    }
}

// ── the store root and the two world-readable files ────────────────────────────────────────────────────

/// Create the store root if absent and bring it to policy (2775, owner:root_group) — group-writable by the
/// managing group + setgid so members manage the store without sudo. Trusted location, so path-based.
fn ensure_root_dir(root: &str, uid: u32, gid: u32) -> Result<(), String> {
    let p = Path::new(root);
    if !p.is_dir() {
        std::fs::create_dir_all(p).map_err(|e| format!("creating store root {root}: {e}"))?;
    }
    let fd = open_dir_follow(p).map_err(|e| format!("opening store root {root}: {e}"))?;
    fchown(fd.as_raw_fd(), uid, gid).map_err(|e| format!("chown store root {root}: {e}"))?;
    fchmod_dir(fd.as_raw_fd(), 0o2775).map_err(|e| format!("chmod store root {root}: {e}"))?;
    Ok(())
}

/// Write a world-readable non-secret file directly under the (trusted) store root: atomic sibling temp +
/// `renameat`, `O_NOFOLLOW` throughout, 0644 owner:meta_group.
fn write_root_file(root_fd: RawFd, name: &str, body: &[u8], uid: u32, gid: u32) -> Result<(), String> {
    write_file_at(root_fd, name, body, 0o644, uid, gid).map_err(|e| format!("writing {name}: {e}"))
}

/// Write the declarative manifest (a SIBLING of the store root): one managed store-relative path per line,
/// world-readable, root-owned. Its directory is root-controlled, so a same-dir temp + rename is enough.
fn write_manifest(manifest_path: &str, managed: &BTreeSet<String>, uid: u32, gid: u32) -> Result<(), String> {
    let body: String = managed.iter().map(|l| format!("{l}\n")).collect();
    let path = Path::new(manifest_path);
    let dir = path
        .parent()
        .ok_or_else(|| format!("manifest path {manifest_path} has no parent"))?;
    let name = path
        .file_name()
        .ok_or_else(|| format!("manifest path {manifest_path} has no file name"))?;
    let dir_fd = open_dir_follow(dir).map_err(|e| format!("opening {}: {e}", dir.display()))?;
    let name = name.to_string_lossy();
    write_file_at(dir_fd.as_raw_fd(), &name, body.as_bytes(), 0o644, uid, gid)
        .map_err(|e| format!("writing manifest {manifest_path}: {e}"))
}

// ── install one declared credential ─────────────────────────────────────────────────────────────────────

/// Copy one decrypted token into `<root>/<type>/<username>/<file>`, creating the type + account dirs to
/// contract. The account level is CLAIMED so no unprivileged swap can slip past: an existing entry is used
/// only if it is a real directory owned by us (in the sticky type dir, nobody but the owner or root can
/// replace one of our entries), and an absent one is made with `mkdirat` — which, unlike a path `install
/// -d`, refuses to dereference anything that races in (EEXIST, symlink included). Every mode/owner change
/// rides the resulting descriptor.
fn install_cred(root_fd: RawFd, c: &CredEntry, uid: u32, build_gid: u32) -> Result<(), String> {
    let who = format!("{}/{}", c.r#type, c.username);
    // Each field is exactly ONE path level. Reject `.`/`..`/`/`/newline/empty — the NixOS assertions cover
    // most of these at eval time, but `.` was a gap (it collapses a level: `type="."` would stamp the store
    // ROOT 3777), and the token file must not collide with the crashed-temp reap pattern (`.<x>.tmp`) or
    // convergence would delete it the same run. Validate here so the CLI is safe on any config, module or not.
    check_component("account type", &c.r#type)?;
    check_component("username", &c.username)?;
    check_component("tokenFile", &c.file)?;
    if c.file.starts_with('.') && c.file.ends_with(".tmp") {
        return Err(format!("{who}: tokenFile {:?} collides with the temp-reap pattern", c.file));
    }
    // `cache` is the artifact-cache sibling with its own (world-writable, non-sticky, non-secret) contract;
    // installing a credential "type" there would re-stamp it to the token contract, break the cache's
    // self-heal semantics, and hide the account from `cred list` (which filters the name).
    if c.r#type == "cache" {
        return Err(format!("{who}: 'cache' is the artifact cache, not a credential type"));
    }

    let token = std::fs::read(&c.source)
        .map_err(|e| format!("{who}: reading credential source {}: {e}", c.source))?;

    let type_fd = ensure_type_dir(root_fd, &c.r#type, uid, build_gid)
        .map_err(|e| format!("{who}: {e}"))?;
    let acct_fd = claim_account_dir(type_fd.as_raw_fd(), &c.username, uid, build_gid)
        .map_err(|e| format!("{who}: {e}"))?;

    write_file_at(acct_fd.as_raw_fd(), &c.file, &token, 0o640, uid, build_gid)
        .map_err(|e| format!("{who}: installing token: {e}"))
}

/// Open the type dir, creating it (setgid+sticky+world-writable) if absent, refusing a symlink. In the
/// store ROOT, whose entries only the managing group can swap, so this needs no owner check.
fn ensure_type_dir(root_fd: RawFd, name: &str, uid: u32, gid: u32) -> io::Result<OwnedFd> {
    let fd = match open_child_dir_nofollow(root_fd, name) {
        Ok(fd) => fd,
        Err(e) if e.raw_os_error() == Some(libc::ENOENT) => {
            mkdirat(root_fd, name, 0o3777)?;
            open_child_dir_nofollow(root_fd, name)?
        }
        Err(e) => return Err(e),
    };
    fchown(fd.as_raw_fd(), uid, gid)?;
    fchmod_dir(fd.as_raw_fd(), 0o3777)?;
    Ok(fd)
}

/// Claim the account dir: an existing entry is accepted only if it is a real directory owned by `uid` (or
/// root); anything else — a symlink, a plain file, another user's dir — is refused. An absent one is made
/// with `mkdirat`. Then converge it (2750, owner:build_gid) on the returned descriptor.
fn claim_account_dir(type_fd: RawFd, name: &str, uid: u32, gid: u32) -> io::Result<OwnedFd> {
    let fd = match open_child_dir_nofollow(type_fd, name) {
        Ok(fd) => {
            let st = fstat(fd.as_raw_fd())?;
            if st.st_uid != uid && st.st_uid != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "account dir belongs to uid {} — refusing to install into it; remove it (or have \
                         its owner run `propnix cred rm`) so the module can claim the account",
                        st.st_uid
                    ),
                ));
            }
            fd
        }
        Err(e) if e.raw_os_error() == Some(libc::ENOENT) => {
            mkdirat(type_fd, name, 0o2750)?;
            open_child_dir_nofollow(type_fd, name)?
        }
        // ELOOP (a symlink at the account path) and ENOTDIR (a plain file) both land here.
        Err(e) => {
            return Err(io::Error::new(
                e.kind(),
                format!("account path is not a real directory ({e}) — refusing to install through it"),
            ))
        }
    };
    fchown(fd.as_raw_fd(), uid, gid)?;
    fchmod_dir(fd.as_raw_fd(), 0o2750)?;
    strip_acl(fd.as_raw_fd());
    Ok(fd)
}

// ── prune ───────────────────────────────────────────────────────────────────────────────────────────────

/// Remove each dropped token in `to_remove` (`<type>/<username>/<file>` paths the old manifest listed and
/// this generation no longer declares). Returns `(kept, any_failed)`: the paths it could NOT remove — the
/// caller MUST fold these into the new manifest so they are retried next generation — plus whether anything
/// went wrong. Deliberately NOT a `Result`: an error return that carried no survivors is how a partial
/// prune once orphaned its unremoved tokens forever (the failure path discarded exactly the list whose
/// purpose was surviving the failure). Two safety properties:
///   * Every descent is `O_NOFOLLOW` relative to a parent descriptor, so a symlinked type/account entry
///     can never redirect the unlink; the token unlink removes the named entry itself, not a target.
///   * A token is removed ONLY from an account dir the materializer owns. A manifest entry always names a
///     declarative (root-owned) account, but this is belt-and-suspenders: even a corrupt manifest can never
///     delete a user-owned imperative token.
fn prune(root: &OwnedFd, to_remove: &[String], owner_uid: u32) -> (Vec<String>, bool) {
    let mut kept: Vec<String> = Vec::new();
    let mut any_failed = false;
    for rel in to_remove {
        let parts: Vec<&str> = rel.split('/').collect();
        if parts.len() != 3 || parts.iter().any(|p| p.is_empty() || *p == "." || *p == "..") {
            // The manifest is root-written, so this should never happen; refuse to act on a weird line.
            eprintln!("propnix: prune: manifest line {rel:?} is not <type>/<username>/<file> — skipped");
            kept.push(rel.clone());
            any_failed = true;
            continue;
        }
        let (ty, user, file) = (parts[0], parts[1], parts[2]);
        let type_fd = match open_child_dir_nofollow(root.as_raw_fd(), ty) {
            Ok(fd) => fd,
            Err(e) if e.raw_os_error() == Some(libc::ENOENT) => continue, // already gone
            Err(e) => {
                eprintln!("propnix: prune: {rel}: type dir not a real directory ({e}) — left alone");
                kept.push(rel.clone());
                any_failed = true;
                continue;
            }
        };
        let acct_fd = match open_child_dir_nofollow(type_fd.as_raw_fd(), user) {
            Ok(fd) => fd,
            Err(e) if e.raw_os_error() == Some(libc::ENOENT) => continue,
            Err(e) => {
                eprintln!("propnix: prune: {rel}: account dir not a real directory ({e}) — left alone");
                kept.push(rel.clone());
                any_failed = true;
                continue;
            }
        };
        // Never delete a token from an account dir the materializer does not own — that is an imperative
        // account (its dir belongs to the human who ran `cred add`), not ours. `owner_uid` is 0 for the
        // real service and the test user's uid under `cargo test`.
        match fstat(acct_fd.as_raw_fd()) {
            Ok(st) if st.st_uid != owner_uid => {
                eprintln!(
                    "propnix: prune: {rel}: account dir is owned by uid {} (imperative) — not removing it",
                    st.st_uid
                );
                continue; // not kept: it is not ours to record as declarative either
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!("propnix: prune: {rel}: cannot stat account dir ({e}) — left alone");
                kept.push(rel.clone());
                any_failed = true;
                continue;
            }
        }
        // Remove the token entry itself (a symlink here is unlinked, not followed).
        if let Err(e) = unlinkat(acct_fd.as_raw_fd(), file, 0) {
            if e.raw_os_error() != Some(libc::ENOENT) {
                eprintln!("propnix: prune: could not remove {rel}: {e}");
                kept.push(rel.clone());
                any_failed = true;
                continue;
            }
        }
        // Tidy the now-empty account dir; a non-empty one just fails (ENOTEMPTY), harmlessly. The TYPE dir
        // is deliberately NOT rmdir'd here — step 5 re-ensures every known type dir, but leaving it also
        // avoids a window where an unprivileged `cred add` finds no type dir to write into.
        let _ = unlinkat(type_fd.as_raw_fd(), user, libc::AT_REMOVEDIR);
    }
    (kept, any_failed)
}

// ── convergence sweep ───────────────────────────────────────────────────────────────────────────────────

/// Bring one type dir and everything under it onto the contract, operating only on descriptors opened
/// `O_NOFOLLOW`: type dir → 3777 owner:build_gid; each real account dir → 2750; each real token file →
/// 0640; ACL-era xattrs stripped at every level. FOREIGN entries are expected here (the type dirs are
/// world-writable, so any user can create a symlink or stray file) and are LEFT ALONE with a note but do
/// NOT fail the run — otherwise one `touch` by any user would make every activation go red. A genuine
/// inability to converge a REAL store entry does fail. The per-account `.*.tmp` a crashed write may leave
/// (this materializer's or the CLI `put`'s) is reaped rather than converged — it holds a token copy at a
/// name nothing will ever read again, so tightening its mode would just preserve litter.
fn converge_type(root_fd: RawFd, ty: impl AsRef<OsStr>, build_gid: u32) -> Result<(), String> {
    let ty = ty.as_ref();
    let tyd = ty.to_string_lossy();
    let type_fd = match open_child_dir_nofollow(root_fd, ty) {
        Ok(fd) => fd,
        Err(e) if e.raw_os_error() == Some(libc::ENOENT) => return Ok(()),
        // A symlink/regular file at the type level (e.g. the `credentials.toml` pointer, or something a
        // trusted store member created) is not a type dir — note and skip, do not fail.
        Err(e) => {
            eprintln!("propnix: {tyd}: not a type directory ({e}) — left alone");
            return Ok(());
        }
    };
    strip_acl(type_fd.as_raw_fd());
    fchown(type_fd.as_raw_fd(), UID_UNCHANGED, build_gid).map_err(|e| format!("{tyd}: chgrp: {e}"))?;
    fchmod_dir(type_fd.as_raw_fd(), 0o3777).map_err(|e| format!("{tyd}: chmod: {e}"))?;

    let mut any_failed = false;
    for account in read_dir_names(type_fd.as_raw_fd()).map_err(|e| format!("{tyd}: listing: {e}"))? {
        let acctd = account.to_string_lossy();
        let acct_fd = match open_child_dir_nofollow(type_fd.as_raw_fd(), &account) {
            Ok(fd) => fd,
            // Not an account dir (a symlink, a stray file) — foreign but expected in a world-writable dir.
            Err(e) => {
                eprintln!("propnix: {tyd}/{acctd} is not an account directory ({e}) — left alone");
                continue;
            }
        };
        strip_acl(acct_fd.as_raw_fd());
        if let Err(e) = fchown(acct_fd.as_raw_fd(), UID_UNCHANGED, build_gid)
            .and_then(|()| fchmod_dir(acct_fd.as_raw_fd(), 0o2750))
        {
            eprintln!("propnix: {tyd}/{acctd}: converge: {e}");
            any_failed = true;
            continue;
        }
        for entry in read_dir_names(acct_fd.as_raw_fd()).map_err(|e| format!("{tyd}/{acctd}: listing: {e}"))? {
            let named = entry.to_string_lossy();
            let is_tmp = named.starts_with('.') && named.ends_with(".tmp");
            match open_child_file_nofollow(acct_fd.as_raw_fd(), &entry) {
                Ok(fd) => {
                    if is_tmp {
                        let _ = unlinkat(acct_fd.as_raw_fd(), &entry, 0);
                        continue;
                    }
                    strip_acl(fd.as_raw_fd());
                    if let Err(e) = fchown(fd.as_raw_fd(), UID_UNCHANGED, build_gid)
                        .and_then(|()| fchmod(fd.as_raw_fd(), 0o640))
                    {
                        eprintln!("propnix: {tyd}/{acctd}/{named}: converge: {e}");
                        any_failed = true;
                    }
                }
                // Benign non-token entries — a symlink (ELOOP), a subdirectory or FIFO (rejected as
                // non-regular), or one deleted mid-sweep (ENOENT) — are skipped silently. A REAL error
                // (EACCES, EIO, fd exhaustion) must not be swallowed as "converged nothing, all good".
                Err(e) => {
                    let benign = e.kind() == io::ErrorKind::InvalidInput // not a regular file
                        || matches!(
                            e.raw_os_error(),
                            Some(libc::ELOOP) | Some(libc::ENOENT) | Some(libc::ENOTDIR)
                        );
                    if !benign {
                        eprintln!("propnix: {tyd}/{acctd}/{named}: cannot open to converge: {e}");
                        any_failed = true;
                    }
                }
            }
        }
    }
    if any_failed {
        Err(format!("some entries under {tyd} could not be converged"))
    } else {
        Ok(())
    }
}

// ── low-level fd helpers ────────────────────────────────────────────────────────────────────────────────

/// A store path component must be exactly one level and nothing tricky: not empty, not `.`/`..`, no `/`,
/// no NUL, no newline (the last two also keep the one-line-per-entry manifest honest). Shared with
/// `CredStore::put`, whose username can come from a store's API response rather than the config.
pub(crate) fn check_component(what: &str, v: &str) -> Result<(), String> {
    if v.is_empty()
        || v == "."
        || v == ".."
        || v.contains('/')
        || v.contains('\0')
        || v.contains('\n')
    {
        return Err(format!("{what} {v:?} is not a plain path component"));
    }
    Ok(())
}

/// A NUL-terminated C string from any OS name — `&str`, `String`, or a raw `OsStr`/`OsString` read from a
/// directory. Taking `OsStr` (not `&str`) is what lets convergence re-open a NON-UTF-8 entry by its true
/// bytes rather than a lossy-mangled name that would never resolve.
fn cname(s: impl AsRef<OsStr>) -> io::Result<CString> {
    CString::new(s.as_ref().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "name has a NUL byte"))
}

/// Open a directory following symlinks in its path — for the trusted store root / manifest dir only.
fn open_dir_follow(path: &Path) -> io::Result<OwnedFd> {
    let c = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path has a NUL byte"))?;
    let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Open a child DIRECTORY relative to `dirfd`, refusing a symlink at the final component (`O_NOFOLLOW`).
/// `O_DIRECTORY` makes a non-directory (a FIFO, a regular file) fail with ENOTDIR before any blocking open.
fn open_child_dir_nofollow(dirfd: RawFd, name: impl AsRef<OsStr>) -> io::Result<OwnedFd> {
    let c = cname(name)?;
    let fd = unsafe {
        libc::openat(
            dirfd,
            c.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Open a child FILE relative to `dirfd`, refusing a symlink at the final component, and refusing anything
/// that is not a regular file. `O_NONBLOCK` is load-bearing, not a nicety: without it, an `open(O_RDONLY)`
/// on a FIFO BLOCKS until a writer appears — and any local user can `mkfifo` inside a world-writable type
/// dir, which would hang the whole (untimed, oneshot) activation forever. `O_NONBLOCK` makes the FIFO open
/// return immediately; the `fstat` regular-file check then rejects it. It is inert for a regular file, and
/// the descriptor is only ever `fchmod`/`fchown`/`fremovexattr`'d, never read, so it stays harmless.
fn open_child_file_nofollow(dirfd: RawFd, name: impl AsRef<OsStr>) -> io::Result<OwnedFd> {
    let c = cname(name)?;
    let fd = unsafe {
        libc::openat(
            dirfd,
            c.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    // Refuse anything that is not a regular file (a directory opens O_RDONLY; a FIFO/device opened above).
    let st = fstat(owned.as_raw_fd())?;
    if st.st_mode & libc::S_IFMT != libc::S_IFREG {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a regular file"));
    }
    Ok(owned)
}

/// Write `body` to a sibling temp under `dirfd` (O_CREAT|O_EXCL|O_NOFOLLOW, so a pre-existing/symlinked
/// temp is refused), stamp its mode+owner on the descriptor, fsync, then `renameat` it onto `final_name` —
/// an atomic replace that never disturbs an existing good file until it succeeds and never follows a
/// symlink. The temp name carries the PID: a concurrent run (a manual `cred materialize` beside the unit)
/// must never pre-clean or rename OUR in-flight temp — with a shared fixed name, run B's pre-clean could
/// delete run A's half-written temp and A's rename would then move B's half-written one onto the final
/// name, the exact torn state temp+rename exists to prevent. Stale temps from crashed runs (other pids)
/// are reaped by the convergence sweep's `.*.tmp` pass instead.
fn write_file_at(
    dirfd: RawFd,
    final_name: &str,
    body: &[u8],
    mode: u32,
    uid: u32,
    gid: u32,
) -> io::Result<()> {
    let tmp = format!(".{final_name}.{}.materialize.tmp", std::process::id());
    let tmp = tmp.as_str();
    let ctmp = cname(tmp)?;
    // Clear any stale temp from a previous crashed run first (best-effort; ignore ENOENT).
    let _ = unlinkat(dirfd, tmp, 0);
    let fd = unsafe {
        libc::openat(
            dirfd,
            ctmp.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode as libc::c_uint,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    // fchmod AFTER chown: chown can clear setuid/setgid on some filesystems. Any failure from here must not
    // strand the token-bearing temp, so unlink it before propagating.
    let staged = write_all(owned.as_raw_fd(), body)
        .and_then(|()| fchown(owned.as_raw_fd(), uid, gid))
        .and_then(|()| fchmod(owned.as_raw_fd(), mode))
        .and_then(|()| {
            if unsafe { libc::fsync(owned.as_raw_fd()) } < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    drop(owned);
    if let Err(e) = staged {
        let _ = unlinkat(dirfd, tmp, 0);
        return Err(e);
    }
    renameat(dirfd, tmp, dirfd, final_name)?;
    // Make the rename itself durable: without a directory fsync a successful exit can still lose the entry
    // on power loss. Best-effort — the oneshot re-runs at next boot and re-materializes regardless.
    unsafe { libc::fsync(dirfd) };
    Ok(())
}

fn write_all(fd: RawFd, mut buf: &[u8]) -> io::Result<()> {
    while !buf.is_empty() {
        let n = unsafe { libc::write(fd, buf.as_ptr() as *const libc::c_void, buf.len()) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        buf = &buf[n as usize..];
    }
    Ok(())
}

fn fchmod(fd: RawFd, mode: u32) -> io::Result<()> {
    if unsafe { libc::fchmod(fd, mode as libc::mode_t) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// `fchmod` a DIRECTORY, tolerating an environment that refuses the setgid bit. Some kernels/namespaces
/// (a userns over ZFS; the Nix build sandbox) return EPERM on a chmod that would set S_ISGID rather than
/// silently dropping it, as `ensure_type_dir` already documents for the CLI's 3777→1777 fallback. The real
/// service runs as root (CAP_FSETID) and never hits this; where it does, keeping the permission bits and
/// losing only setgid degrades exactly as the 1777 fallback does — group inheritance is lost but the
/// materializer sets every group explicitly anyway, so correctness holds.
fn fchmod_dir(fd: RawFd, mode: u32) -> io::Result<()> {
    match fchmod(fd, mode) {
        Ok(()) => Ok(()),
        Err(e) if e.raw_os_error() == Some(libc::EPERM) && mode & 0o2000 != 0 => {
            // Retry FIRST, report only if the fallback actually took: a genuine EPERM (immutable dir,
            // read-only fs) fails the retry too and must propagate without a misleading "keeping" note.
            let r = fchmod(fd, mode & !0o2000);
            if r.is_ok() {
                eprintln!(
                    "propnix: this filesystem/namespace refused the setgid bit; keeping {:o} without it — \
                     unprivileged `cred add` here may need a re-activation to fix a new token's group",
                    mode & 0o777
                );
            }
            r
        }
        Err(e) => Err(e),
    }
}

/// `fchown` with `UID_UNCHANGED`/`GID_UNCHANGED` sentinels to leave either field alone.
fn fchown(fd: RawFd, uid: u32, gid: u32) -> io::Result<()> {
    if unsafe { libc::fchown(fd, uid as libc::uid_t, gid as libc::gid_t) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn fstat(fd: RawFd) -> io::Result<libc::stat> {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut st) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(st)
}

fn mkdirat(dirfd: RawFd, name: impl AsRef<OsStr>, mode: u32) -> io::Result<()> {
    let c = cname(name)?;
    if unsafe { libc::mkdirat(dirfd, c.as_ptr(), mode as libc::mode_t) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn unlinkat(dirfd: RawFd, name: impl AsRef<OsStr>, flags: libc::c_int) -> io::Result<()> {
    let c = cname(name)?;
    if unsafe { libc::unlinkat(dirfd, c.as_ptr(), flags) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn renameat(old_dirfd: RawFd, old: &str, new_dirfd: RawFd, new: &str) -> io::Result<()> {
    let (co, cn) = (cname(old)?, cname(new)?);
    if unsafe { libc::renameat(old_dirfd, co.as_ptr(), new_dirfd, cn.as_ptr()) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Strip POSIX ACL xattrs from a descriptor so plain group ownership governs again (the ACL-era repair —
/// a `-rw-r-----+` token's `group:` entry is ignored for a userns builder). Best-effort: a store that
/// never had ACLs, or a filesystem without xattr support, is a harmless no-op.
fn strip_acl(fd: RawFd) {
    for name in [c"system.posix_acl_access", c"system.posix_acl_default"] {
        unsafe {
            libc::fremovexattr(fd, name.as_ptr());
        }
    }
}

/// Directory entry NAMES under `dirfd` (excluding `.`/`..`), read through a duplicate of the descriptor so
/// the caller keeps its own. Names are then re-opened relative to `dirfd` with `O_NOFOLLOW`, so even if the
/// listing itself raced a swap, each per-entry mutation still validates the entry independently.
fn read_dir_names(dirfd: RawFd) -> io::Result<Vec<OsString>> {
    let dup = unsafe { libc::dup(dirfd) };
    if dup < 0 {
        return Err(io::Error::last_os_error());
    }
    let dirp = unsafe { libc::fdopendir(dup) };
    if dirp.is_null() {
        let e = io::Error::last_os_error();
        unsafe { libc::close(dup) };
        return Err(e);
    }
    let mut names = Vec::new();
    loop {
        // readdir returns NULL both at end-of-stream and on error; distinguish via errno.
        unsafe { *libc::__errno_location() = 0 };
        let ent = unsafe { libc::readdir(dirp) };
        if ent.is_null() {
            let err = io::Error::last_os_error();
            unsafe { libc::closedir(dirp) };
            if err.raw_os_error() == Some(0) {
                return Ok(names);
            }
            return Err(err);
        }
        let name = unsafe { CStr::from_ptr((*ent).d_name.as_ptr()) };
        let bytes = name.to_bytes();
        if bytes == b"." || bytes == b".." {
            continue;
        }
        names.push(OsString::from_vec(bytes.to_vec()));
    }
}

/// Resolve a group SPEC (a name on the service, a numeric gid under test) to its gid. A numeric string is
/// accepted only if a group with that gid exists — a bare number that names no group would otherwise let a
/// misconfigured activation stamp files with a gid nobody has.
fn resolve_gid(spec: &str) -> Result<u32, String> {
    if let Ok(n) = spec.parse::<libc::gid_t>() {
        let gr = unsafe { libc::getgrgid(n) };
        return if gr.is_null() {
            Err(format!("no group has gid {n}"))
        } else {
            Ok(n)
        };
    }
    let c = cname(spec).map_err(|e| format!("group name {spec:?}: {e}"))?;
    let gr = unsafe { libc::getgrnam(c.as_ptr()) };
    if gr.is_null() {
        Err(format!("no such group {spec:?}"))
    } else {
        Ok(unsafe { (*gr).gr_gid })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
    use std::path::PathBuf;

    fn tmp(tag: &str) -> PathBuf {
        let mut d = std::env::temp_dir();
        d.push(format!("propnix-mat-{tag}-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn mode(p: &Path) -> u32 {
        std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777
    }

    /// Run materialize unprivileged: owner = us, every group = our own gid (so `fchown` to self and the
    /// setgid `fchmod` on a group we belong to both succeed with no privilege — the same code the root
    /// service runs).
    fn run(base: &Path, creds: Vec<CredEntry>) -> (Result<(), String>, PathBuf, String) {
        let root = base.join("store");
        let manifest = base.join("store-declarative-credentials");
        let gid = unsafe { libc::getgid() };
        let uid = unsafe { libc::getuid() };
        let cfg = serde_json::json!({
            "root": root.to_str().unwrap(),
            "owner_uid": uid,
            "root_group": gid.to_string(),
            "build_group": gid.to_string(),
            "meta_group": gid.to_string(),
            "pointer_body": "credentialDir = \"/propnix\"\n",
            "manifest_path": manifest.to_str().unwrap(),
            "types": ["gog", "steam"],
            "credentials": creds.iter().map(|c| serde_json::json!({
                "type": c.r#type, "username": c.username, "file": c.file, "source": c.source,
            })).collect::<Vec<_>>(),
        });
        let cfg_path = base.join("cfg.json");
        std::fs::write(&cfg_path, serde_json::to_vec(&cfg).unwrap()).unwrap();
        (materialize(&cfg_path), root, std::fs::read_to_string(&manifest).unwrap_or_default())
    }

    fn secret(base: &Path, name: &str, body: &str) -> String {
        let p = base.join(name);
        std::fs::write(&p, body).unwrap();
        p.to_str().unwrap().to_string()
    }

    fn entry(base: &Path, ty: &str, user: &str, file: &str, body: &str) -> CredEntry {
        CredEntry {
            r#type: ty.into(),
            username: user.into(),
            file: file.into(),
            source: secret(base, &format!("{ty}-{user}-src"), body),
        }
    }

    #[test]
    fn installs_the_contract_layout_and_the_pointer_and_manifest() {
        let base = tmp("layout");
        let gid = unsafe { libc::getgid() };
        let (res, root, manifest) = run(
            &base,
            vec![entry(&base, "gog", "alice", "galaxy_tokens.json", "{\"t\":1}")],
        );
        res.unwrap();

        let acct = root.join("gog").join("alice");
        let token = acct.join("galaxy_tokens.json");
        // Mask to the permission bits: an unprivileged test env (the Nix build sandbox) may refuse the
        // setgid bit, which `fchmod_dir` tolerates — the low 9 bits are the contract that must always hold.
        assert_eq!(mode(&root) & 0o777, 0o775, "root dir");
        assert_eq!(mode(&root.join("gog")) & 0o1777, 0o1777, "type dir sticky + world-rwx (setgid masked)");
        assert_eq!(mode(&acct) & 0o777, 0o750, "account dir 0750");
        assert_eq!(mode(&token), 0o640, "token 0640");
        assert_eq!(std::fs::metadata(&token).unwrap().gid(), gid, "token group = build group");
        assert_eq!(std::fs::read_to_string(&token).unwrap(), "{\"t\":1}");
        assert_eq!(mode(&root.join("credentials.toml")), 0o644, "pointer 0644");
        assert!(std::fs::read_to_string(root.join("credentials.toml")).unwrap().contains("/propnix"));
        assert_eq!(manifest, "gog/alice/galaxy_tokens.json\n", "manifest lists the managed token");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn prunes_a_credential_the_config_stopped_declaring() {
        let base = tmp("prune");
        // Generation A: two accounts.
        run(&base, vec![
            entry(&base, "gog", "alice", "galaxy_tokens.json", "a"),
            entry(&base, "gog", "bob", "galaxy_tokens.json", "b"),
        ]).0.unwrap();
        let root = base.join("store");
        assert!(root.join("gog/bob/galaxy_tokens.json").exists());

        // Generation B: alice only. bob's token AND now-empty account dir must be pruned; alice stays.
        let (res, _, manifest) = run(&base, vec![entry(&base, "gog", "alice", "galaxy_tokens.json", "a")]);
        res.unwrap();
        assert!(root.join("gog/alice/galaxy_tokens.json").exists(), "alice survives");
        assert!(!root.join("gog/bob").exists(), "bob's account dir tidied away");
        assert_eq!(manifest, "gog/alice/galaxy_tokens.json\n");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_symlinked_account_entry_is_never_followed_by_install_or_converge() {
        let base = tmp("symlink");
        let outside = base.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("victim"), "precious").unwrap();

        // Pre-create the store + a symlinked account path where a declared account wants to land.
        let root = base.join("store");
        std::fs::create_dir_all(root.join("gog")).unwrap();
        symlink(&outside, root.join("gog").join("mallory")).unwrap();

        let (res, _, _) = run(&base, vec![entry(&base, "gog", "mallory", "galaxy_tokens.json", "x")]);
        // The declared install is refused (soft failure), and NOTHING is written through the link.
        assert!(res.is_err(), "installing through a symlinked account must fail the run");
        assert!(!outside.join("galaxy_tokens.json").exists(), "no token written through the link");
        assert_eq!(std::fs::read_to_string(outside.join("victim")).unwrap(), "precious");
        // The symlink's target keeps its original (non-2750) mode — convergence never followed it.
        assert_ne!(mode(&outside), 0o2750, "converge must not have re-moded the link target");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn converge_repairs_an_imperative_account_and_reaps_a_crashed_temp() {
        let base = tmp("converge");
        let root = base.join("store");
        // An imperative account left loose by an older layout: wrong dir mode + a crashed-put temp holding
        // a token copy + an ACL-era-ish extra file, none declared.
        let acct = root.join("steam").join("carol");
        std::fs::create_dir_all(&acct).unwrap();
        std::fs::set_permissions(root.join("steam"), std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(&acct, std::fs::Permissions::from_mode(0o777)).unwrap();
        std::fs::write(acct.join("depotdownloader-store.tar"), "tok").unwrap();
        std::fs::set_permissions(acct.join("depotdownloader-store.tar"), std::fs::Permissions::from_mode(0o666)).unwrap();
        std::fs::write(acct.join(".depotdownloader-store.tar.materialize.tmp"), "leaked").unwrap();

        let (res, _, _) = run(&base, vec![]); // no declared creds — pure convergence
        res.unwrap();
        assert_eq!(mode(root.join("steam").as_path()) & 0o1777, 0o1777, "type dir sticky + world-rwx converged");
        assert_eq!(mode(&acct) & 0o777, 0o750, "account dir converged, group-write and other stripped");
        assert_eq!(mode(acct.join("depotdownloader-store.tar").as_path()), 0o640, "token converged");
        assert!(!acct.join(".depotdownloader-store.tar.materialize.tmp").exists(), "crashed temp reaped");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_missing_source_is_reported_but_does_not_strand_the_others() {
        let base = tmp("missing");
        let good = entry(&base, "gog", "alice", "galaxy_tokens.json", "a");
        let bad = CredEntry {
            r#type: "gog".into(),
            username: "ghost".into(),
            file: "galaxy_tokens.json".into(),
            source: base.join("does-not-exist").to_str().unwrap().to_string(),
        };
        let (res, root, manifest) = run(&base, vec![bad, good]);
        assert!(res.is_err(), "a missing source makes the run report failure");
        assert!(root.join("gog/alice/galaxy_tokens.json").exists(), "the good account still installed");
        assert!(!root.join("gog/ghost/galaxy_tokens.json").exists());
        // The manifest reflects REALITY, not intent: the failed install is not recorded as declarative,
        // so `is_declarative` won't mislabel it and next generation's prune won't chase a phantom.
        assert_eq!(manifest, "gog/alice/galaxy_tokens.json\n", "only the installed token is manifested");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_fifo_in_the_store_does_not_hang_the_run() {
        // Any user can mkfifo in a world-writable type dir; converge must not block opening it (which a
        // plain O_RDONLY would, forever — hanging activation). O_NONBLOCK + the regular-file check skip it.
        let base = tmp("fifo");
        let root = base.join("store");
        let acct = root.join("gog").join("alice");
        std::fs::create_dir_all(&acct).unwrap();
        let fifo = acct.join("evil");
        let c = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o644) }, 0, "mkfifo");
        // A FIFO named like a temp must also not hang the reap path.
        let fifo2 = acct.join(".x.materialize.tmp");
        let c2 = std::ffi::CString::new(fifo2.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c2.as_ptr(), 0o644) }, 0, "mkfifo tmp");

        // No token declared; pure convergence over the planted FIFOs. Must return, not hang.
        let (res, _, _) = run(&base, vec![]);
        // A FIFO is a benign non-regular entry, so the run should not even report failure.
        res.unwrap();
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_foreign_stray_file_does_not_fail_the_run() {
        // A stray file in a world-writable type dir is expected (anyone can create one); it must be left
        // alone WITHOUT flipping the unit to failed — else one `touch` reddens every activation forever.
        let base = tmp("foreign");
        let root = base.join("store");
        std::fs::create_dir_all(root.join("gog")).unwrap();
        std::fs::write(root.join("gog").join("junk"), "x").unwrap(); // a file where an account dir belongs
        let (res, _, _) = run(&base, vec![entry(&base, "gog", "alice", "galaxy_tokens.json", "a")]);
        res.unwrap(); // the stray file is skipped, not a failure
        assert!(root.join("gog/alice/galaxy_tokens.json").exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn an_unremovable_dropped_credential_stays_in_the_manifest_for_retry() {
        // The invariant a partial prune must keep: a dropped entry that could not be removed stays NAMED
        // in the manifest, so the next generation retries it instead of orphaning the token forever.
        let base = tmp("prune-retry");
        run(&base, vec![entry(&base, "gog", "alice", "galaxy_tokens.json", "a")]).0.unwrap();
        let root = base.join("store");
        // Make the account dir unremovable-from (no write on the dir → unlink fails).
        let acct = root.join("gog").join("alice");
        std::fs::set_permissions(&acct, std::fs::Permissions::from_mode(0o500)).unwrap();

        // Generation B drops alice: the prune fails, the run reports failure, and the manifest KEEPS her.
        let (res, _, manifest) = run(&base, vec![]);
        assert!(res.is_err(), "a failed prune must surface");
        assert_eq!(
            manifest, "gog/alice/galaxy_tokens.json\n",
            "the unremovable entry must stay manifested for retry"
        );

        // Generation C (dir healed — converge in gen B restored 2750... which is still unwritable-by-group
        // but WRITABLE by owner, so the retry now succeeds): token gone, manifest empty.
        let (res, _, manifest) = run(&base, vec![]);
        res.unwrap();
        assert!(!acct.exists(), "the retry prunes what generation B could not");
        assert_eq!(manifest, "", "nothing declarative remains");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_stray_root_level_directory_is_never_widened() {
        // The convergence sweep must apply the world-writable type-dir contract ONLY to real type dirs
        // (known/declared, or previously converged = build-group). A member's own dir at the root level
        // must keep its mode and group — stamping it 3777 would make private content world-creatable-into.
        let base = tmp("stray-root");
        let root = base.join("store");
        let private = root.join("backup");
        std::fs::create_dir_all(&private).unwrap();
        std::fs::write(private.join("secret"), "s").unwrap();
        std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(private.join("secret"), std::fs::Permissions::from_mode(0o600)).unwrap();

        // run() uses OUR gid as the build group, so `backup` carries the "build group" already — the gate
        // must still skip it because it is not world-writable (the second half of the type-dir signature).
        let (res, _, _) = run(&base, vec![entry(&base, "gog", "alice", "galaxy_tokens.json", "a")]);
        res.unwrap();
        let m = mode(&private);
        assert_eq!(m & 0o777, 0o700, "stray dir mode must be untouched, got {m:o}");
        assert_eq!(mode(private.join("secret").as_path()), 0o600, "private file untouched");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn cache_is_refused_as_a_credential_type() {
        let base = tmp("cache-type");
        let cred = CredEntry {
            r#type: "cache".into(),
            username: "alice".into(),
            file: "tok.bin".into(),
            source: secret(&base, "s", "x"),
        };
        let (res, root, manifest) = run(&base, vec![cred]);
        assert!(res.is_err());
        assert!(!root.join("cache").exists(), "nothing may be created under the cache name");
        assert_eq!(manifest, "", "the refused credential is not manifested");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn dotted_and_temp_colliding_components_are_refused() {
        let base = tmp("components");
        // `.` as a type would collapse a level and stamp the store root; must be refused.
        let dot = CredEntry {
            r#type: ".".into(),
            username: "x".into(),
            file: "t".into(),
            source: secret(&base, "s1", "x"),
        };
        // A tokenFile matching the reap pattern would be installed then deleted the same run.
        let tmpname = CredEntry {
            r#type: "gog".into(),
            username: "alice".into(),
            file: ".galaxy.tmp".into(),
            source: secret(&base, "s2", "x"),
        };
        let (res, root, _) = run(&base, vec![dot, tmpname]);
        assert!(res.is_err());
        assert_eq!(mode(&root) & 0o777, 0o775, "store root must NOT have been stamped 3777 by a `.` type");
        assert!(!root.join("gog/alice/.galaxy.tmp").exists(), "reap-colliding token refused");
        let _ = std::fs::remove_dir_all(&base);
    }
}
