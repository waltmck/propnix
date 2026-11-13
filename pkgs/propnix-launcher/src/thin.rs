//! THIN-mode run path — a native or box64-emulated Linux game (no wine prefix). The counterpart to the
//! wine PREFIX path in main.rs/run.rs, sharing all the display-agnostic machinery: the user+mount namespace
//! (propnix-mount), gamescope (the game runs inside it, drawing through SDL's x11 driver), single-instance
//! focus, the GTK splash, the window-watcher, signals.
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
//!     relies on the window-watcher (gamescope has a game window → dismiss; gone for good → force teardown).

use crate::config::{payload_search_path, ThinConfig, THIN_BINFIX_DIR, THIN_GAME_DIR};
use crate::settings::{Paths, Settings};
use crate::{display, focus, gamescope, mount, run, settings, signals, splash, util};
use propnix_mount::Entry;
use std::io;
use std::os::unix::process::CommandExt; // process_group
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc;
use std::time::Duration;

/// Entry point for a `mode = "thin"` config (main.rs dispatches here after the mode probe). Mirrors the
/// two-phase structure of the wine path: the OUTER mints the view + assembles the mount ns and drives the
/// splash; the INNER (re-exec'd `--inside-ns`) execs the game inside the assembled view.
pub fn run(config_path: &str, unseal: bool, inside_ns: bool, view_arg: Option<&str>, passthrough: &[String]) -> u8 {
    let cfg = match ThinConfig::load(config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix-launcher: {e}");
            return 1;
        }
    };
    signals::install();

    // PROPNIX_WIDTH/HEIGHT from the compositor when unset — gamescope's size (gamescope.rs) and a setup
    // script's display facts. OUTER only, and here while still single-threaded: it mutates the process env.
    if !inside_ns {
        display::populate_facts();
    }

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
                return 2;
            }
        }
    } else {
        match mount::make_view(&settings.appid) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("propnix-launcher: create mount view: {e}");
                return 1;
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
) -> u8 {
    // The view root is cleaned up by RAII (mount::ViewGuard) on EVERY exit path below — declared first so
    // it drops last, after the worker join has reaped the mount child.
    let _view_guard = mount::ViewGuard(paths.view.clone());

    if !mount::userns_supported() {
        eprintln!(
            "propnix: this host does not allow unprivileged user namespaces, which propnix needs to \
             assemble the game's private mount view.\n  Enable them and retry (NixOS enables them by default)."
        );
        return 1;
    }

    // The persistent dirs: `state` (PROPNIX_STATE root), `cache`, and `runtime` (the single-instance lock).
    // No DXVK/vkd3d shader-cache dirs — that is the wine backend's concern.
    for d in [&paths.state, &paths.cache, &paths.runtime] {
        if let Err(e) = std::fs::create_dir_all(d) {
            eprintln!("propnix-launcher: mkdir {}: {e}", d.display());
            return 1;
        }
    }

    // Single-instance guard (shared with the wine path). `app_id` is the game's desktop-entry id, carried by
    // both the splash and gamescope's window.
    let app_id = format!("org.propnix.{}", settings.appid);
    let lock = if cfg.single_instance {
        match focus::acquire(&paths.runtime) {
            Ok(focus::Lock::Acquired(f)) => Some(f), // held until process exit
            Ok(focus::Lock::Busy) => {
                eprintln!("propnix: {} is already running", cfg.name);
                focus::raise_running(&paths.runtime);
                return 0;
            }
            Err(e) => {
                eprintln!("propnix-launcher: single-instance lock: {e}");
                return 1;
            }
        }
    } else {
        None
    };
    // A duplicate launch hands its activation token to this one (focus.rs) — single-instance games only.
    let activations = lock.as_ref().and_then(|_| {
        focus::listen(&paths.runtime)
            .map_err(|e| eprintln!("propnix-launcher: activation socket (a duplicate launch cannot focus this one): {e}"))
            .ok()
    });

    // Set the runtime PROPNIX_* roots (PROPNIX_STATE/APPID + the normalized PROPNIX_SAVE_DIR) the bind
    // sources expand against — the same helper the wine table uses — then resolve the save binds.
    if let Err(e) = mount::set_mount_env(&settings, &paths) {
        eprintln!("propnix-launcher: {e}");
        return 1;
    }
    let entries = match resolve_thin_table(&cfg, &paths.view) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("propnix-launcher: mount table: {e}");
            return 1;
        }
    };

    // Per-game SETUP SCRIPT — the same OUTER-phase hook the wine path runs, and for the same reason: it
    // seeds a config file in the game's own save dir, which is a host directory either way. Placed AFTER
    // set_mount_env + resolve_thin_table (so PROPNIX_SAVE_DIR/APPID are set and the save dir exists) and
    // BEFORE the view is assembled. A NON-ZERO exit ABORTS: a setup failure is a packaging bug or a
    // half-written config, not something to launch into.
    if let Some(script) = &cfg.setup_script {
        let mut cmd = std::process::Command::new(script);
        cmd.env("PROPNIX_PAYLOAD", &cfg.payload);
        // ALL the game trees, ':'-joined in mount-priority order — the head alone is not where a multi-depot
        // build necessarily ships the asset the script reads (config::payload_search_path).
        cmd.env(
            "PROPNIX_PAYLOADS",
            payload_search_path(&cfg.payload, &cfg.payloads),
        );
        match cmd.status() {
            Ok(s) if s.success() => {}
            Ok(s) => {
                eprintln!(
                    "propnix-launcher: setup script exited {} — aborting (packaging bug or corrupted config)",
                    run::code_of(s)
                );
                return 1;
            }
            Err(e) => {
                eprintln!("propnix-launcher: cannot run setup script {script}: {e}");
                return 1;
            }
        }
    }

    // Quiet GTK's Vulkan-ICD probe warnings on Asahi (cairo renderer is plenty for the splash).
    if cfg.splash && std::env::var_os("GSK_RENDERER").is_none() {
        std::env::set_var("GSK_RENDERER", "cairo");
    }

    // gamescope's per-launch host paths (its ready file + X socket dir), removed when this guard drops.
    let session = match gamescope::Session::create(&paths.runtime) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("propnix-launcher: gamescope session: {e}");
            return 1;
        }
    };
    let scaling = match gamescope::scaling(cfg.gamescope_filter.as_deref(), cfg.gamescope_scaler.as_deref()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("propnix-launcher: {e}");
            return 2;
        }
    };
    let gamescope_cmd = gamescope::command(&gamescope::Options {
        root: &cfg.gamescope,
        app_id: &app_id,
        title: &cfg.name,
        bench: settings.bench,
        fps: settings.fps,
        expose_wayland: effective_sdl_driver(&cfg).contains("wayland"),
        scaling: &scaling,
        mangohud: cfg.mangohud.as_deref(),
        fallback_gl: cfg.fallback_gl.as_ref(),
        ready: &session.ready,
    });

    // MUST be single-threaded here — spawn_mounted's pre_exec assembles the view post-fork. resolve_binds
    // leads the table with a source-less tmpfs at the view root (the game's $HOME), whose child-skeleton
    // creates each save bind's mountpoint; the save binds then land on it.
    let (child, reader) = match run::spawn_mounted(
        gamescope_cmd,
        &session.x11_dir,
        &session.status,
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
            return 1;
        }
    };

    let (tx, rx) = mpsc::channel::<run::Progress>();
    if let Some(listener) = activations {
        let tx = tx.clone();
        focus::serve(listener, move |token| {
            let _ = tx.send(run::Progress::Activate(token));
        });
    }

    // Game-window watcher (run::watch_window, through gamescope's nested X server): for a native SDL/GL game
    // there is NO first-present stderr marker for watch_child to scan, so the splash relies entirely on
    // gamescope having a game window to show; and once it has, the game's windows going away for good means
    // it is hung on shutdown → force teardown.
    if cfg.window_watch {
        let tx = tx.clone();
        let (ready, x11_dir) = (session.ready.clone(), session.x11_dir.clone());
        std::thread::spawn(move || run::watch_window(tx, ready, x11_dir));
    }

    // Move `settings` into the worker (watch_child borrows it for the run; nothing below needs it — the
    // splash/window ids were already cloned above).
    let status = session.status.clone();
    let worker = std::thread::spawn(move || run::watch_child(child, reader, status, &settings, tx));

    let code = if cfg.splash {
        splash::run(app_id, cfg.name.clone(), cfg.icon.clone(), rx, gamescope::activator(&session))
    } else {
        headless_wait(rx, gamescope::activator(&session))
    };
    let _ = worker.join();
    (code & 0xff) as u8
}

/// Splash-disabled wait: drain the worker's progress channel until the game exits, returning its code. The
/// window-watcher's `Presented` events are ignored (nothing to dismiss); activation requests go straight to
/// the game; only `Exited` ends the wait.
fn headless_wait(rx: mpsc::Receiver<run::Progress>, activate_game: impl Fn(String)) -> i32 {
    loop {
        match rx.recv() {
            Ok(run::Progress::Exited(code)) => return code,
            Ok(run::Progress::Presented) => {}
            Ok(run::Progress::Activate(token)) => activate_game(token),
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

    // The game dir: the read-only game tree, unioned from the lowers below, highest-priority first:
    //   * `gameLowers` — the layers that need no exec-bit fix (the backend's own overlays, the offline
    //     Steam-entitlement settings tree, a game's `extraLowers`);
    //   * one layer per `gameModeFixes` entry, IN ORDER — each an intermediate metacopy overlay
    //     `skeleton::lower` (userxattr) mounted read-only at its own THIN_BINFIX_DIR<i>, whose exe stubs are
    //     +x while data redirects to the store (zero copy). One per game tree, so a tree keeps its own place
    //     in the stack: fixing them as a single layer built from the primary payload would mirror that whole
    //     tree over everything above it and silently win against a DLC that ships its own build of the game.
    // Each binfix dir sorts before the game dir (`.` < `g`), so it is laid first and the game overlay below
    // can reference it as a lower.
    // The final game mount is: 1 lower → a read-only bind; several → a read-only overlay UNION (leftmost wins).
    let game_target = view.join(THIN_GAME_DIR).to_string_lossy().into_owned();
    let mut game_lowers: Vec<String> = cfg.game_lowers.clone();
    for (i, mf) in cfg.game_mode_fixes.iter().enumerate() {
        let binfix_target = view
            .join(format!("{THIN_BINFIX_DIR}{i}"))
            .to_string_lossy()
            .into_owned();
        entries.push(Entry::Overlay {
            target: binfix_target.clone(),
            lower: mf.lower.clone(),
            upper: None,
            skeleton: Some(mf.skeleton.clone()),
            ro: true,
        });
        game_lowers.push(binfix_target);
    }
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
                if b.kind == crate::config::BindKind::File {
                    if let Some(parent) = p.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    std::fs::File::create(p)?;
                } else {
                    std::fs::create_dir_all(p)?;
                }
            } else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("bind source {src} does not exist (set create = true to create it)"),
                ));
            }
        }
        // `dst` is view-relative — EXCEPT when it expands to an absolute path, which `Path::join` then
        // takes verbatim, landing the bind OUTSIDE the view. That is deliberate, and exactly one kind of
        // game needs it: a port that resolves its data directory from /etc/passwd
        // (`getpwuid(getuid())->pw_dir`) rather than from $HOME reaches the launching user's REAL home no
        // matter what this process sets, so the only way to redirect it is to bind the save dir onto that
        // absolute path inside the namespace. (Civ V's Aspyr shim does this for one file — see
        // pkgs/games/civilization-5's saveBinds. Its game FOLDER honours XDG_DATA_HOME and lands in the
        // view; the stray one would otherwise persist to the real home, escaping the sandbox.)
        //
        // Expansion makes that expressible without hardcoding a user: `$HOME/...` resolves against the
        // LAUNCHER's own env, whose HOME is the real one (the child's is set to the view further down).
        // Existing relative dsts contain no `$`, so this is a no-op for them.
        let dst = util::expand_env(&b.dst);
        let target = view.join(&dst);
        // An out-of-view target has no parent entry to provide it as a mountpoint (propnix-mount's plain
        // bind requires the target to exist), so create it here — on the HOST, deliberately: an empty
        // directory in the user's home that the bind immediately covers for the life of the launch.
        if Path::new(&dst).is_absolute() && !target.exists() {
            if b.create {
                std::fs::create_dir_all(&target)?;
            } else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!(
                        "bind target {} is outside the view and does not exist \
                         (set create = true to make it)",
                        target.display()
                    ),
                ));
            }
        }
        entries.push(Entry::Mount {
            target: target.to_string_lossy().into_owned(),
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
fn run_inner(cfg: &ThinConfig, settings: &Settings, paths: &Paths, passthrough: &[String]) -> u8 {
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
    //
    // Each root is SET to its view path, not unset. Unsetting looks equivalent — the freedesktop default is
    // exactly `$HOME/<subdir>`, which is where a game that reads $HOME lands either way — but it silently
    // fails for a game that does NOT read $HOME. Civ V's Aspyr shim resolves the home directory with
    // `getpwuid(getuid())->pw_dir` (the binary imports getpwuid and contains no "HOME" string at all), so
    // with these unset it writes its saves, settings and databases to the REAL ~/.local/share/Aspyr,
    // escaping the view entirely and leaving the game's own save bind inert. It does read XDG_DATA_HOME,
    // so stating the value fixes it — and states the contract for every other passwd-reading port too.
    cmd.env("HOME", &paths.view);
    for (k, sub) in [
        ("XDG_DATA_HOME", ".local/share"),
        ("XDG_CONFIG_HOME", ".config"),
        ("XDG_CACHE_HOME", ".cache"),
        ("XDG_STATE_HOME", ".local/state"),
    ] {
        cmd.env(k, paths.view.join(sub));
    }

    // Steam-emulated build (cfg.steam_emu): gbe_fork generates its own identity in its global settings
    // under the data home — which on THIN is the ephemeral view, so it is minted afresh each launch. The
    // launcher does not seat a stored SteamID64 here: that would read the credential store as the
    // launching human, which the group-ownership contract does not permit on declarative/shared hosts.

    // The baked LD_LIBRARY_PATH (native bridging libs ∪ x86_64 guest libs) box64 folds into both its native
    // bridge resolution and the guest search path — extended with the GL/Vulkan fallback stack when the
    // host provides none (or the game forced one). Each discovery var is guarded: a per-game env entry or
    // an inherited session var for the same name wins over what the fallback derives.
    let gl = crate::glstack::resolve(cfg.fallback_gl.as_ref());
    let ld_library_path = crate::glstack::extend_ld_path(&cfg.ld_library_path, gl.as_ref());
    if !ld_library_path.is_empty() {
        cmd.env("LD_LIBRARY_PATH", &ld_library_path);
    }
    if let Some(g) = &gl {
        for (k, v) in &g.vars {
            if !cfg.env.contains_key(*k) && std::env::var_os(k).is_none() {
                cmd.env(k, v);
            }
        }
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
    // FEX's equivalent (FEX only): the disk cache of JIT'd guest blocks, in the same directory the wine path
    // uses (`paths.fex_cache`, named by kernel TSO support). Same placement and override rule as above.
    if cfg.emulator.as_deref().map_or(false, |e| e.to_ascii_lowercase().contains("fex")) {
        let diskcache = &paths.fex_cache;
        let _ = std::fs::create_dir_all(diskcache);
        cmd.env("FEX_DISKCACHE", "1");
        cmd.env("FEX_DISKCACHEPATH", format!("{}/", diskcache.to_string_lossy()));
    }

    // The baked "meant" env (BOX64_NORCFILES/PREFER_WRAPPED, etc.), each value $VAR-expanded.
    for (k, v) in &cfg.env {
        cmd.env(k, util::expand_env(v));
    }

    // SDL video-driver default (unless the config pinned it): PROPNIX_SDL_VIDEODRIVER wins; else x11, the
    // driver for gamescope's Xwayland. Set explicitly: gamescope unsets the var, and SDL3 would otherwise try
    // Wayland, which with WAYLAND_DISPLAY unset means the host's `wayland-0`. A `wayland` choice gets
    // gamescope's own Wayland display (`effective_sdl_driver`). Harmless for a non-SDL game.
    if !cfg.env.contains_key("SDL_VIDEODRIVER") {
        cmd.env("SDL_VIDEODRIVER", sdl_video_driver());
    }

    // gamescope's WSI layer on the Vulkan loader's search path (gamescope.rs `xdg_data_dirs`): box64 wraps the
    // NATIVE libvulkan, so a Vulkan game's swapchain goes to gamescope directly. Unless the game pinned its
    // own. (PROPNIX_BENCH's overlay is gamescope's mangoapp, which needs nothing in here.)
    if !cfg.env.contains_key("XDG_DATA_DIRS") {
        cmd.env("XDG_DATA_DIRS", gamescope::xdg_data_dirs(&cfg.gamescope));
    }

    cmd.process_group(0);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix-launcher: failed to launch {}: {e}", exe_path.display());
            return 1;
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
    (code & 0xff) as u8
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

/// The SDL video driver the game will run with: its own pinned `SDL_VIDEODRIVER`, else `sdl_video_driver()`.
/// A `wayland` one makes gamescope serve its own Wayland display (gamescope.rs `expose_wayland`).
fn effective_sdl_driver(cfg: &ThinConfig) -> String {
    match cfg.env.get("SDL_VIDEODRIVER") {
        Some(v) => util::expand_env(v),
        None => sdl_video_driver(),
    }
}

/// The SDL video driver to request: an explicit `PROPNIX_SDL_VIDEODRIVER` verbatim, else `x11`. (Read from
/// the launcher's own env — PROPNIX_* is never scrubbed.)
fn sdl_video_driver() -> String {
    match std::env::var("PROPNIX_SDL_VIDEODRIVER") {
        Ok(v) if !v.is_empty() => v,
        _ => "x11".to_string(),
    }
}
