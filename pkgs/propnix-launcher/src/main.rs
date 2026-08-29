//! propnix-launcher — the per-app launcher. Two phases around the WINEPREFIX mount namespace:
//!   * OUTER — load the baked config → layer PROPNIX_* overrides → single-instance guard → seed the
//!     writable prefix upper + bind saves → resolve the mount table → run the game THROUGH propnix-mount
//!     (which lays down the bind view and re-execs us `--inside-ns`) while a GTK splash covers cold start.
//!   * INNER (`--inside-ns`, the prefix bind view live) — stamp the registry → spawn wine → tear down
//!     prefix-scoped on exit.
//! Nix computes the intended state (the config); this program enforces it via a bind-assembled prefix view.

mod config;
mod display;
mod env;
mod focus;
mod glstack;
mod graphics;
mod mount;
mod run;
mod settings;
mod signals;
mod splash;
mod steamid;
mod thin;
mod userreg;
mod util;

use std::path::Path;
use std::process::{Command, ExitCode};
use std::sync::mpsc;

struct Args {
    config: Option<String>,
    unseal: bool,    // --propnix-unseal: skip the env scrub (debug)
    inside_ns: bool, // --inside-ns: the propnix-mount re-exec — run the game inside the bind view
    view: Option<String>, // --view <path>: the mount-view root the OUTER minted, handed to the INNER
    passthrough: Vec<String>, // extra args handed to the game exe
}

fn parse_args(argv: &[String]) -> Args {
    let mut a = Args {
        config: None,
        unseal: false,
        inside_ns: false,
        view: None,
        passthrough: Vec::new(),
    };
    let mut only_rest = false;
    let mut i = 0;
    while i < argv.len() {
        let s = argv[i].as_str();
        if only_rest {
            a.passthrough.push(argv[i].clone());
            i += 1;
            continue;
        }
        match s {
            "--" => only_rest = true,
            "--config" => {
                i += 1;
                if i < argv.len() {
                    a.config = Some(argv[i].clone());
                }
            }
            "--propnix-unseal" => a.unseal = true,
            "--inside-ns" => a.inside_ns = true,
            "--view" => {
                i += 1;
                if i < argv.len() {
                    a.view = Some(argv[i].clone());
                }
            }
            _ if s.starts_with("--config=") => a.config = Some(s["--config=".len()..].to_string()),
            _ => a.passthrough.push(argv[i].clone()),
        }
        i += 1;
    }
    a
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = parse_args(&argv);

    let config_path = match &args.config {
        Some(p) => p.clone(),
        None => {
            eprintln!("propnix-launcher: --config <path> is required");
            return ExitCode::from(2);
        }
    };

    // Two launcher MODES, tagged by the config's `mode` field (default "prefix"). "thin" (box64 / native
    // Linux) diverges enough from wine — no WINEPREFIX, no registry, a direct execve — to warrant a separate
    // path with a different config shape (`ThinConfig`), so dispatch there before loading the wine `Config`
    // (whose required fields a thin config lacks). "prefix" falls through to the wine path below, unchanged.
    match config::ModeProbe::mode_of(&config_path) {
        Ok(m) if m == "thin" => {
            return thin::run(
                &config_path,
                args.unseal,
                args.inside_ns,
                args.view.as_deref(),
                &args.passthrough,
            );
        }
        Ok(_) => {}
        Err(e) => {
            eprintln!("propnix-launcher: {e}");
            return ExitCode::FAILURE;
        }
    }

    let cfg = match config::Config::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix-launcher: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Per-game `brokenVariables`: unset these env vars BEFORE anything else (fact population, Settings, the
    // seal), so a user's global PROPNIX_* that a title can't tolerate is neutralised for it. Single-threaded
    // here (no thread has spawned yet) → remove_var is safe. Applied in both phases; the inner also inherits
    // the already-unset env from the outer, so this is belt-and-suspenders.
    for v in &cfg.broken_variables {
        std::env::remove_var(v);
    }

    // Validate PROPNIX_QUALITY (a defined knob): if set, it must be one of the allowed levels — a typo is a
    // HARD ERROR (fail fast), not a silently-ignored value. The MEANING (which preset) is game-specific and
    // lives in the game's setupScript; the launcher only enforces the vocabulary, then passes it through.
    if let Some(q) = std::env::var("PROPNIX_QUALITY").ok().filter(|s| !s.is_empty()) {
        const ALLOWED: [&str; 5] = ["low", "medium", "high", "ultra", "default"];
        if !ALLOWED.contains(&q.as_str()) {
            eprintln!(
                "propnix-launcher: PROPNIX_QUALITY='{q}' is invalid — expected one of: {}",
                ALLOWED.join(", ")
            );
            return ExitCode::from(2);
        }
    }

    // Teardown on Ctrl-C / kill (the worker/inner observe the flag): plan §5 "EXIT/INT/TERM".
    signals::install();

    // Fill PROPNIX_WIDTH/HEIGHT from the compositor's primary output when unset (§5) — so a game's setupScript
    // gets a default that matches the live display. OUTER only: the inner re-exec inherits these via the env
    // (PROPNIX_* is not scrubbed). Runs here while single-threaded (before any thread) — it mutates the
    // process env. (Refresh/DPI are deliberately NOT derived — opt-in only; see display.rs.)
    if !args.inside_ns {
        display::populate_facts();
    }

    let settings = settings::Settings::resolve(&cfg, args.unseal);

    // Diagnostic only (the launcher is arch-transparent — it never branches on the backend): surface which
    // emulator set assembled this app when the user opts into PROPNIX_DEBUG.
    if !args.inside_ns && std::env::var("PROPNIX_DEBUG").is_ok() {
        eprintln!("propnix: backend={}", cfg.backend);
    }

    // The WINEPREFIX mount-view root: the OUTER mints a fresh random /tmp dir; the INNER is handed that same
    // path back via `--view` (propnix-mount has already assembled the bind view there).
    let view = if args.inside_ns {
        match &args.view {
            Some(v) => std::path::PathBuf::from(v),
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

    if args.inside_ns {
        run_inner(&cfg, &settings, &paths, &args)
    } else {
        run_outer(cfg, settings, paths, args, config_path)
    }
}

/// OUTER phase: prepare state, guard single-instance, seed the upper + saves, resolve the table, and run
/// the game through propnix-mount while showing the splash.
fn run_outer(
    cfg: config::Config,
    settings: settings::Settings,
    paths: settings::Paths,
    args: Args,
    config_path: String,
) -> ExitCode {
    // The view root is cleaned up by RAII (mount::ViewGuard) on EVERY exit path below — declared first so
    // it drops last, after the worker join has reaped the mount child.
    let _view_guard = mount::ViewGuard(paths.view.clone());

    // propnix-mount assembles the prefix inside a private user+mount namespace; without unprivileged userns
    // support there is no way to lay the binds, so fail fast with an actionable error.
    if !mount::userns_supported() {
        eprintln!(
            "propnix: this host does not allow unprivileged user namespaces, which propnix needs to \
             assemble the wine prefix.\n  Enable them and retry — e.g. on Debian/Ubuntu \
             `sudo sysctl -w kernel.unprivileged_userns_clone=1` (persist under /etc/sysctl.d), or ensure \
             the kernel has CONFIG_USER_NS and `user.max_user_namespaces` > 0. NixOS enables them by default."
        );
        return ExitCode::FAILURE;
    }

    // The `view` already exists (mkdtemp made the mountpoint; propnix-mount tmpfs's onto it). Create the
    // persistent dirs (state holds the overlay uppers + user.reg; cache the shader caches).
    for d in [&paths.state, &paths.cache, &paths.runtime] {
        if let Err(e) = std::fs::create_dir_all(d) {
            eprintln!("propnix-launcher: mkdir {}: {e}", d.display());
            return ExitCode::FAILURE;
        }
    }
    if settings.is_dxvk() {
        let _ = std::fs::create_dir_all(&paths.dxvk_cache);
        let _ = std::fs::create_dir_all(&paths.vkd3d_cache);
    }

    // Single-instance guard. The lock is held by this outer process (CLOEXEC → not inherited past here).
    let wm_class = Path::new(&cfg.exe)
        .file_stem()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let app_id = format!("org.propnix.{}", cfg.appid);
    let _lock = match focus::acquire(&paths.runtime) {
        Ok(focus::Lock::Acquired(f)) => f, // held until process exit
        Ok(focus::Lock::Busy) => {
            eprintln!("propnix: {} is already running", cfg.name);
            focus::raise_running(&wm_class, &cfg.name, &app_id);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("propnix-launcher: single-instance lock: {e}");
            return ExitCode::FAILURE;
        }
    };

    // The entire prefix (profile, drives, hives, saves, …) is the mount table — the launcher just resolves it
    // into a `Vec<Entry>` that the linked `propnix_mount` lays down (in the mount child's pre_exec). `user.reg`
    // is written by wine into the persistent root mount (`$PROPNIX_STATE/wine/prefix`, seeded once with the
    // game-agnostic base hive) and reconciled each launch by the three-way merge in userreg.rs.
    let entries = match mount::resolve_table(&cfg, &settings, &paths) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("propnix-launcher: mount table: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Per-game SETUP SCRIPT — the escape hatch for game-specific prefix setup (e.g. Skyrim seeding
    // SkyrimPrefs.ini `iSize` + a quality preset). Runs here in the OUTER, AFTER resolve_table (so
    // PROPNIX_SAVE_DIR/APPID are set and the save dir exists) and BEFORE the prefix is assembled/launched,
    // with the runtime env + `PROPNIX_PAYLOAD` (the game tree, for reading shipped assets). A NON-ZERO exit
    // ABORTS the launch: a setup failure is a packaging bug or a would-be-corrupted prefix, and must surface
    // rather than launch into a broken state.
    if let Some(script) = &cfg.setup_script {
        let mut cmd = Command::new(script);
        cmd.env("PROPNIX_PAYLOAD", &cfg.payload);
        match cmd.status() {
            Ok(s) if s.success() => {}
            Ok(s) => {
                eprintln!(
                    "propnix-launcher: setup script exited {} — aborting (packaging bug or corrupted prefix)",
                    run::code_of(s)
                );
                return ExitCode::FAILURE;
            }
            Err(e) => {
                eprintln!("propnix-launcher: cannot run setup script {script}: {e}");
                return ExitCode::FAILURE;
            }
        }
    }
    // Quiet GTK's Vulkan-ICD probe warnings (radv/anv fail on Asahi; cairo renderer is plenty).
    if std::env::var_os("GSK_RENDERER").is_none() {
        std::env::set_var("GSK_RENDERER", "cairo");
    }

    // MUST be single-threaded here — spawn_mounted's pre_exec assembles the prefix post-fork. Spawn the
    // splash/worker threads only AFTER it returns. (The module prefetch is NOT started here: the assembled
    // prefix lives in the child's private mount namespace, invisible from this process — the INNER warms it.)
    let (child, reader) = match run::spawn_mounted(
        &cfg.emulators.tar,
        &config_path,
        &paths.view,
        entries,
        args.unseal,
        &args.passthrough,
        cfg.online,
    ) {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("propnix-launcher: launch failed: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Now safe to go multithreaded.
    let (tx, rx) = mpsc::channel::<run::Progress>();
    let name = cfg.name.clone();
    let icon = cfg.icon.clone();

    // Compositor window watcher (run::watch_window): dismisses the splash when the game window MAPS (the
    // only signal for marker-less backends, e.g. an OpenGL title) and force-tears-down when it is DESTROYED
    // (a wine game can hang on shutdown after its window closes).
    {
        let tx = tx.clone();
        let needle = wm_class.clone();
        let title = cfg.name.clone();
        let splash_app_id = app_id.clone();
        std::thread::spawn(move || run::watch_window(tx, needle, title, splash_app_id));
    }

    let worker = std::thread::spawn(move || {
        run::watch_child(child, reader, &settings, tx);
    });
    let code = splash::run(app_id, name, icon, rx);
    let _ = worker.join();
    ExitCode::from((code & 0xff) as u8)
}

/// INNER phase (`--inside-ns`): propnix-mount has set up the WINEPREFIX bind view. Build the sealed env,
/// then stamp the registry + run wine.
fn run_inner(
    cfg: &config::Config,
    settings: &settings::Settings,
    paths: &settings::Paths,
    args: &Args,
) -> ExitCode {
    let child_env = env::ChildEnv::build(cfg, settings, paths);
    let code = run::run_inside_ns(cfg, settings, paths, &child_env, &args.passthrough);
    ExitCode::from((code & 0xff) as u8)
}
