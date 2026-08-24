//! THIN-mode run path — a native or box64-emulated Linux game (no wine prefix). The counterpart to the
//! wine PREFIX path in main.rs/run.rs, sharing all the display-agnostic machinery: the user+mount namespace
//! (propnix-mount), single-instance focus, the GTK splash, the compositor window-watcher, signals.
//!
//! What DIVERGES from wine:
//!   * There is no WINEPREFIX. The mount view root is instead a fresh per-launch tmpfs used as the game's
//!     `$HOME` (resolve_binds leads the table with a source-less tmpfs root entry, whose child-skeleton makes
//!     the save mountpoints). The declared save/state `binds` are mounted onto it (their persistent
//!     `$STATE`/`$PROPNIX_SAVE_DIR` sources bound at paths under the view $HOME), so the game writes its own
//!     native paths (`$HOME/.local/share/…`) while the data lands in propnix-managed dirs — the same
//!     PROPNIX_SAVE_DIR/<appid> semantics the wine path gives.
//!   * The game tree is a READ-ONLY overlay/bind propnix-mount lays at the view's game dir (`gameLowers`,
//!     unioned for free when several depots) — no build-time merge, no store copy. The INNER execs the game
//!     from it (`box64 <gameDir>/exe …` on aarch64, the native ELF on x86_64) with a scrubbed env + the baked
//!     LD_LIBRARY_PATH (native bridging libs ∪ x86_64 guest libs). No registry, no wineserver: teardown is a
//!     process-group kill.
//!   * A native SDL/GL game emits none of wine's D3D first-present stderr markers, so the splash dismiss
//!     relies on the window-watcher (game window MAPs → dismiss; window DESTROYED → force teardown).

use crate::config::{ThinConfig, THIN_BINFIX_DIR, THIN_GAME_DIR};
use crate::settings::{Paths, Settings};
use crate::{focus, mount, run, settings, signals, splash, util};
use propnix_mount::Entry;
use std::io;
use std::os::unix::process::CommandExt; // process_group
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::sync::mpsc;
use std::time::Duration;

/// Entry point for a `mode = "thin"` config (main.rs dispatches here after the mode probe). Mirrors the
/// two-phase structure of the wine path: the OUTER mints the view + assembles the mount ns and drives the
/// splash; the INNER (re-exec'd `--inside-ns`) execs the game inside the assembled view.
pub fn run(config_path: &str, unseal: bool, inside_ns: bool, view_arg: Option<&str>, passthrough: &[String]) -> ExitCode {
    let cfg = match ThinConfig::load(config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix-launcher: {e}");
            return ExitCode::FAILURE;
        }
    };
    signals::install();

    let settings = settings::Settings::resolve_thin(&cfg.app_id, unseal);

    if !inside_ns && std::env::var("PROPNIX_DEBUG").is_ok() {
        eprintln!("propnix: mode=thin appid={}", settings.appid);
    }

    // The mount-view root: the OUTER mints a fresh random /tmp dir (the game's $HOME); the INNER is handed
    // that same path back via `--view` (propnix-mount already laid the tmpfs + save binds there).
    let view = if inside_ns {
        match view_arg {
            Some(v) => PathBuf::from(v),
            None => {
                eprintln!("propnix-launcher: --inside-ns requires --view");
                return ExitCode::from(2);
            }
        }
    } else {
        match mount::make_view(&settings.appid) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("propnix-launcher: create mount view: {e}");
                return ExitCode::FAILURE;
            }
        }
    };
    let paths = settings.paths(view);

    if inside_ns {
        run_inner(&cfg, &settings, &paths, passthrough)
    } else {
        run_outer(cfg, settings, paths, config_path, passthrough, unseal)
    }
}

/// OUTER: gate on userns, make the persistent dirs, guard single-instance, resolve the save binds into the
/// mount table, spawn the game through propnix-mount, and cover cold start with the splash + window-watcher.
fn run_outer(
    cfg: ThinConfig,
    settings: Settings,
    paths: Paths,
    config_path: &str,
    passthrough: &[String],
    unseal: bool,
) -> ExitCode {
    // The view root is cleaned up by RAII (mount::ViewGuard) on EVERY exit path below — declared first so
    // it drops last, after the worker join has reaped the mount child.
    let _view_guard = mount::ViewGuard(paths.view.clone());

    if !mount::userns_supported() {
        eprintln!(
            "propnix: this host does not allow unprivileged user namespaces, which propnix needs to \
             assemble the game's private mount view.\n  Enable them and retry (NixOS enables them by default)."
        );
        return ExitCode::FAILURE;
    }

    // The persistent dirs: `state` (PROPNIX_STATE root), `cache`, and `runtime` (the single-instance lock).
    // No DXVK/vkd3d shader-cache dirs — that is the wine backend's concern.
    for d in [&paths.state, &paths.cache, &paths.runtime] {
        if let Err(e) = std::fs::create_dir_all(d) {
            eprintln!("propnix-launcher: mkdir {}: {e}", d.display());
            return ExitCode::FAILURE;
        }
    }

    // Single-instance guard (shared with the wine path). The window needle is the appid slug — a native SDL
    // game sets its Wayland app_id / X11 WM_CLASS to the exe basename, which matches the slug for our titles;
    // `raise_running`/`game_window_probe` also match on the title and the `org.propnix.<appid>` splash id.
    let needle = settings.appid.clone();
    let app_id = format!("org.propnix.{}", settings.appid);
    let _lock = if cfg.single_instance {
        match focus::acquire(&paths.runtime) {
            Ok(focus::Lock::Acquired(f)) => Some(f), // held until process exit
            Ok(focus::Lock::Busy) => {
                eprintln!("propnix: {} is already running", cfg.name);
                focus::raise_running(&needle, &cfg.name, &app_id);
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("propnix-launcher: single-instance lock: {e}");
                return ExitCode::FAILURE;
            }
        }
    } else {
        None
    };

    // Set the runtime PROPNIX_* roots (PROPNIX_STATE/APPID + the normalized PROPNIX_SAVE_DIR) the bind
    // sources expand against — the same helper the wine table uses — then resolve the save binds.
    if let Err(e) = mount::set_mount_env(&settings, &paths) {
        eprintln!("propnix-launcher: {e}");
        return ExitCode::FAILURE;
    }
    let entries = match resolve_thin_table(&cfg, &paths.view) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("propnix-launcher: mount table: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Quiet GTK's Vulkan-ICD probe warnings on Asahi (cairo renderer is plenty for the splash).
    if cfg.splash && std::env::var_os("GSK_RENDERER").is_none() {
        std::env::set_var("GSK_RENDERER", "cairo");
    }

    // MUST be single-threaded here — spawn_mounted's pre_exec assembles the view post-fork. resolve_binds
    // leads the table with a source-less tmpfs at the view root (the game's $HOME), whose child-skeleton
    // creates each save bind's mountpoint; the save binds then land on it.
    let (child, reader) = match run::spawn_mounted(
        &cfg.tar,
        config_path,
        &paths.view,
        entries,
        unseal,
        passthrough,
        cfg.online,
    ) {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("propnix-launcher: launch failed: {e}");
            return ExitCode::FAILURE;
        }
    };

    let (tx, rx) = mpsc::channel::<run::Progress>();

    // Compositor window-watcher (run::watch_window): for a native SDL/GL game there is NO first-present
    // stderr marker for watch_child to scan, so the splash relies entirely on the window MAPping; and once
    // it has appeared, its DESTRUCTION means the user closed the game → force teardown.
    if cfg.window_watch {
        let tx = tx.clone();
        let needle = needle.clone();
        let title = cfg.name.clone();
        let splash_app_id = app_id.clone();
        std::thread::spawn(move || run::watch_window(tx, needle, title, splash_app_id));
    }

    // Move `settings` into the worker (watch_child borrows it for the run; nothing below needs it — the
    // splash/window ids were already cloned above).
    let worker = std::thread::spawn(move || run::watch_child(child, reader, &settings, tx));

    let code = if cfg.splash {
        splash::run(app_id, cfg.name.clone(), cfg.icon.clone(), rx)
    } else {
        headless_wait(rx)
    };
    let _ = worker.join();
    ExitCode::from((code & 0xff) as u8)
}

/// Splash-disabled wait: drain the worker's progress channel until the game exits, returning its code. The
/// window-watcher's `Presented` events are ignored (nothing to dismiss); only `Exited` ends the wait.
fn headless_wait(rx: mpsc::Receiver<run::Progress>) -> i32 {
    loop {
        match rx.recv() {
            Ok(run::Progress::Exited(code)) => return code,
            Ok(run::Progress::Presented) => {}
            Err(_) => return 1, // worker dropped the sender without an Exited — treat as failure
        }
    }
}

/// Resolve the THIN mount table into the parent-first `Vec<Entry>` propnix-mount lays. Three parts:
///   1. an explicit source-less tmpfs at the view ROOT (the game's $HOME) — a REAL entry so propnix-mount
///      builds its child-skeleton (enter_and_mount's rootless fallback lays a bare tmpfs with NO skeleton, so
///      the game/save mountpoints wouldn't exist inside it → ENOENT);
///   2. the GAME DIR (`THIN_GAME_DIR` under the view): the `gameLowers` mounted READ-ONLY — a plain bind for a
///      single tree, a lowerdir-only overlayfs UNION for several depots (merged for free, no store copy);
///   3. the save/state `binds`: each `src` (a persistent `$VAR`-expandable dir — typically
///      `$PROPNIX_SAVE_DIR/$PROPNIX_APPID`) bound at `dst` under the view $HOME (created if `create`).
fn resolve_thin_table(cfg: &ThinConfig, view: &Path) -> io::Result<Vec<Entry>> {
    let mut entries: Vec<Entry> = vec![Entry::Mount {
        target: view.to_string_lossy().into_owned(),
        source: None, // a fresh ephemeral tmpfs — the game's $HOME
        mode: "rw".to_string(),
        seed: None,
    }];

    // The game dir: the read-only game tree, unioned from `gameLowers` (+ an optional exec-bit-fix layer on
    // top). The lowers list, highest-priority first:
    //   * with a `gameModeFix`: an intermediate metacopy overlay `skeleton::lower` (userxattr) is mounted at
    //     THIN_BINFIX_DIR first — its exe stubs are +x while data redirects to the store (zero copy) — then
    //     stacked ABOVE `gameLowers` (so the +x executables win over the depots' 0444 originals);
    //   * `gameLowers` themselves (the data depots), unioned read-only.
    // The final game mount is: 1 lower → a read-only bind; several → a read-only overlay UNION (leftmost wins).
    let game_target = view.join(THIN_GAME_DIR).to_string_lossy().into_owned();
    let mut game_lowers: Vec<String> = Vec::new();
    if let Some(mf) = &cfg.game_mode_fix {
        // Entry: the metacopy exec-bit-fix overlay (`skeleton::lower`, userxattr — propnix-mount's skeleton
        // path), mounted read-only at THIN_BINFIX_DIR. Sorts before the game dir (`.` < `g`), so it is laid
        // first and the game overlay below can reference it as a lower.
        let binfix_target = view.join(THIN_BINFIX_DIR).to_string_lossy().into_owned();
        entries.push(Entry::Overlay {
            target: binfix_target.clone(),
            lower: mf.lower.clone(),
            upper: None,
            skeleton: Some(mf.skeleton.clone()),
            ro: true,
        });
        game_lowers.push(binfix_target);
    }
    game_lowers.extend(cfg.game_lowers.iter().cloned());
    if game_lowers.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "thin config has empty gameLowers".to_string(),
        ));
    }
    entries.push(if game_lowers.len() == 1 {
        Entry::Mount {
            target: game_target,
            source: Some(game_lowers.remove(0)),
            mode: "ro".to_string(),
            seed: None,
        }
    } else {
        Entry::Overlay {
            target: game_target,
            lower: game_lowers.join(":"),
            upper: None,
            skeleton: None,
            ro: true,
        }
    });

    for b in &cfg.binds {
        let src = util::expand_env(&b.src);
        let p = Path::new(&src);
        if !p.exists() {
            if b.create {
                std::fs::create_dir_all(p)?;
            } else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("bind source {src} does not exist (set create = true to create it)"),
                ));
            }
        }
        let target = view.join(&b.dst).to_string_lossy().into_owned();
        entries.push(Entry::Mount {
            target,
            source: Some(src),
            mode: if b.ro { "ro" } else { "rw" }.to_string(),
            seed: None,
        });
    }
    // Erase masked files from the game dir (e.g. a Steam game's libsteam_api.so): one whiteout entry each,
    // targeting the game-dir-relative path. Sorted parent-first below, so the game overlay is laid first.
    for m in &cfg.mask_files {
        let target = view
            .join(THIN_GAME_DIR)
            .join(m)
            .to_string_lossy()
            .into_owned();
        entries.push(Entry::Whiteout { target });
    }
    propnix_mount::sort_parent_first(&mut entries);
    Ok(entries)
}

/// INNER (`--inside-ns`): the view (the game's $HOME tmpfs + save binds) is live. Build the sealed env, exec
/// the game in its own process group with inherited stdio (→ the outer's read pipe), wait, and tear down with
/// a process-group kill on exit/cancel. Returns the game's exit code.
fn run_inner(cfg: &ThinConfig, settings: &Settings, paths: &Paths, passthrough: &[String]) -> ExitCode {
    // The game dir is the read-only overlay/bind propnix-mount laid at THIN_GAME_DIR under the view; the exe is
    // resolved as an ABSOLUTE path within it (Command::new resolves a relative program against OUR cwd, not the
    // child's current_dir — so never pass a bare `./exe`). cwd = the game dir, or its `workingDir` subdir for
    // an engine (Clausewitz) that resolves its data root from the cwd.
    let game_dir = paths.view.join(THIN_GAME_DIR);
    let exe_path = game_dir.join(&cfg.exe);
    let cwd = match &cfg.working_dir {
        Some(rel) => game_dir.join(rel),
        None => game_dir.clone(),
    };
    // The command: `<emulator> <exe> …` on aarch64 (box64), the bare ELF on x86_64 (native).
    let mut cmd = match &cfg.emulator {
        Some(emu) => {
            let mut c = Command::new(emu);
            c.arg(&exe_path);
            c
        }
        None => Command::new(&exe_path),
    };
    cmd.args(&cfg.exe_args).args(passthrough).current_dir(&cwd);

    // TARGETED SCRUB (never env_clear): drop only inherited names matching a scrub prefix (BOX64_/FEX_/LD_/
    // WINE). LD_LIBRARY_PATH is scrubbed here and reset below (matching the POC), so a host LD_PRELOAD of a
    // native aarch64 allocator can't be injected into the x86 guest.
    if !settings.unseal {
        let unset: Vec<String> = std::env::vars()
            .map(|(k, _)| k)
            .filter(|k| cfg.scrub_prefixes.iter().any(|p| k.starts_with(p)))
            .collect();
        for k in &unset {
            cmd.env_remove(k);
        }
    }

    // $HOME = the ephemeral view; redirect the XDG *_HOME roots under it so the game's own data paths resolve
    // inside the view (only the explicitly-bound save dir persists — every other write is throwaway, the same
    // ephemeral-prefix contract the wine path gives). XDG_RUNTIME_DIR (sockets) and the system XDG_*_DIRS are
    // left intact. Applied BEFORE cfg.env so a game that pins its own XDG value can still override.
    cmd.env("HOME", &paths.view);
    for k in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"] {
        cmd.env_remove(k);
    }

    // The baked LD_LIBRARY_PATH (native bridging libs ∪ x86_64 guest libs) box64 folds into both its native
    // bridge resolution and the guest search path.
    if !cfg.ld_library_path.is_empty() {
        cmd.env("LD_LIBRARY_PATH", &cfg.ld_library_path);
    }

    // box64 DynaCache (box64 only): box64 serializes JIT'd guest blocks to disk and reuses them on later
    // launches, cutting cold-start JIT time — the box64 sibling of the wine path's DXVK/vkd3d shader caches
    // (set from `paths.cache` there too). box64 does NOT create the folder, so we point it at, and create, a
    // persistent per-app dir (`<cache>/box64`). Skipped for FEX (ignores BOX64_*) and native (no emulator).
    // Set BEFORE cfg.env so a game can still override (e.g. pin BOX64_DYNACACHE=0).
    if cfg.emulator.as_deref().map_or(false, |e| e.contains("box64")) {
        let dynacache = paths.cache.join("box64");
        let _ = std::fs::create_dir_all(&dynacache);
        cmd.env("BOX64_DYNACACHE", "1");
        cmd.env("BOX64_DYNACACHE_FOLDER", &dynacache);
    }

    // The baked "meant" env (BOX64_NORCFILES/PREFER_WRAPPED, etc.), each value $VAR-expanded.
    for (k, v) in &cfg.env {
        cmd.env(k, util::expand_env(v));
    }

    // SDL video-driver default (unless the config pinned it): PROPNIX_SDL_VIDEODRIVER wins; else Wayland when
    // a Wayland session is present, X11 otherwise. Harmless for a non-SDL game (it ignores the var).
    if !cfg.env.contains_key("SDL_VIDEODRIVER") {
        cmd.env("SDL_VIDEODRIVER", sdl_video_driver());
    }

    // PROPNIX_BENCH: MangoHud's OpenGL overlay (box64/native games are SDL/GL, not the wine path's Vulkan).
    // box64 renders through NATIVE Mesa (it wraps libGL) and ships a built-in special-case for
    // `libMangoHud_shim.so`'s `dlsym` — so the HUD is enabled exactly as the `mangohud` wrapper does:
    //   * LD_PRELOAD the SHIM (`<root>/lib/mangohud/libMangoHud_shim.so`) — box64's integration hooks it,
    //     routing the guest's GL entry-point `dlsym`s through MangoHud (a plain `libMangoHud.so` preload does
    //     NOT work under box64; that was the earlier mistake);
    //   * put `<root>/lib/mangohud` on LD_LIBRARY_PATH so the shim finds its opengl/dlsym siblings;
    //   * add `<root>/share` to XDG_DATA_DIRS for the Vulkan implicit layer (box64 Vulkan games).
    // dlsym is enabled by default (the wrapper does not set MANGOHUD_DLSYM). The seal scrubbed LD_*, so these
    // are set fresh, only under bench, layered over the LD_LIBRARY_PATH set above.
    if settings.bench {
        if let Some(mh) = &cfg.mangohud {
            let mhlib = format!("{mh}/lib/mangohud");
            cmd.env("MANGOHUD", "1");
            if std::env::var_os("MANGOHUD_CONFIG").is_none() {
                cmd.env(
                    "MANGOHUD_CONFIG",
                    "fps,frame_timing,cpu_stats,engine_version",
                );
            }
            let ld = if cfg.ld_library_path.is_empty() {
                mhlib.clone()
            } else {
                format!("{mhlib}:{}", cfg.ld_library_path)
            };
            cmd.env("LD_LIBRARY_PATH", ld);
            // Compose with a baked LD_PRELOAD (box64.guestPreload on native — e.g. Stellaris's offline
            // Steam entitlement shim) instead of clobbering it: benching must not silently drop what the
            // preload provides (there, every DLC).
            let preload = match cfg.env.get("LD_PRELOAD") {
                Some(v) if !v.is_empty() => {
                    format!("{mhlib}/libMangoHud_shim.so:{}", util::expand_env(v))
                }
                _ => format!("{mhlib}/libMangoHud_shim.so"),
            };
            cmd.env("LD_PRELOAD", preload);
            let base = match std::env::var("XDG_DATA_DIRS") {
                Ok(v) if !v.is_empty() => v,
                _ => "/usr/share".to_string(),
            };
            cmd.env("XDG_DATA_DIRS", format!("{mh}/share:{base}"));
        }
    }

    cmd.process_group(0);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix-launcher: failed to launch {}: {e}", exe_path.display());
            return ExitCode::FAILURE;
        }
    };
    let pgid = child.id() as i32;

    let code = loop {
        if signals::cancelled() {
            break reap_group(&mut child, pgid);
        }
        match child.try_wait() {
            Ok(Some(status)) => break run::code_of(status),
            Ok(None) => {}
            Err(e) => {
                eprintln!("propnix-launcher: wait failed: {e}");
                break 1;
            }
        }
        std::thread::sleep(Duration::from_millis(120));
    };
    ExitCode::from((code & 0xff) as u8)
}

/// Tear down the game's process group on cancel: SIGTERM first (a graceful chance to save + exit), then — if
/// it hasn't exited within a grace window — SIGKILL, which cannot be blocked. THIN has no wineserver to `-k`,
/// and native games commonly IGNORE SIGTERM (Clausewitz does), so without the SIGKILL escalation `wait()`
/// would block forever and hang the whole launcher tree. Returns 130 (terminated).
fn reap_group(child: &mut std::process::Child, pgid: i32) -> i32 {
    unsafe {
        libc::kill(-pgid, libc::SIGTERM);
    }
    // Poll for a graceful exit (~3 s), then force.
    for _ in 0..25 {
        match child.try_wait() {
            Ok(Some(_)) => return 130,
            _ => std::thread::sleep(Duration::from_millis(120)),
        }
    }
    unsafe {
        libc::kill(-pgid, libc::SIGKILL);
    }
    let _ = child.wait();
    130
}

/// The SDL video driver to request: an explicit `PROPNIX_SDL_VIDEODRIVER` verbatim, else `wayland` when a
/// Wayland session is present (`WAYLAND_DISPLAY`), else `x11`. (Read from the launcher's own env — PROPNIX_*
/// is never scrubbed.)
fn sdl_video_driver() -> String {
    if let Ok(v) = std::env::var("PROPNIX_SDL_VIDEODRIVER") {
        if !v.is_empty() {
            return v;
        }
    }
    match std::env::var("WAYLAND_DISPLAY") {
        Ok(v) if !v.is_empty() => "wayland".to_string(),
        _ => "x11".to_string(),
    }
}
