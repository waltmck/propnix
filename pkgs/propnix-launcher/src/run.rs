//! Launch + lifecycle (winefex L262-287): spawn wine backgrounded in its OWN process group, drive the
//! splash close from DXVK's first-present marker on a PIPE (event-driven, no disk), watch for exit/cancel,
//! and tear down PREFIX-SCOPED on the way out.

use crate::config::Config;
use crate::env::ChildEnv;
use crate::settings::{Paths, Settings};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Worker → GTK progress events.
pub enum Progress {
    Presented,      // first frame is on screen → dismiss the splash
    Exited(i32),    // the game (and its prefix tree) is gone → quit with this code
    Failed(String), // could not even launch → report + quit(1)
}

/// Warm the wine lower's DLL closure in the background (posix_fadvise WILLNEED). No-op on a warm cache.
pub fn spawn_prefetch(cfg: &Config) {
    let _ = Command::new(&cfg.emulators.prefetch)
        .arg(&cfg.emulators.prefix_lower)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

pub fn code_of(status: ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}

/// Spawn wine backgrounded in its own process group, with stdout+stderr merged into a PIPE we read.
/// Returns the child and the pipe's read end (the launcher owns it; Command takes the write ends, so the
/// parent holds none — the reader sees EOF once the whole wine tree closes them). No file, no disk.
fn spawn_game(
    cfg: &Config,
    child_env: &ChildEnv,
    args: &[String],
) -> std::io::Result<(Child, std::io::PipeReader)> {
    let wine = format!("{}/bin/wine", cfg.emulators.wine);
    let mut cmd = Command::new(wine);
    cmd.arg(&cfg.exe).args(args).current_dir(&cfg.payload);
    child_env.apply(&mut cmd);

    // One pipe fed by both stdout and stderr (DXVK logs to stderr; Unity to stdout).
    let (reader, writer) = std::io::pipe()?;
    let writer2 = writer.try_clone()?;
    cmd.stdout(writer);
    cmd.stderr(writer2);

    // Own process group: an INT/TERM delivered to the launcher's group won't also hit the game directly
    // (we drive teardown ourselves), and we can signal the whole game tree as a group on cancel.
    cmd.process_group(0);
    let child = cmd.spawn()?;
    Ok((child, reader))
}

/// PREFIX-SCOPED reap — kills THIS prefix's whole wine tree (game + wineserver + services) and NOTHING
/// else. Never a global process-name kill (that would SIGKILL a concurrent wine app's wineserver, §7).
fn teardown(cfg: &Config, paths: &Paths) {
    let wineserver = format!("{}/bin/wineserver", cfg.emulators.wine);
    let _ = Command::new(wineserver)
        .arg("-k")
        .env("WINEPREFIX", &paths.prefix)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

pub fn run_worker(
    cfg: Arc<Config>,
    settings: Settings,
    paths: Paths,
    child_env: ChildEnv,
    args: Vec<String>,
    tx: Sender<Progress>,
) {
    // Wine HKCU setup while the splash is already up: the display-driver stamp (once/on change) + the
    // configured user.reg overrides (every launch — e.g. the black pre-render window background, so the
    // game's window doesn't flash white before its first frame).
    crate::graphics::apply(&cfg, &settings, &paths, &child_env);
    crate::graphics::apply_user_reg(&cfg, &child_env);

    let (mut child, reader) = match spawn_game(&cfg, &child_env, &args) {
        Ok(pair) => pair,
        Err(e) => {
            let _ = tx.send(Progress::Failed(format!("failed to launch wine: {e}")));
            return;
        }
    };
    let pgid = child.id() as i32; // == pgid (process_group(0))

    // Reader thread: drain the merged stdout/stderr pipe. Dismiss the splash the instant DXVK logs its
    // first-present marker (`Presenter:`) — event-driven, no polling, no disk. Forward the stream to the
    // terminal only in verbose (console) mode; otherwise drain silently so the child never blocks on a
    // full pipe. Ends at EOF once the whole wine tree has closed the pipe.
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
                            let _ = std::io::stderr().write_all(&line);
                        }
                        // First-present marker, ANY D3D backend (all ≈ first frame on screen):
                        //   * DXVK (D3D9/10/11)   → `Presenter:` at swapchain creation
                        //   * vkd3d-proton (D3D12) → `Creating swapchain`
                        //   * wined3d (OpenGL)     → `@ approx N.NNfps` (wine's fps channel; ~1s after the
                        //                            first present, enabled via WINEDEBUG=+fps on that backend)
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
    // Pure fallback: all three D3D backends now emit a first-present marker on the pipe (the reader thread
    // dismisses on it), so this only fires if a marker never arrives. Kept long so it can't dismiss the
    // splash prematurely during a slow cold start (Unity/Mono init + DXVK pipeline compile on a cold disk).
    let present_timeout = Duration::from_secs(180);

    loop {
        if crate::signals::cancelled() {
            unsafe {
                libc::kill(-pgid, libc::SIGTERM);
            }
            teardown(&cfg, &paths);
            let _ = tx.send(Progress::Exited(130));
            return;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                teardown(&cfg, &paths);
                let code = code_of(status);
                // Output was drained silently in quiet mode — tell the user how to see it on a bad exit.
                if code != 0 && !settings.console {
                    eprintln!(
                        "propnix: {} exited with code {code}; re-run with PROPNIX_BENCH=1 to see its output",
                        cfg.name
                    );
                }
                let _ = tx.send(Progress::Exited(code));
                return;
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("propnix: wait failed: {e}");
                teardown(&cfg, &paths);
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
