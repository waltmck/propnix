//! propnix-mount — a LIBRARY the launcher links (not a separate binary): `enter_and_mount` builds a layered
//! bind-mount "table" for the WINEPREFIX (and any per-game writable game-dir redirects), expressed as a
//! declarative `&[Entry]`, most-specific entry wins.
//!
//! The launcher calls it from a `Command::pre_exec` hook on the mount child: it unshares a private user+mount
//! namespace, then bind(2)s each entry, and RETURNS so the caller execs the game into the assembled prefix.
//! Unprivileged (the ns creator holds CAP_SYS_ADMIN in-ns), and SELF-CLEANING: the mounts vanish when the
//! process tree exits (the mount ns dies). We do NOT unshare the pid ns, so the wine tree stays visible to
//! the outer launcher for prefix-scoped teardown.
//!
//! `entries` are LITERAL paths, SORTED PARENT-FIRST by the launcher, so applying them in order makes each
//! nested entry shadow its parent (topological layering). (The launcher probes for unprivileged-userns
//! support and refuses to launch with an actionable error if it's unavailable, so by the time this runs it's
//! known good.)

use std::ffi::CString;
use std::path::Path;
use std::process::Command;

/// Create one empty mountpoint stub under `base` for each `(rel, is_file)` — a FILE stub when `is_file` (e.g.
/// `system.reg`), a directory otherwise, with parent dirs made as needed. These are the child mountpoints a
/// mount must expose so a nested sub-mount lands cleanly. The single implementation shared by every stub
/// producer (a mount's child skeleton and a source-less tmpfs alike), so failure semantics are uniform.
fn create_stub_tree(base: &Path, stubs: &[(String, bool)]) -> Result<(), String> {
    for (rel, is_file) in stubs {
        let p = base.join(rel);
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
        }
        if *is_file {
            std::fs::File::create(&p).map_err(|e| format!("touch {}: {e}", p.display()))?;
        } else {
            std::fs::create_dir_all(&p).map_err(|e| format!("mkdir {}: {e}", p.display()))?;
        }
    }
    Ok(())
}

/// The per-mount flags currently on `target` (nosuid/nodev/noexec/atime), as MS_* bits. In a user namespace
/// the kernel LOCKS these on mounts propagated in — a remount-ro that fails to carry them back is EPERM — so
/// we read them (statvfs) and OR them into the remount. Note ST_* and MS_* have different numeric values, so
/// this is a real remap, not a passthrough.
unsafe fn locked_mnt_flags(target: *const libc::c_char) -> libc::c_ulong {
    let mut vfs: libc::statvfs = std::mem::zeroed();
    if libc::statvfs(target, &mut vfs) != 0 {
        return 0;
    }
    let f = vfs.f_flag;
    let mut ms: libc::c_ulong = 0;
    if f & libc::ST_NOSUID != 0 {
        ms |= libc::MS_NOSUID;
    }
    if f & libc::ST_NODEV != 0 {
        ms |= libc::MS_NODEV;
    }
    if f & libc::ST_NOEXEC != 0 {
        ms |= libc::MS_NOEXEC;
    }
    if f & libc::ST_NOATIME != 0 {
        ms |= libc::MS_NOATIME;
    }
    if f & libc::ST_NODIRATIME != 0 {
        ms |= libc::MS_NODIRATIME;
    }
    if f & libc::ST_RELATIME != 0 {
        ms |= libc::MS_RELATIME;
    }
    ms
}

/// A resolved entry (LITERAL paths). `mount` = a bind of `source` at `target`; `overlay` = a COW overlay
/// whose reads fall through to `lower`. `upper = None` → ephemeral (we mount a fresh per-launch tmpfs for
/// the upper+work); a set `upper` is persistent (we derive its workdir as a sibling on the same fs).
///
/// `skeleton` (overlay only) = a store path to a TAR of a data-only METADATA layer. When set, `lower` is a
/// root-owned Nix store tree we could not otherwise copy-up unprivileged (copy-up must reproduce the lower's
/// owner; root is unmapped in our ns → EOVERFLOW). The tar holds, per file, a user-owned SPARSE stub sized
/// to the original + `user.overlay.metacopy` + `user.overlay.redirect=/<relpath>`; we extract it into a
/// fresh tmpfs and stack it ABOVE `lower` as a data-only layer (`lowerdir=<skel>::<lower>`, `userxattr`).
/// Reads fall through the redirect to the store inode (shared page cache, no copy); copy-up reproduces the
/// stub's mapped owner and pulls the full data from the store layer (the sparse size is what makes the data
/// copy fire — a 0-byte stub would silently truncate). `skeleton = None` → a plain overlay (user-owned or
/// ephemeral `lower` that needs no metadata layer, e.g. Temp).
/// A resolved mount-table entry (LITERAL paths only), built by the launcher and applied by `enter_and_mount`
/// (the launcher links this crate and passes a `&[Entry]` directly — no JSON, no separate binary).
pub enum Entry {
    Mount {
        target: String,
        /// A bind source, or None → mount a fresh ns-private tmpfs at the target (ephemeral, writable, gone
        /// when the mount namespace dies). With `seed` set, that tmpfs is pre-filled from a store tree.
        source: Option<String>,
        /// "ro" | "rw".
        mode: String,
        /// Optional seed tree: after establishing the target (bind or tmpfs), every file under `seed` NOT
        /// already present at the target is copied in (existing files untouched), concurrently — presenting a
        /// store tree as a per-launch writable dir a runtime can mmap+write.
        seed: Option<String>,
    },
    Overlay {
        target: String,
        lower: String,
        upper: Option<String>,
        skeleton: Option<String>,
    },
}

fn oserr() -> String {
    std::io::Error::last_os_error().to_string()
}

/// Populate `target` from the `seed` tree: every path under `seed` NOT already present at the matching
/// location under `target` is created — directories, symlinks (copied as symlinks, never followed), and
/// regular files (contents copied, made user-writable since store originals are read-only). Existing target
/// paths are never overwritten. File/symlink copies run concurrently across a small worker pool. Used to
/// pre-fill a per-launch tmpfs with a store tree a runtime needs as REAL, WRITABLE files — e.g. Mono's
/// managed assemblies, which it MAP_SHARED-maps (unsupported from an overlay lower layer) and which must sit
/// in a writable directory. Directories are created in the (serial) walk so the parallel phase never races
/// to `mkdir` a shared parent.
fn seed_dir(seed: &str, target: &str) -> Result<(), String> {
    use std::path::PathBuf;
    enum Kind {
        File,
        Symlink(PathBuf),
    }
    struct Job {
        src: PathBuf,
        dst: PathBuf,
        kind: Kind,
    }
    let seed_root = Path::new(seed);
    let tgt_root = Path::new(target);
    let mut jobs: Vec<Job> = Vec::new();
    let mut stack = vec![seed_root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let rd = std::fs::read_dir(&dir).map_err(|e| format!("read_dir {}: {e}", dir.display()))?;
        for ent in rd {
            let ent = ent.map_err(|e| format!("readdir {}: {e}", dir.display()))?;
            let src = ent.path();
            let rel = src.strip_prefix(seed_root).unwrap();
            let dst = tgt_root.join(rel);
            let ft = ent
                .file_type()
                .map_err(|e| format!("file_type {}: {e}", src.display()))?;
            if ft.is_symlink() {
                if dst.symlink_metadata().is_err() {
                    let lt = std::fs::read_link(&src)
                        .map_err(|e| format!("readlink {}: {e}", src.display()))?;
                    jobs.push(Job {
                        src,
                        dst,
                        kind: Kind::Symlink(lt),
                    });
                }
            } else if ft.is_dir() {
                // Create the dir now (idempotent) so the parallel phase can drop files straight in, then recurse.
                std::fs::create_dir_all(&dst).map_err(|e| format!("mkdir {}: {e}", dst.display()))?;
                stack.push(src);
            } else if dst.symlink_metadata().is_err() {
                jobs.push(Job {
                    src,
                    dst,
                    kind: Kind::File,
                });
            }
        }
    }
    if jobs.is_empty() {
        return Ok(());
    }
    let n = std::thread::available_parallelism()
        .map(|v| v.get())
        .unwrap_or(4)
        .min(8)
        .min(jobs.len());
    let jobs = &jobs;
    let next = std::sync::atomic::AtomicUsize::new(0);
    let err: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
    std::thread::scope(|s| {
        for _ in 0..n {
            // Borrow (not move) `next`/`err`/`jobs` — all shared across the pool for the scope's lifetime.
            s.spawn(|| {
                use std::os::unix::fs::PermissionsExt;
                loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if i >= jobs.len() {
                        break;
                    }
                    let j = &jobs[i];
                    let r: Result<(), String> = match &j.kind {
                        Kind::Symlink(lt) => std::os::unix::fs::symlink(lt, &j.dst)
                            .map_err(|e| format!("symlink {}: {e}", j.dst.display())),
                        Kind::File => std::fs::copy(&j.src, &j.dst)
                            .map_err(|e| {
                                format!("copy {} -> {}: {e}", j.src.display(), j.dst.display())
                            })
                            .map(|_| {
                                // Make the copy user-writable — the point of seeding is a writable tree.
                                let _ = std::fs::set_permissions(
                                    &j.dst,
                                    std::fs::Permissions::from_mode(0o644),
                                );
                            }),
                    };
                    if let Err(m) = r {
                        let mut g = err.lock().unwrap();
                        if g.is_none() {
                            *g = Some(m);
                        }
                        break;
                    }
                }
            });
        }
    });
    match err.into_inner().unwrap() {
        Some(m) => Err(m),
        None => Ok(()),
    }
}

fn entry_target(e: &Entry) -> &str {
    match e {
        Entry::Mount { target, .. } => target,
        Entry::Overlay { target, .. } => target,
    }
}

/// The path whose tree provides this mount's content — a bind's `source`, an overlay's `lower`. `None` → a
/// fresh tmpfs (empty content). Used only to decide which child mountpoints a bind/tmpfs already carries;
/// overlays stub every child unconditionally, so the value isn't consulted for them.
fn content_path(e: &Entry) -> Option<&str> {
    match e {
        Entry::Mount { source, .. } => source.as_deref(),
        Entry::Overlay { lower, .. } => Some(lower),
    }
}

/// A child mount whose target is a FILE bind needs a FILE mountpoint (e.g. `system.reg`), else a directory.
fn child_is_file(e: &Entry) -> bool {
    matches!(e, Entry::Mount { source: Some(s), .. } if Path::new(s).is_file())
}

/// Index of `i`'s NEAREST mount ancestor in `targets` — the entry whose target is the longest proper
/// path-ancestor of `targets[i]` — or `None` when `targets[i]` is the prefix root. This makes the mount table
/// a forest: `targets[i]` mounts ONTO its parent, and the parent must expose `targets[i]` as a mountpoint.
fn parent_index(targets: &[&str], root: &str, i: usize) -> Option<usize> {
    let t = targets[i];
    if t == root {
        return None;
    }
    let mut best: Option<(usize, usize)> = None; // (index, ancestor length)
    for (j, &tj) in targets.iter().enumerate() {
        if j == i {
            continue;
        }
        // tj is a path-ancestor of t iff `tj` + `/` is a prefix of `t`.
        let is_ancestor =
            t.len() > tj.len() && t.starts_with(tj) && t.as_bytes()[tj.len()] == b'/';
        if is_ancestor && best.map_or(true, |(_, l)| tj.len() > l) {
            best = Some((j, tj.len()));
        }
    }
    best.map(|(j, _)| j)
}

/// Build this mount's CHILD SKELETON — a fresh ns-private tmpfs (user-owned) holding one empty stub at each
/// MISSING child mountpoint (`missing`: relative path + is-file). Used as the mount's bottom overlay lowerdir
/// so a nested sub-mount always has a mountpoint to land on, without `ensure_mountpoint` creating it in the
/// content (which would copy up an overlay upper, or fail on a read-only bind). Only the children the mount's
/// own content lacks are stubbed — a bind whose source already carries every child stays a plain bind.
fn build_child_skeleton(idx: usize, missing: &[(String, bool)]) -> Result<String, String> {
    let skel = format!("/tmp/.propnix-childskel-{idx}");
    std::fs::create_dir_all(&skel).map_err(|e| format!("mkdir {skel}: {e}"))?;
    let sc = CString::new(skel.as_str()).unwrap();
    let ty = CString::new("tmpfs").unwrap();
    if unsafe { libc::mount(ty.as_ptr(), sc.as_ptr(), ty.as_ptr(), 0, std::ptr::null()) } != 0 {
        return Err(format!("tmpfs at {skel}: {}", oserr()));
    }
    create_stub_tree(Path::new(&skel), missing)?;
    Ok(skel)
}

/// Enter a private user+mount namespace and lay the WINEPREFIX mount table (`entries`, already resolved to
/// literal paths + sorted parent-first). Runs in the launcher's `Command::pre_exec` hook on the mount child:
/// unshares the ns, maps our uid/gid, then applies every entry parent-first, then RETURNS so the caller's
/// exec runs the game inside the assembled prefix (the ns + its binds live exactly as long as that process
/// tree). Every entry target is an absolute path AT/UNDER `root` (the launcher joined it to the view).
///
/// The prefix ROOT is normally the table's own root entry (makeAppWine injects target "" — a persistent
/// mount of `$PROPNIX_STATE/wine/prefix` seeded with the base user.reg, realized as an overlay so its upper
/// persists and its child-skeleton lower exposes every sub-mount's mountpoint); being parent-first it's laid
/// first. As a fallback, a table with NO root entry gets a fresh ephemeral tmpfs at the root instead.
/// `tar_bin` extracts overlay `skeleton` tars. Any failure is returned as a message.
pub fn enter_and_mount(root: &str, entries: &[Entry], tar_bin: &str) -> Result<(), String> {
    unsafe {
        let (uid, gid) = (libc::getuid(), libc::getgid());
        if libc::unshare(libc::CLONE_NEWUSER | libc::CLONE_NEWNS) != 0 {
            return Err(format!("unshare(userns|mountns): {}", oserr()));
        }
        // Identity uid/gid map (map only our own id — the ns creator keeps CAP_SYS_ADMIN in-ns, and
        // keeping our real uid means files/sockets/XDG all resolve normally). setgroups=deny first, as
        // the kernel requires before an unprivileged gid_map write.
        let _ = std::fs::write("/proc/self/setgroups", "deny");
        if std::fs::write("/proc/self/uid_map", format!("{uid} {uid} 1")).is_err()
            || std::fs::write("/proc/self/gid_map", format!("{gid} {gid} 1")).is_err()
        {
            return Err(format!("writing uid/gid map: {}", oserr()));
        }
        // Make our mount tree private so nothing propagates out (it's ns-private regardless).
        let slash = CString::new("/").unwrap();
        libc::mount(
            std::ptr::null(),
            slash.as_ptr(),
            std::ptr::null(),
            libc::MS_REC | libc::MS_PRIVATE,
            std::ptr::null(),
        );
        // The mount table is a FOREST (by target-path nesting): each entry mounts ONTO its nearest mount
        // ancestor, which must expose it as a mountpoint. So every mount gets a CHILD SKELETON of the
        // mountpoints its own content lacks (below); applied parent-first (the launcher sorted the table so),
        // a mount — with its skeleton — is always laid before any child lands on it.
        let targets: Vec<&str> = entries.iter().map(entry_target).collect();
        let mut children: Vec<Vec<usize>> = vec![Vec::new(); entries.len()];
        for i in 0..entries.len() {
            if let Some(p) = parent_index(&targets, root, i) {
                children[p].push(i);
            }
        }

        // The prefix ROOT: normally the table's own root entry (a Mount of $STATE/wine/prefix, realized below
        // as an overlay whose upper persists user.reg) — laid in the loop below, and being parent-first it's
        // first. FALLBACK: a table with no root entry gets a fresh ephemeral tmpfs backing the root here.
        if !entries.iter().any(|e| entry_target(e) == root) {
            let r = CString::new(root).unwrap();
            let ty = CString::new("tmpfs").unwrap();
            if libc::mount(ty.as_ptr(), r.as_ptr(), ty.as_ptr(), 0, std::ptr::null()) != 0 {
                return Err(format!("tmpfs root at {root}: {}", oserr()));
            }
        }

        for (i, e) in entries.iter().enumerate() {
            // The child mountpoint stubs this mount needs in its lower so a sub-mount lands cleanly (no
            // `ensure_mountpoint` copy-up into an overlay upper, no failure on a read-only bind). For an
            // OVERLAY, stub EVERY child — its mountpoints come from its own skeleton (merged into the normal
            // layer; the copy-up skeleton already mirrors any the lower carries, and seed_dir dedups them), so
            // the overlay never depends on the lower coincidentally having them. For a bind/tmpfs, stub only
            // the children the source LACKS, so a bind whose source carries every child stays a plain bind.
            let for_overlay = matches!(e, Entry::Overlay { .. });
            let content = content_path(e);
            let mut stubs: Vec<(String, bool)> = Vec::new();
            for &j in &children[i] {
                let rel = &targets[j][targets[i].len() + 1..];
                let present = content.is_some_and(|c| Path::new(c).join(rel).exists());
                if for_overlay || !present {
                    stubs.push((rel.to_string(), child_is_file(&entries[j])));
                }
            }
            let child_skel = if stubs.is_empty() {
                None
            } else {
                Some(build_child_skeleton(i, &stubs)?)
            };
            let cs = child_skel.as_deref();

            match e {
                Entry::Overlay {
                    target,
                    lower,
                    upper,
                    skeleton,
                } => {
                    if let Err(msg) = mount_overlay(
                        i, target, lower, upper.as_deref(), false, skeleton.as_deref(), cs, tar_bin,
                    ) {
                        return Err(format!("overlay {lower} -> {target}: {msg}"));
                    }
                }
                Entry::Mount {
                    target,
                    source,
                    mode,
                    seed,
                } => {
                    let tgt = CString::new(target.as_str()).unwrap();
                    match source {
                        // A bind whose source LACKS a child mountpoint → realize it as an overlay so the
                        // child skeleton injects them: a read-only bind → a lowerdir-only (read-only) overlay
                        // over `[source, skeleton]`; a writable one → `source` as the upper, skeleton the
                        // lower. (Rare — sources usually carry their children, so the plain bind below wins.)
                        Some(src) if cs.is_some() => {
                            let res = if mode == "ro" {
                                mount_overlay(i, target, src, None, true, None, cs, tar_bin)
                            } else {
                                mount_overlay(i, target, cs.unwrap(), Some(src), false, None, None, tar_bin)
                            };
                            if let Err(msg) = res {
                                return Err(format!("bind-overlay {src} -> {target}: {msg}"));
                            }
                            if let Some(seed) = seed {
                                if let Err(msg) = seed_dir(seed, target) {
                                    return Err(format!("seed {seed} -> {target}: {msg}"));
                                }
                            }
                        }
                        // Plain recursive bind (its source already carries every child mountpoint; the target
                        // itself is a mountpoint the parent entry's skeleton/source already provides).
                        Some(src) => {
                            let csrc = CString::new(src.as_str()).unwrap();
                            if libc::mount(
                                csrc.as_ptr(),
                                tgt.as_ptr(),
                                std::ptr::null(),
                                libc::MS_BIND | libc::MS_REC,
                                std::ptr::null(),
                            ) != 0
                            {
                                return Err(format!("bind {src} -> {target}: {}", oserr()));
                            }
                            if let Some(seed) = seed {
                                if let Err(msg) = seed_dir(seed, target) {
                                    return Err(format!("seed {seed} -> {target}: {msg}"));
                                }
                            }
                            if mode == "ro" {
                                let locked = locked_mnt_flags(tgt.as_ptr());
                                if libc::mount(
                                    std::ptr::null(),
                                    tgt.as_ptr(),
                                    std::ptr::null(),
                                    libc::MS_BIND | libc::MS_REMOUNT | libc::MS_RDONLY | locked,
                                    std::ptr::null(),
                                ) != 0
                                {
                                    return Err(format!("remount ro {target}: {}", oserr()));
                                }
                            }
                        }
                        // Fresh ns-private tmpfs (ephemeral, writable). Any missing child mountpoints are
                        // created directly in it (no copy-up concern — it's throwaway), then seeded.
                        None => {
                            let _ = std::fs::create_dir_all(target);
                            let ty = CString::new("tmpfs").unwrap();
                            if libc::mount(ty.as_ptr(), tgt.as_ptr(), ty.as_ptr(), 0, std::ptr::null())
                                != 0
                            {
                                return Err(format!("tmpfs at {target}: {}", oserr()));
                            }
                            create_stub_tree(Path::new(target), &stubs)?;
                            if let Some(seed) = seed {
                                if let Err(msg) = seed_dir(seed, target) {
                                    return Err(format!("seed {seed} -> {target}: {msg}"));
                                }
                            }
                            if mode == "ro" {
                                let locked = locked_mnt_flags(tgt.as_ptr());
                                if libc::mount(
                                    std::ptr::null(),
                                    tgt.as_ptr(),
                                    std::ptr::null(),
                                    libc::MS_REMOUNT | libc::MS_RDONLY | locked,
                                    std::ptr::null(),
                                ) != 0
                                {
                                    return Err(format!("remount ro {target}: {}", oserr()));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // The ns (and its binds) live exactly as long as the caller's process tree — the caller now execs the
    // game into this assembled prefix.
    Ok(())
}

/// Mount a COW overlay at `target`. `ro = true` → a LOWERDIR-ONLY read-only overlay (no upper/work — used to
/// inject a `child_skel` mountpoint layer under a read-only bind's source). Otherwise `upper = None` →
/// EPHEMERAL (fresh ns-private tmpfs up/work); `upper = Some` → PERSISTENT (that dir, workdir a sibling on the
/// same fs, reset each launch). `skeleton = Some(tar)` → extract the tar into a fresh tmpfs and stack it as a
/// data-only metadata layer ABOVE `lower` with `userxattr` (so a root-owned store `lower` becomes writable-CoW
/// unprivileged, data preserved). `child_skel = Some(dir)` → append it as the BOTTOM lowerdir so nested
/// sub-mounts have a mountpoint the content lacks (user-owned tmpfs — no metacopy).
fn mount_overlay(
    idx: usize,
    target: &str,
    lower: &str,
    upper: Option<&str>,
    ro: bool,
    skeleton: Option<&str>,
    child_skel: Option<&str>,
    tar_bin: &str,
) -> Result<(), String> {
    // `target` already exists as a dir mountpoint — the parent entry's child skeleton (or the mkdtemp view,
    // for the root) provides it, laid parent-first before this overlay.
    // Resolve the lower stack. With a skeleton, extract its tar into a fresh ns-private tmpfs and stack it
    // as a data-only metadata layer above the store `lower` (`<skel>::<lower>`); userxattr is mandatory
    // unprivileged (metacopy/redirect + whiteouts use the user.overlay.* namespace). The stubs are SPARSE
    // and sized to the originals, so copy-up on write pulls the full data from the store layer. Without a
    // skeleton, `lower` is used directly (a user-owned or ephemeral lower). A `child_skel` is appended at the
    // BOTTOM (lowest priority — it only fills mountpoints nothing above provides).
    let (lowerdir, xattr_opt) = match skeleton {
        Some(tar) => {
            if tar_bin.is_empty() {
                return Err("skeleton set but no `--tar` binary was provided by the launcher".to_string());
            }
            let skel = format!("/tmp/.propnix-skel-{idx}");
            std::fs::create_dir_all(&skel).map_err(|e| format!("mkdir {skel}: {e}"))?;
            let sc = CString::new(skel.as_str()).unwrap();
            let ty = CString::new("tmpfs").unwrap();
            if unsafe { libc::mount(ty.as_ptr(), sc.as_ptr(), ty.as_ptr(), 0, std::ptr::null()) } != 0 {
                return Err(format!("tmpfs at {skel}: {}", oserr()));
            }
            let status = Command::new(tar_bin)
                .args(["--sparse", "--no-same-owner", "-xf", tar, "-C", skel.as_str()])
                .status()
                .map_err(|e| format!("exec {tar_bin}: {e}"))?;
            if !status.success() {
                return Err(format!("extracting skeleton {tar} into {skel}: tar {status}"));
            }
            // The tar carries only sized sparse stubs — the Nix build sandbox can't set user.* xattrs — so
            // stamp the data-only metacopy/redirect xattrs now, on the tmpfs (which supports them).
            let skel_root = Path::new(&skel);
            apply_metacopy_xattrs(skel_root, skel_root)?;
            // Merge the child mountpoint stubs INTO this (normal) skeleton layer, not as a separate lowerdir:
            // the store `lower` here is a DATA-ONLY layer (the `::`), so a stub appended after it would be
            // invisible; and a stub in a SECOND normal lowerdir breaks the metacopy redirect. Same layer works.
            if let Some(cs) = child_skel {
                seed_dir(cs, &skel)?;
            }
            (format!("{skel}::{lower}"), ",userxattr")
        }
        None => {
            // No metacopy/data-only layer → the child mountpoint stubs are simply another normal lowerdir.
            let ld = match child_skel {
                Some(cs) => format!("{lower}:{cs}"),
                None => lower.to_string(),
            };
            (ld, "")
        }
    };
    // Read-only: a lowerdir-only overlay (no upper/work) — the merged tree is read-only.
    if ro {
        let opts = format!("lowerdir={lowerdir}{xattr_opt}");
        return finish_overlay_mount(target, &opts);
    }
    let (upperdir, workdir) = match upper {
        None => {
            // Fresh tmpfs (ns-private, self-cleaning); its up/work back the ephemeral upper.
            let scratch = format!("/tmp/.propnix-ovl-{idx}");
            std::fs::create_dir_all(&scratch).map_err(|e| format!("mkdir {scratch}: {e}"))?;
            let sc = CString::new(scratch.as_str()).unwrap();
            let ty = CString::new("tmpfs").unwrap();
            if unsafe {
                libc::mount(ty.as_ptr(), sc.as_ptr(), ty.as_ptr(), 0, std::ptr::null())
            } != 0
            {
                return Err(format!("tmpfs at {scratch}: {}", oserr()));
            }
            let (up, wk) = (format!("{scratch}/up"), format!("{scratch}/work"));
            std::fs::create_dir_all(&up).map_err(|e| format!("mkdir {up}: {e}"))?;
            std::fs::create_dir_all(&wk).map_err(|e| format!("mkdir {wk}: {e}"))?;
            (up, wk)
        }
        Some(u) => {
            // Persistent upper (the launcher created it). overlay's workdir must be an EMPTY dir on the same
            // filesystem as the upper — use a sibling, reset each launch (it's scratch, never user data).
            let wk = format!("{u}.propnix-work");
            let _ = std::fs::remove_dir_all(&wk);
            std::fs::create_dir_all(&wk).map_err(|e| format!("mkdir {wk}: {e}"))?;
            (u.to_string(), wk)
        }
    };
    let opts = format!("lowerdir={lowerdir},upperdir={upperdir},workdir={workdir}{xattr_opt}");
    finish_overlay_mount(target, &opts)
}

/// Issue the `mount(2)` for an already-composed overlay options string.
fn finish_overlay_mount(target: &str, opts: &str) -> Result<(), String> {
    let src = CString::new("overlay").unwrap();
    let tgt = CString::new(target).unwrap();
    let ty = CString::new("overlay").unwrap();
    let data = CString::new(opts).unwrap();
    if unsafe {
        libc::mount(
            src.as_ptr(),
            tgt.as_ptr(),
            ty.as_ptr(),
            0,
            data.as_ptr() as *const libc::c_void,
        )
    } != 0
    {
        return Err(oserr());
    }
    Ok(())
}

/// Stamp a freshly-extracted skeleton tree with the data-only overlay xattrs. The tar holds only sized
/// sparse stubs (the Nix build sandbox can't set user.* xattrs); here — on the tmpfs, which supports them —
/// each regular-file stub gets `user.overlay.metacopy` (present) + `user.overlay.redirect=/<relpath>` (its
/// own path, i.e. where its data lives in the store data layer). Symlinks/dirs are left as-is. Recursive.
fn apply_metacopy_xattrs(root: &Path, dir: &Path) -> Result<(), String> {
    let rd = std::fs::read_dir(dir).map_err(|e| format!("readdir {}: {e}", dir.display()))?;
    for ent in rd {
        let ent = ent.map_err(|e| format!("readdir {}: {e}", dir.display()))?;
        let ft = ent.file_type().map_err(|e| format!("filetype: {e}"))?;
        let path = ent.path();
        if ft.is_dir() {
            apply_metacopy_xattrs(root, &path)?;
        } else if ft.is_file() {
            use std::os::unix::ffi::OsStrExt;
            let rel = path
                .strip_prefix(root)
                .map_err(|_| format!("strip_prefix {}", path.display()))?;
            let mut redirect = vec![b'/'];
            redirect.extend_from_slice(rel.as_os_str().as_bytes());
            set_xattr(&path, "user.overlay.metacopy", b"")?;
            set_xattr(&path, "user.overlay.redirect", &redirect)?;
        }
    }
    Ok(())
}

fn set_xattr(path: &Path, name: &str, value: &[u8]) -> Result<(), String> {
    use std::os::unix::ffi::OsStrExt;
    let cpath = CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
    let cname = CString::new(name).unwrap();
    let ret = unsafe {
        libc::setxattr(
            cpath.as_ptr(),
            cname.as_ptr(),
            value.as_ptr() as *const libc::c_void,
            value.len(),
            0,
        )
    };
    if ret != 0 {
        return Err(format!(
            "setxattr {name} on {}: {}",
            path.display(),
            oserr()
        ));
    }
    Ok(())
}
