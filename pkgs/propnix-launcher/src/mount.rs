//! The WINEPREFIX mount-table backend — assembles the ENTIRE prefix the game sees from a declarative table
//! (binds + COW overlays, with optional per-mount `seed` population). Two jobs:
//!   * gate on unprivileged user namespaces (`userns_supported`): propnix-mount needs one to bind, so the
//!     outer refuses to launch with an actionable error if the host lacks them.
//!   * resolve `cfg.mounts` (store paths already baked literal by Nix; `$VAR` runtime roots expanded here) +
//!     the dynamic DXVK/vkd3d DLL overlays into the absolute, parent-first topology JSON propnix-mount consumes.

use crate::config::{Config, Mount, MountSpec};
use crate::settings::{Paths, Settings};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::os::unix::ffi::OsStringExt;
use std::path::{Path, PathBuf};

/// Mint a fresh, RANDOM per-launch WINEPREFIX mount root under `$TMPDIR` (`.../propnix-<appid>-XXXXXX`, 0700
/// via mkdtemp; falls back to /tmp when TMPDIR is unset). The view is throwaway per launch — a clean split
/// between the WINEPREFIX and persistent state (which lives under `$PROPNIX_STATE/wine/`: the prefix root is
/// a persistent mount of `.../wine/prefix`, the profile overlays' uppers alongside). The kernel-ns binds
/// self-clean, so a prior unclean exit leaves at most an empty dir, never a stale mount.
/// `appid` is a safe kebab-case slug, no sanitizing.
pub fn make_view(appid: &str) -> io::Result<PathBuf> {
    let tmp = std::env::var_os("TMPDIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let mut buf = tmp
        .join(format!("propnix-{appid}-XXXXXX"))
        .into_os_string()
        .into_vec();
    buf.push(0); // NUL terminator for mkdtemp (which rewrites the trailing XXXXXX in place)
    let ret = unsafe { libc::mkdtemp(buf.as_mut_ptr() as *mut libc::c_char) };
    if ret.is_null() {
        return Err(io::Error::last_os_error());
    }
    buf.pop(); // drop the NUL
    Ok(PathBuf::from(std::ffi::OsString::from_vec(buf)))
}

/// RAII cleanup of the per-launch view root (`make_view`'s dir): best-effort `remove_dir` on Drop, so EVERY
/// outer exit path — including early error returns — removes the dir. Held by the OUTER for the whole run,
/// declared before anything else so it drops last (after the worker join has reaped the mount child).
/// Non-recursive and errors-ignored by design: the ns-private binds never appear in the outer's namespace,
/// so the dir is empty here — and while the child's ns still pins it as a mount root, rmdir just fails
/// EBUSY (harmless; an unclean exit leaves at most an empty dir, and the next launch mints a fresh random
/// root anyway).
pub struct ViewGuard(pub PathBuf);

impl Drop for ViewGuard {
    fn drop(&mut self) {
        // Skip removal during a PANIC unwind: between spawn_mounted and the worker join the game child may
        // still be running, and rmdir of a dir that is a mountpoint only in the child's namespace can
        // lazily detach it there (leak-on-panic is the safe pre-existing behavior; every normal return —
        // including the early error paths — still cleans up).
        if !std::thread::panicking() {
            let _ = std::fs::remove_dir(&self.0);
        }
    }
}

// A resolved table entry (LITERAL paths only). This is `propnix_mount::Entry` — the SAME type the linked
// mount code consumes (no JSON, no serialization): `resolve_table` builds a `Vec<Entry>` and hands it
// straight to `propnix_mount::enter_and_mount` via the mount child's `pre_exec` closure. For an Overlay,
// `upper = None` means EPHEMERAL (a fresh per-launch tmpfs for the upper+work); a set `upper` is persistent;
// `readOnly` overrides both — a lowerdir-only union (no upper at all), used to merge a base game with DLC.
use propnix_mount::Entry;

/// Probe in a throwaway child (unshare mutates the caller): can we create a user namespace at all?
/// propnix-mount needs one to assemble the prefix; the outer refuses to launch (with an actionable error)
/// if this returns false.
pub fn userns_supported() -> bool {
    unsafe {
        match libc::fork() {
            0 => {
                let ok = libc::unshare(libc::CLONE_NEWUSER) == 0;
                libc::_exit(if ok { 0 } else { 1 });
            }
            pid if pid > 0 => {
                let mut status = 0;
                libc::waitpid(pid, &mut status, 0);
                libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0
            }
            _ => false,
        }
    }
}

/// Set the RUNTIME `PROPNIX_*` roots that mount-path `$VAR` references expand against, and normalize
/// `PROPNIX_SAVE_DIR`. (The fixed store paths — the read-only lower and the payload — are baked as literal
/// paths in the table by Nix, so they are NOT env vars here.) Called once before the splash + worker
/// threads spawn, so mutating the process env here is single-threaded and safe.
///   * `PROPNIX_STATE` / `PROPNIX_CACHE` / `PROPNIX_APPID` — the app's state dir, cache dir and id.
///   * `PROPNIX_SAVE_DIR` — user-facing: an explicit-but-missing value is a hard error (a typo / unmounted
///     volume — fail loudly rather than write saves to the wrong place); unset → the default
///     `$XDG_DATA_HOME/propnix-saves`, created. Per-app dirs (`<root>/$PROPNIX_APPID`) are made by
///     `createIfNotExist` on the entry that uses them.
pub fn set_mount_env(settings: &Settings, paths: &Paths) -> io::Result<()> {
    std::env::set_var("PROPNIX_STATE", &paths.state);
    // The app's CACHE dir ($XDG_CACHE_HOME/propnix/<appid>) — the home for large DERIVED data a game
    // rebuilds when it is missing, so a bind row can put it somewhere the user does not back up. Same dir
    // the DXVK/vkd3d shader caches already use. Distinct from PROPNIX_STATE, which is for state worth
    // keeping: on a typical setup $XDG_CACHE_HOME can be pointed at a fast, un-snapshotted filesystem
    // while the state dir cannot.
    std::env::set_var("PROPNIX_CACHE", &paths.cache);
    std::env::set_var("PROPNIX_APPID", &settings.appid);
    let save_root = match std::env::var_os("PROPNIX_SAVE_DIR") {
        Some(v) if !v.is_empty() => {
            let root = PathBuf::from(&v);
            if !root.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!(
                        "PROPNIX_SAVE_DIR '{}' does not exist — create it, or unset it to use the default ({})",
                        root.display(),
                        crate::util::data_home().join("propnix-saves").display()
                    ),
                ));
            }
            root
        }
        _ => {
            let root = crate::util::data_home().join("propnix-saves");
            fs::create_dir_all(&root)?;
            root
        }
    };
    std::env::set_var("PROPNIX_SAVE_DIR", &save_root);
    Ok(())
}

/// Resolve the declared table (+ PROPNIX_EXTRA_BINDS + the dynamic DXVK/vkd3d overlays) into the absolute,
/// parent-first `Vec<Entry>` that the linked `propnix_mount::enter_and_mount` applies. `$VAR`s are expanded
/// here; only literals go out (passed in-memory to the mount child's pre_exec — no JSON, no table file).
pub fn resolve_table(cfg: &Config, settings: &Settings, paths: &Paths) -> io::Result<Vec<Entry>> {
    set_mount_env(settings, paths)?;
    let view = &paths.view;
    let mut entries: Vec<Entry> = Vec::new();

    // The prefix ROOT is itself a declared entry (mkWineApp injects target "" — a persistent mount of
    // `$PROPNIX_STATE/wine/prefix`, seeded once with the game-agnostic base user.reg). propnix-mount realizes
    // it as an overlay over a child-skeleton lower so every sub-mount's mountpoint exists; user.reg PERSISTS
    // there across launches (the three-way merge in userreg.rs reconciles it each launch), it is not
    // regenerated. Every entry below lays onto that root.

    // The declared table + any PROPNIX_EXTRA_BINDS (runtime rows; a matching target overrides the baked
    // one). Merged into one map so resolution + the topological sort see a single consolidated table.
    let mut all: BTreeMap<String, Mount> = cfg.mounts.clone();
    for (target, m) in parse_extra_binds() {
        all.insert(target, m);
    }

    for (target, m) in &all {
        if !m.enabled {
            continue;
        }
        let abs_target = resolve_target(target, view);
        let entry = match &m.spec {
            MountSpec::Mount { source, mode, seed } => {
                // `source` present → a bind of that path; `source` null → propnix-mount mounts a fresh
                // ns-private tmpfs at the target (nothing to pre-create here). `seed` (if set) is populated
                // into the target by propnix-mount at mount time.
                let source = match source {
                    Some(s) => {
                        let s = crate::util::expand_env(s);
                        ensure_writable(target, &s, m.create_if_not_exist, false)?;
                        Some(s)
                    }
                    None => None,
                };
                let seed = seed.as_deref().map(crate::util::expand_env);
                Entry::Mount {
                    target: abs_target,
                    source,
                    mode: mode.clone(),
                    seed,
                }
            }
            // A single regular FILE bound at the target — `createIfNotExist` touches the source instead of
            // mkdir'ing it, and propnix-mount lays a file mountpoint (its `child_is_file` already detects a
            // file source). See MountSpec::File for why this exists.
            MountSpec::File { source, mode } => {
                let s = crate::util::expand_env(source);
                ensure_writable(target, &s, m.create_if_not_exist, true)?;
                Entry::Mount {
                    target: abs_target,
                    source: Some(s),
                    mode: mode.clone(),
                    seed: None,
                }
            }
            MountSpec::Overlay {
                lower,
                upper,
                skeleton,
                read_only,
            } => {
                let lower = crate::util::expand_env(lower);
                // A read-only overlay has NO upper (lowerdir-only); never touch/create one even if given.
                let upper = if *read_only {
                    None
                } else {
                    match upper {
                        None => None, // ephemeral — propnix-mount mounts a fresh per-launch tmpfs
                        Some(u) => {
                            let u = crate::util::expand_env(u);
                            ensure_writable(target, &u, m.create_if_not_exist, false)?; // an overlay upper is always a dir
                            Some(u)
                        }
                    }
                };
                // The skeleton is a baked store path (a tar); expand_env is a harmless no-op on it.
                let skeleton = skeleton.as_deref().map(crate::util::expand_env);
                Entry::Overlay {
                    target: abs_target,
                    lower,
                    upper,
                    skeleton,
                    ro: *read_only,
                }
            }
            // Erase the target file from its parent (a bundled store-integration DLL); no source to prepare.
            MountSpec::Whiteout {} => Entry::Whiteout { target: abs_target },
        };
        entries.push(entry);
    }

    // DXVK (d3d9/10/11) + vkd3d-proton (d3d12) native ARM64EC DLLs, overlaid onto system32 when the DXVK
    // backend is active. NOT declarative — the sources are the resolved emulator store paths. Each shadows
    // wine's builtin of the same name (which exists in the store system32 → the bind mountpoint is present).
    if settings.is_dxvk() {
        let sys = view.join("drive_c/windows/system32");
        for (store, dll) in [
            (&cfg.emulators.dxvk, "d3d11"),
            (&cfg.emulators.dxvk, "d3d10core"),
            (&cfg.emulators.dxvk, "dxgi"),
            (&cfg.emulators.dxvk, "d3d9"),
            (&cfg.emulators.vkd3d, "d3d12"),
            (&cfg.emulators.vkd3d, "d3d12core"),
        ] {
            entries.push(Entry::Mount {
                target: sys.join(format!("{dll}.dll")).to_string_lossy().into_owned(),
                source: Some(format!("{store}/{dll}.dll")),
                mode: "ro".to_string(),
                seed: None,
            });
        }
    }

    // Parent-first: fewer path components bind before deeper ones, so a nested entry shadows its parent.
    propnix_mount::sort_parent_first(&mut entries);

    Ok(entries)
}

/// A target is a path RELATIVE to the prefix view root — join it to the view. The special EMPTY target is
/// the prefix root itself (the root overlay), which resolves to the view path exactly (no trailing slash, so
/// propnix-mount can match it against `--root`).
fn resolve_target(target: &str, view: &Path) -> String {
    if target.is_empty() {
        view.to_string_lossy().into_owned()
    } else {
        view.join(target).to_string_lossy().into_owned()
    }
}

/// Ensure a writable mount source / persistent overlay upper exists: create it (as a directory) when
/// allowed, else FAIL the launch (a missing store source/lower should fail loudly, not be silently created
/// empty).
fn ensure_writable(target: &str, path: &str, create: bool, is_file: bool) -> io::Result<()> {
    let p = Path::new(path);
    if p.exists() {
        return Ok(());
    }
    if !create {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("mount source for '{target}' does not exist: {path} (set createIfNotExist = true to create it)"),
        ));
    }
    if is_file {
        // A `file = true` row redirects one FILE, so the source must be a file — `mkdir` here would make
        // the game's expected file a directory and fail obscurely at open().
        if let Some(parent) = p.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::File::create(p).map(|_| ())
    } else {
        fs::create_dir_all(p)
    }
}

/// PROPNIX_EXTRA_BINDS → runtime bind rows: a `;`-separated list of `TARGET|SOURCE`, where TARGET is a
/// prefix-relative or env-var path (e.g. `drive_c/users/propnix/Documents/X`) and SOURCE is an absolute /
/// `$`-expandable host path. Each becomes a writable, self-creating bind that overrides a baked target of
/// the same name. The ad-hoc escape hatch (redirect a secondary save/mods dir without a rebuild); malformed
/// pairs skipped. `$VAR`s in either field are expanded later, alongside the declared table.
fn parse_extra_binds() -> Vec<(String, Mount)> {
    let spec = match std::env::var("PROPNIX_EXTRA_BINDS") {
        Ok(v) if !v.is_empty() => v,
        _ => return Vec::new(),
    };
    let mut out = Vec::new();
    for pair in spec.split(';') {
        if pair.is_empty() {
            continue;
        }
        match pair.split_once('|') {
            Some((t, s)) if !t.is_empty() && !s.is_empty() => out.push((
                t.to_string(),
                Mount {
                    spec: MountSpec::Mount {
                        source: Some(s.to_string()),
                        mode: "rw".to_string(),
                        seed: None,
                    },
                    enabled: true,
                    create_if_not_exist: true,
                },
            )),
            _ => eprintln!("propnix: ignoring malformed PROPNIX_EXTRA_BINDS entry {pair:?}"),
        }
    }
    out
}
