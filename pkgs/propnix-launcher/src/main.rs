//! propnix-launcher — the per-app launcher for the winefex backend. Ports winefex.nix stage-for-stage:
//! load the baked config → layer PROPNIX_* overrides → single-instance guard → assemble the symlink-farm
//! prefix → bind saves → seal the env → show a GTK splash while wine cold-starts → tear down prefix-scoped
//! on exit. Nix computes the intended state (the config); this program enforces it.

mod config;
mod env;
mod focus;
mod graphics;
mod prefix;
mod run;
mod save;
mod settings;
mod signals;
mod splash;
mod util;

use std::path::Path;
use std::process::{Command, ExitCode, Stdio};
use std::sync::mpsc;
use std::sync::Arc;

struct Args {
    config: Option<String>,
    unseal: bool, // --propnix-unseal: skip the env scrub (debug)
    shell: bool,  // --shell: sealed interactive shell in the prefix instead of launching (debug)
    passthrough: Vec<String>, // extra args handed to the game exe
}

fn parse_args(argv: &[String]) -> Args {
    let mut a = Args {
        config: None,
        unseal: false,
        shell: false,
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
            "--shell" => a.shell = true,
            _ if s.starts_with("--config=") => {
                a.config = Some(s["--config=".len()..].to_string())
            }
            _ => a.passthrough.push(argv[i].clone()),
        }
        i += 1;
    }
    a
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let args = parse_args(&argv);

    let config_path = match args.config {
        Some(p) => p,
        None => {
            eprintln!("propnix-launcher: --config <path> is required");
            return ExitCode::from(2);
        }
    };

    let cfg = match config::Config::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix-launcher: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Teardown on Ctrl-C / kill (the worker observes the flag): plan §5 "EXIT/INT/TERM".
    signals::install();

    let settings = settings::Settings::resolve(&cfg, args.unseal, args.shell);
    let paths = settings.paths();

    for d in [&paths.state, &paths.cache, &paths.runtime, &paths.prefix] {
        if let Err(e) = std::fs::create_dir_all(d) {
            eprintln!("propnix-launcher: mkdir {}: {e}", d.display());
            return ExitCode::FAILURE;
        }
    }
    if settings.is_dxvk() {
        let _ = std::fs::create_dir_all(&paths.dxvk_cache);
        let _ = std::fs::create_dir_all(&paths.vkd3d_cache);
    }

    // Single-instance guard. The lock is held by this outer process (CLOEXEC → not inherited into wine).
    let wm_class = Path::new(&cfg.exe)
        .file_stem()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let _lock = match focus::acquire(&paths.runtime) {
        Ok(focus::Lock::Acquired(f)) => f, // held until process exit
        Ok(focus::Lock::Busy) => {
            eprintln!("propnix: {} is already running", cfg.name);
            focus::raise_running(&wm_class, &cfg.name);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("propnix-launcher: single-instance lock: {e}");
            return ExitCode::FAILURE;
        }
    };

    // Warm the DLL closure as early as possible (background; no-op on a warm cache).
    if !settings.no_prefetch {
        run::spawn_prefetch(&cfg);
    }

    // Assemble the symlink-farm prefix.
    if let Err(e) = prefix::assemble(&cfg, &settings, &paths) {
        eprintln!("propnix-launcher: prefix assembly failed: {e}");
        return ExitCode::FAILURE;
    }

    // Bind saves/data out of the prefix (§6.1: create the save dir or refuse to launch).
    if let Err(e) = save::apply(&cfg, &settings, &paths) {
        eprintln!("propnix-launcher: {e}");
        return ExitCode::FAILURE;
    }

    let child_env = env::ChildEnv::build(&cfg, &settings, &paths);

    // --shell escape hatch: a sealed interactive shell in the payload dir, no game, no splash.
    if settings.shell {
        return run_shell(&cfg, &paths, &child_env);
    }

    // Quiet GTK's Vulkan-ICD probe warnings (radv/anv fail on Asahi; GTK falls back anyway). The splash is
    // trivial, so the cairo renderer is plenty and probes nothing. Respect a user override.
    if std::env::var_os("GSK_RENDERER").is_none() {
        std::env::set_var("GSK_RENDERER", "cairo");
    }

    // GUI splash + worker thread doing graphics-stamp → spawn → watch → teardown.
    let (tx, rx) = mpsc::channel::<run::Progress>();
    let cfg = Arc::new(cfg);
    let name = cfg.name.clone();
    let icon = cfg.icon.clone();

    let worker = {
        let cfg = cfg.clone();
        let passthrough = args.passthrough;
        std::thread::spawn(move || {
            run::run_worker(cfg, settings, paths, child_env, passthrough, tx);
        })
    };

    let code = splash::run(name, icon, rx);
    let _ = worker.join();
    ExitCode::from((code & 0xff) as u8)
}

fn run_shell(cfg: &config::Config, paths: &settings::Paths, child_env: &env::ChildEnv) -> ExitCode {
    eprintln!(
        "propnix: sealed shell in {} (WINEPREFIX={})",
        cfg.payload,
        paths.prefix.display()
    );
    let mut cmd = Command::new("bash");
    cmd.arg("-i")
        .current_dir(&cfg.payload)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    child_env.apply(&mut cmd);
    // Put wine on PATH for convenience in the debug shell.
    let path = std::env::var("PATH").unwrap_or_default();
    cmd.env("PATH", format!("{}/bin:{}", cfg.emulators.wine, path));
    match cmd.status() {
        Ok(s) => ExitCode::from((run::code_of(s) & 0xff) as u8),
        Err(e) => {
            eprintln!("propnix-launcher: shell: {e}");
            ExitCode::FAILURE
        }
    }
}
