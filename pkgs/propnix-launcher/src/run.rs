//! Launch + lifecycle. Split across the mount namespace:
//!   * OUTER (no ns) — `spawn_mounted` re-execs this launcher as `--inside-ns` with a `pre_exec` hook that
//!     runs the linked `propnix_mount::enter_and_mount` (unshare the ns + lay the WINEPREFIX bind table) in
//!     the child first; `watch_child` drives the splash off the first-present marker and signals the child's
//!     group on cancel.
//!   * INNER (`--inside-ns`, prefix view live) — `run_inside_ns` stamps the registry, spawns wine in its
//!     own process group with inherited stdio (which reaches the outer's read pipe), waits, and tears down
//!     PREFIX-SCOPED (`wineserver -k`) on exit/cancel.

use crate::config::Config;
use crate::env::ChildEnv;
use crate::focus;
use crate::settings::{Paths, Settings};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

/// Worker → GTK progress events.
pub enum Progress {
    Presented,   // first frame is on screen → dismiss the splash
    Exited(i32), // the game (and its prefix tree) is gone → quit with this code
}

/// Warm the ASSEMBLED prefix's PE-module closure in the background (posix_fadvise WILLNEED). No-op on a warm
/// cache.
/// Runs the linked `propnix_prefetch::warm` on a DETACHED thread so it overlaps the registry stamp and wine's
/// own cold start (fire-and-forget; dies with the process).
///
/// INNER-ONLY, and hence WINE-ONLY: the prefix view exists solely inside the mount namespace propnix-mount
/// unshares in the mount child, so from the OUTER (which is not in that namespace) `paths.view` is an empty
/// directory — warming it there would find nothing. Running here, after the mount, covers the WHOLE prefix
/// in one walk: system32's wine builtins + FEX emulator DLLs + the DXVK/vkd3d and `extraSystem32` binds,
/// syswow64's i386 symlinks, AND the game's own bundled modules under `drive_c/game`. (THIN has no prefix
/// and no wine loader, so it never reaches this path.)
///
/// Restricted to the three PE-module extensions wine's loader MAPS at start-up, and nothing else:
///   * `dll` — the bulk of it (~1.3 k in the store system tree) plus the game's bundled libraries;
///   * `drv` — the display driver is `winewayland.drv` / `winex11.drv`, NOT a `.dll`, and every GUI title
///     binds one before its first window;
///   * `exe` — the game's own executable, plus the wine services wineboot starts alongside it
///     (services.exe, explorer.exe, winedevice.exe).
/// The restriction is what makes warming the full view affordable: a game's DATA (assets, packs, video) is
/// streamed by its engine on its own schedule, so warming it would only spend I/O bandwidth and ARC that the
/// modules need first.
fn spawn_prefetch(view: &std::path::Path) {
    let view = view.to_path_buf();
    let debug = std::env::var_os("PROPNIX_DEBUG").is_some();
    std::thread::spawn(move || {
        let started = Instant::now();
        let n = propnix_prefetch::warm(&[view], &["dll", "drv", "exe"]);
        // The only trace of an otherwise silent background job — and the one number that says whether it
        // found the assembled prefix at all (a count of 0 would mean we warmed an empty view).
        if debug {
            eprintln!("propnix: prefetched {n} PE modules in {:?}", started.elapsed());
        }
    });
}

pub fn code_of(status: ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

/// OUTER: run the game inside a fresh WINEPREFIX. We re-exec ourselves as `--inside-ns`, but with a
/// `pre_exec` hook that FIRST runs the linked `propnix_mount::enter_and_mount` in the child — it unshares a
/// private user+mount namespace and lays the bind table (`entries`, passed in-memory), so the re-exec'd inner
/// runs inside the assembled prefix. stdout+stderr merge into a PIPE we read; own process group so a cancel
/// can signal the whole tree at once.
///
/// `online = false` (the app declares itself offline) additionally unshares a NETWORK namespace in that
/// same child, so the game gets loopback and nothing else. Display/audio are unaffected — they are UNIX
/// sockets, which live in the mount namespace.
///
/// SAFETY: the `pre_exec` closure runs post-fork / pre-exec, so it (and the fs writes + mount syscalls in
/// `enter_and_mount`) is only safe if the CALLER is SINGLE-THREADED at this point. `run_outer` guarantees
/// that — it calls this BEFORE spawning the worker thread or the GTK splash.
pub fn spawn_mounted(
    tar: &str,
    config_path: &str,
    view: &std::path::Path,
    entries: Vec<propnix_mount::Entry>,
    unseal: bool,
    passthrough: &[String],
    online: bool,
) -> std::io::Result<(Child, std::io::PipeReader)> {
    let me = std::env::current_exe()?;
    let mut cmd = Command::new(&me);
    cmd.arg("--inside-ns").arg("--view").arg(view).arg("--config").arg(config_path);
    if unseal {
        cmd.arg("--propnix-unseal");
    }
    if !passthrough.is_empty() {
        cmd.arg("--").args(passthrough);
    }
    let (reader, writer) = std::io::pipe()?;
    let writer2 = writer.try_clone()?;
    cmd.stdout(writer);
    cmd.stderr(writer2);
    cmd.process_group(0);

    // Assemble the prefix in the child (post-fork, pre-exec): unshare the ns + lay the mount table, then the
    // Command execs the inner launcher into it. An assembly failure aborts the spawn (surfaced to the parent).
    let root = view.to_string_lossy().into_owned();
    let tar = tar.to_string();
    unsafe {
        cmd.pre_exec(move || {
            propnix_mount::enter_and_mount(&root, &entries, &tar, !online)
                .map_err(|e| std::io::Error::other(format!("prefix assembly: {e}")))
        });
    }
    let child = cmd.spawn()?;
    Ok((child, reader))
}

/// OUTER: watch the mounted child. Dismiss the splash on the first-present marker (any D3D backend), wait
/// for exit, and SIGTERM the child's group on cancel — the INNER does the prefix-scoped `wineserver -k`.
pub fn watch_child(
    mut child: Child,
    reader: std::io::PipeReader,
    settings: &Settings,
    tx: Sender<Progress>,
) {
    let pgid = child.id() as i32; // == pgid (process_group(0))

    {
        let tx = tx.clone();
        let verbose = settings.console;
        std::thread::spawn(move || {
            let mut buf = BufReader::new(reader);
            let mut line: Vec<u8> = Vec::new();
            let mut announced = false;
            loop {
                line.clear();
                match buf.read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if verbose {
                            let mut out = std::io::stdout();
                            let _ = out.write_all(&line);
                            let _ = out.flush();
                        }
                        // First-present marker, ANY backend (all ≈ first frame on screen):
                        //   DXVK → `Presenter:`; vkd3d → `Creating swapchain`; wined3d → `@ approx N.NNfps`.
                        if !announced {
                            let s = String::from_utf8_lossy(&line);
                            if s.contains("Presenter:")
                                || s.contains("Creating swapchain")
                                || s.contains("@ approx")
                            {
                                announced = true;
                                let _ = tx.send(Progress::Presented);
                            }
                        }
                    }
                }
            }
        });
    }

    let start = Instant::now();
    let mut timed_out = false;
    // Pure fallback if a marker never arrives (kept long so it can't dismiss the splash during a slow cold
    // start). The inner drives real teardown; here we only signal the child's group on cancel.
    let present_timeout = Duration::from_secs(180);
    loop {
        if crate::signals::cancelled() {
            unsafe {
                libc::kill(-pgid, libc::SIGTERM);
            }
            let _ = child.wait();
            let _ = tx.send(Progress::Exited(130));
            return;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let code = code_of(status);
                if code != 0 && !settings.console {
                    eprintln!(
                        "propnix: exited with code {code}; re-run with PROPNIX_DEBUG=1 to see its output"
                    );
                }
                let _ = tx.send(Progress::Exited(code));
                return;
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("propnix: wait failed: {e}");
                let _ = tx.send(Progress::Exited(1));
                return;
            }
        }
        if !timed_out && start.elapsed() > present_timeout {
            timed_out = true;
            let _ = tx.send(Progress::Presented);
        }
        std::thread::sleep(Duration::from_millis(120));
    }
}

/// Compositor window-watcher (best-effort; needs a toplevel-list protocol — wlr-foreign-toplevel-management,
/// present on wlroots compositors like Hyprland/sway). Spawned on a thread by both outer paths (wine in
/// main.rs, THIN in thin.rs); one probe of the game's toplevel drives two jobs:
///   1. Splash dismiss — some backends emit NO first-present stderr marker for `watch_child` to scan
///      (OpenGL wine titles like Prison Architect, and every THIN native/box64 game), so dismiss the splash
///      once the game window MAPS. Complements the marker scan (whichever fires first); a marker backend
///      normally wins, so this never uncovers a still-black D3D window early.
///   2. Close-to-quit — once the window has appeared, watch for it to be DESTROYED (gone from the
///      compositor's toplevel list; minimized/unfocused windows still appear, so absence means closed) and
///      force teardown. Needed because a wine game can HANG on shutdown (stuck on ntsync) after its window
///      closes, so the inner's wait-on-process never returns and the launcher tree lingers.
///      `signals::cancel()` drives the existing teardown path (wine: SIGTERM-the-tree + prefix-scoped
///      `wineserver -k`; THIN: the process-group kill), which reaps the hung game.
/// On a compositor lacking the protocol (or no display) the probe returns NoManager and the watcher stops:
/// the splash then relies on the fallback timeout, and the game must exit on its own.
pub fn watch_window(tx: Sender<Progress>, needle: String, title: String, splash_app_id: String) {
    let step = Duration::from_millis(400);
    // Phase 1: wait for the game window to appear → dismiss the splash.
    let mut appeared = false;
    for _ in 0..430u32 {
        // ~175 s, under watch_child's 180 s fallback
        if crate::signals::cancelled() {
            return;
        }
        match focus::game_window_probe(&needle, &title, &splash_app_id) {
            focus::Probe::NoManager => return, // signal unavailable here — fallback timeout owns the splash
            focus::Probe::Found => {
                std::thread::sleep(Duration::from_millis(750)); // let the first frame paint
                let _ = tx.send(Progress::Presented);
                appeared = true;
                break;
            }
            focus::Probe::NotFound => std::thread::sleep(step),
        }
    }
    if !appeared {
        return;
    }
    // Phase 2: the window is up — watch for it to be destroyed (user closed it) → force teardown.
    // Require several consecutive absences (~3 s) so a transient probe glitch, or a toplevel that a
    // fullscreen toggle briefly destroys and re-creates, doesn't trigger a false quit.
    let mut gone = 0u32;
    loop {
        std::thread::sleep(step);
        if crate::signals::cancelled() {
            return; // teardown already under way (normal exit or Ctrl-C)
        }
        match focus::game_window_probe(&needle, &title, &splash_app_id) {
            focus::Probe::Found => gone = 0,
            focus::Probe::NotFound => {
                gone += 1;
                if gone >= 8 {
                    // ~3.2 s with no game window → it was closed; tear the launcher down.
                    crate::signals::cancel();
                    return;
                }
            }
            focus::Probe::NoManager => return, // lost the signal — don't force-quit on uncertainty
        }
    }
}

/// PREFIX-SCOPED reap — kills THIS prefix's whole wine tree (game + wineserver + services) and NOTHING
/// else. Never a global process-name kill.
fn teardown(cfg: &Config, paths: &Paths) {
    let wineserver = format!("{}/bin/wineserver", cfg.emulators.wine);
    let _ = Command::new(wineserver)
        .arg("-k")
        .env("WINEPREFIX", &paths.view)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// INNER (`--inside-ns`): the WINEPREFIX bind view is live. Stamp the display driver + HKCU overrides,
/// spawn wine (own process group, INHERITED stdio → the outer's pipe via propnix-mount), wait, and tear
/// down prefix-scoped on exit/cancel. Returns the game's exit code.
pub fn run_inside_ns(
    cfg: &Config,
    settings: &Settings,
    paths: &Paths,
    child_env: &ChildEnv,
    passthrough: &[String],
) -> i32 {
    // Wine HKCU setup while the splash is already up (out in the outer): display-driver stamp + the
    // configured user.reg / fpsUserReg / userRegScript overrides (three-way merge). All need the live prefix
    // view — hence here, inside the namespace. Only a failing `userRegScript` returns Err (a packaging bug);
    // abort before launching wine (the outer sees the non-zero inner exit and tears the view down).
    if let Err(e) = crate::graphics::apply(cfg, settings, paths, child_env) {
        eprintln!("propnix: registry setup failed: {e}");
        return 1;
    }

    // Steam-emulated build: seat the stored Steam account's SteamID64 into the gbe_fork shim's global
    // settings, at the path CSIDL_APPDATA resolves to for wine's fixed user. Needs the live view (hence
    // inner), and MERGES: drive_c/users is the PERSISTENT users overlay, where the shim saves keys of
    // its own. Best-effort by design — a launch never fails over identity (see steamid.rs).
    if cfg.steam_emu {
        if let Some((_, id)) = crate::steamid::resolve() {
            let dir = paths
                .view
                .join(crate::steamid::WINE_APPDATA)
                .join("GSE Saves")
                .join("settings");
            if let Err(e) = crate::steamid::seat(&dir, id) {
                eprintln!("propnix: could not seat the Steam identity ({e}) — the emu will make one up");
            }
        }
    }

    // Warm the assembled prefix's PE-module closure (detached; see `spawn_prefetch`). The view is live from the
    // moment we start — propnix-mount laid it before re-exec'ing us — but this must come AFTER
    // `graphics::apply`, which mutates the PROCESS env (`set_var`): `warm` reads its own env knobs, and a
    // concurrent setenv/getenv is a data race. Here is the last point that still overlaps wine's cold start,
    // which is the window that matters. `PROPNIX_NO_PREFETCH` is inherited from the outer, so the opt-out
    // holds in this phase too.
    if !settings.no_prefetch {
        spawn_prefetch(&paths.view);
    }

    let wine = format!("{}/bin/wine", cfg.emulators.wine);
    let mut cmd = Command::new(&wine);
    // Baked per-game exe args (cfg.exe_args, e.g. a Unity title's `-screen-fullscreen 1`) come first, then
    // any runtime passthrough (`… -- <args>`) so a user can still add or override on the CLI.
    // cwd + exe. Default (workingDir null): cwd = the game's install dir (C:\game) and the exe is passed as
    // the bare path relative to it — BYTE-IDENTICAL to the historical launch, so no existing game changes.
    // With workingDir set: cwd = that subdirectory (for an engine that resolves its data root from the CWD,
    // not the exe path — e.g. Don't Starve → cwd = C:\game\bin, data at ..\data), and the exe is passed as
    // its full path within the view (still relative to C:\game) so it resolves regardless of the CWD; wine
    // maps that view path back onto the C: drive, so the module path stays C:\game\... .
    let game_dir = paths.view.join(crate::config::GAME_DIR);
    match &cfg.working_dir {
        Some(rel) => {
            cmd.arg(game_dir.join(&cfg.exe))
                .args(&cfg.exe_args)
                .args(passthrough)
                .current_dir(game_dir.join(rel));
        }
        None => {
            cmd.arg(&cfg.exe)
                .args(&cfg.exe_args)
                .args(passthrough)
                .current_dir(&game_dir);
        }
    }
    child_env.apply(&mut cmd);
    // Inherit stdio: our stdout/stderr are propnix-mount's, which are the outer launcher's read pipe.
    cmd.process_group(0);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("propnix: failed to launch wine: {e}");
            return 1;
        }
    };
    let pgid = child.id() as i32;

    loop {
        if crate::signals::cancelled() {
            unsafe {
                libc::kill(-pgid, libc::SIGTERM);
            }
            teardown(cfg, paths);
            return 130;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                teardown(cfg, paths);
                return code_of(status);
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("propnix: wait failed: {e}");
                teardown(cfg, paths);
                return 1;
            }
        }
        std::thread::sleep(Duration::from_millis(120));
    }
}
