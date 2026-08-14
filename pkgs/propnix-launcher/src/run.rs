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

/// Warm the wine lower's DLL closure in the background (posix_fadvise WILLNEED). No-op on a warm cache.
/// Runs the linked `propnix_prefetch::warm` on a DETACHED thread so it overlaps the mount + wine cold start
/// (fire-and-forget; dies with the process). Must be called AFTER `spawn_mounted` — see its SAFETY note.
pub fn spawn_prefetch(cfg: &Config) {
    let lower = std::path::PathBuf::from(&cfg.emulators.prefix_lower);
    std::thread::spawn(move || propnix_prefetch::warm(&[lower]));
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
/// SAFETY: the `pre_exec` closure runs post-fork / pre-exec, so it (and the fs writes + mount syscalls in
/// `enter_and_mount`) is only safe if the CALLER is SINGLE-THREADED at this point. `run_outer` guarantees
/// that — it calls this BEFORE spawning the prefetch thread, the worker thread, or the GTK splash.
pub fn spawn_mounted(
    cfg: &Config,
    config_path: &str,
    view: &std::path::Path,
    entries: Vec<propnix_mount::Entry>,
    unseal: bool,
    passthrough: &[String],
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
    let tar = cfg.emulators.tar.clone();
    unsafe {
        cmd.pre_exec(move || {
            propnix_mount::enter_and_mount(&root, &entries, &tar)
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

    let wine = format!("{}/bin/wine", cfg.emulators.wine);
    let mut cmd = Command::new(&wine);
    // Baked per-game exe args (cfg.exe_args, e.g. a Unity title's `-screen-fullscreen 1`) come first, then
    // any runtime passthrough (`… -- <args>`) so a user can still add or override on the CLI.
    cmd.arg(&cfg.exe)
        .args(&cfg.exe_args)
        .args(passthrough)
        // cwd = the game's install dir inside the prefix (C:\game), where propnix-mount bound the payload.
        .current_dir(paths.view.join(crate::config::GAME_DIR));
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
