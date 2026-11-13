//! Launch + lifecycle. Split across the mount namespace:
//!   * OUTER (no ns) — `spawn_mounted` starts gamescope (gamescope.rs) with this launcher re-exec'd as
//!     `--inside-ns` as its child, behind a `pre_exec` hook that runs the linked
//!     `propnix_mount::enter_and_mount` (unshare the ns + lay the WINEPREFIX bind table) first, so gamescope
//!     and everything under it share the namespace; `watch_child` drives the splash off the first-present
//!     marker, signals the group on cancel, and reports the inner's exit code; `watch_window` watches the
//!     game window through gamescope's nested X server.
//!   * INNER (`--inside-ns`, prefix view live) — `run_inside_ns` stamps the registry, spawns wine in its
//!     own process group with inherited stdio (which reaches the outer's read pipe), waits, and tears down
//!     PREFIX-SCOPED (`wineserver -k`) on exit/cancel.

use crate::config::Config;
use crate::env::ChildEnv;
use crate::settings::{Paths, Settings};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::Sender;
use std::time::{Duration, Instant};

/// Worker → GTK progress events.
pub enum Progress {
    Presented,        // first frame is on screen → dismiss the splash
    Exited(i32),      // the game (and its prefix tree) is gone → quit with this code
    Activate(String), // a duplicate launch wants us focused, with its activation token (empty = none; focus.rs)
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

/// INNER: report the exit code to the outer through the status file (`--status`, gamescope::Session).
/// gamescope always exits 0 (it discards its child's status), so this file is how the outer learns the
/// game's code — a file of its own, never the output pipe the game also writes to. Written to a temporary
/// name and renamed, so the outer never reads a partial value. main() calls this on every way out of the
/// inner.
pub fn report_exit(status: &std::path::Path, code: i32) {
    let tmp = status.with_extension("tmp");
    if std::fs::write(&tmp, code.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, status);
    }
}

/// OUTER: the inner's reported exit code, once it has reported (`report_exit`).
fn reported_exit(status: &std::path::Path) -> Option<i32> {
    std::fs::read_to_string(status).ok()?.trim().parse().ok()
}

/// OUTER: run the game inside a fresh WINEPREFIX, under gamescope. `gamescope` is its command line
/// (gamescope.rs); we append `-- <this launcher> --inside-ns …`, so gamescope runs the re-exec'd inner as its
/// child. A `pre_exec` hook FIRST runs the linked `propnix_mount::enter_and_mount` in the spawned child — it
/// unshares a private user+mount namespace and lays the bind table (`entries`, passed in-memory) — so
/// gamescope, the inner and the game all run inside the assembled prefix. The inner reports its exit code
/// to `status` (`report_exit`). stdout+stderr merge into a PIPE
/// we read (gamescope closes every other fd for its children, but passes 0/1/2 through); own process group,
/// which gamescope's reaper and the inner share, so a cancel signals the whole tree at once. `x11_dir` is
/// bound over `/tmp/.X11-unix` in the same namespace (gamescope::Session says why).
///
/// `online = false` (the app declares itself offline) additionally unshares a NETWORK namespace in that
/// same child, so the game gets loopback and nothing else. Display/audio are unaffected — they are UNIX
/// sockets, which live in the mount namespace.
///
/// SAFETY: the `pre_exec` closure runs post-fork / pre-exec, so it (and the fs writes + mount syscalls in
/// `enter_and_mount`) is only safe if the CALLER is SINGLE-THREADED at this point. `run_outer` guarantees
/// that — it calls this BEFORE spawning the worker thread or the GTK splash.
pub fn spawn_mounted(
    gamescope: Command,
    x11_dir: &std::path::Path,
    status: &std::path::Path,
    tar: &str,
    config_path: &str,
    view: &std::path::Path,
    entries: Vec<propnix_mount::Entry>,
    unseal: bool,
    passthrough: &[String],
    online: bool,
) -> std::io::Result<(Child, std::io::PipeReader)> {
    let me = std::env::current_exe()?;
    let mut cmd = gamescope;
    cmd.arg("--").arg(&me);
    cmd.arg("--inside-ns").arg("--view").arg(view).arg("--config").arg(config_path);
    cmd.arg("--status").arg(status);
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
    let x11_dir = x11_dir.to_string_lossy().into_owned();
    // A host without the directory has no X server to hide; gamescope then creates it, owned by us.
    let bind_x11 = std::path::Path::new(crate::gamescope::X11_SOCKET_DIR).is_dir();
    unsafe {
        cmd.pre_exec(move || {
            propnix_mount::enter_and_mount(&root, &entries, &tar, !online)
                .map_err(|e| std::io::Error::other(format!("prefix assembly: {e}")))?;
            if bind_x11 {
                propnix_mount::bind_over(&x11_dir, crate::gamescope::X11_SOCKET_DIR)
                    .map_err(|e| std::io::Error::other(format!("X socket dir: {e}")))?;
            }
            Ok(())
        });
    }
    let child = cmd.spawn()?;
    Ok((child, reader))
}

/// OUTER: watch the mounted child (gamescope). Dismiss the splash on the first-present marker (any D3D
/// backend), wait for exit, and stop the tree on cancel (`stop`) — the INNER does the prefix-scoped
/// `wineserver -k`. The reported code is the inner's (`report_exit` → `status`), not gamescope's.
pub fn watch_child(
    mut child: Child,
    reader: std::io::PipeReader,
    status: PathBuf,
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
    let mut reported_at: Option<Instant> = None;
    loop {
        // The inner has finished (and done its prefix-scoped teardown) but gamescope is still up: what holds
        // it is a leftover helper (see `stop`). Healthy, gamescope follows the inner out within a second.
        if reported_at.is_none() && reported_exit(&status).is_some() {
            reported_at = Some(Instant::now());
        }
        let lingering = reported_at.is_some_and(|t| t.elapsed() > Duration::from_secs(5));
        if crate::signals::cancelled() || lingering {
            if lingering {
                kill_tree(child.id() as i32);
                let _ = child.wait();
            } else {
                stop(&mut child, pgid);
            }
            drain_group(pgid);
            let _ = tx.send(Progress::Exited(reported_exit(&status).unwrap_or(130)));
            return;
        }
        match child.try_wait() {
            Ok(Some(exit)) => {
                drain_group(pgid);
                let code = match (reported_exit(&status), code_of(exit)) {
                    (Some(code), _) => code,
                    // No report: gamescope failed before starting the inner (its own code says how), or the
                    // inner died without a chance to report (killed) — never a success.
                    (None, 0) => {
                        eprintln!("propnix: the game ended without reporting an exit status");
                        1
                    }
                    (None, gamescope_code) => gamescope_code,
                };
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

/// OUTER: stop gamescope and everything under it. SIGTERM the group — gamescope shuts down and SIGTERMs its
/// own tree, and the inner tears the prefix down — then, if gamescope has not exited within ~10 s, SIGKILL
/// every process still under it. gamescope's reaper is a SUBREAPER that waits for every descendant, so a
/// single helper that outlives the teardown (a wine service stuck in the kernel on ntsync, in a process
/// group of its own) would otherwise hold the reaper, gamescope and this launcher forever.
fn stop(child: &mut Child, pgid: i32) {
    unsafe {
        libc::kill(-pgid, libc::SIGTERM);
    }
    for _ in 0..100 {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    kill_tree(child.id() as i32);
    let _ = child.wait();
}

/// SIGKILL `root` and every process descended from it, found by parent links in /proc. Orphans of the game
/// tree are re-parented to gamescope's reaper (a subreaper), so they are found here too.
fn kill_tree(root: i32) {
    let mut links: Vec<(i32, i32)> = Vec::new(); // (pid, ppid)
    for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        // `pid (comm) state ppid …` — comm may hold spaces and parens, so parse after the LAST ')'.
        let ppid = std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|s| s.rsplit_once(')').and_then(|(_, rest)| rest.split_whitespace().nth(1)?.parse().ok()));
        if let Some(ppid) = ppid {
            links.push((pid, ppid));
        }
    }
    let mut tree = vec![root];
    let mut i = 0;
    while i < tree.len() {
        let parent = tree[i];
        for &(pid, ppid) in &links {
            if ppid == parent && !tree.contains(&pid) {
                tree.push(pid);
            }
        }
        i += 1;
    }
    for pid in tree {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
}

/// OUTER: after gamescope has exited, wait for the rest of its process group — the inner, still running its
/// teardown (`wineserver -k`, the THIN group kill) — so the launcher, and with it the single-instance lock,
/// outlives the game's processes. A member still there after the grace period is SIGKILLed.
fn drain_group(pgid: i32) {
    for _ in 0..100 {
        // ~10 s
        if unsafe { libc::kill(-pgid, 0) } != 0 {
            return; // ESRCH: the group is empty
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    unsafe {
        libc::kill(-pgid, libc::SIGKILL);
    }
}

/// Game-window watcher, through gamescope's NESTED X server (whose DISPLAY gamescope writes to the ready
/// file — gamescope.rs). gamescope publishes the window it is showing as `GAMESCOPE_FOCUSED_WINDOW` on that
/// server's root, and maps its host toplevel exactly while one exists — so the watcher needs nothing from
/// the host compositor and works on every desktop (GNOME included). Spawned on a thread by both outer paths
/// (wine in main.rs, THIN in thin.rs); it drives two jobs:
///   1. Splash dismiss — some backends emit NO first-present stderr marker for `watch_child` to scan
///      (OpenGL wine titles like Prison Architect, and every THIN native/box64 game), so dismiss the splash
///      once gamescope has a game window to show. Complements the marker scan (whichever fires first); a
///      marker backend normally wins, so this never uncovers a still-black D3D window early.
///   2. Close-to-quit for a game that HANGS on shutdown (stuck on ntsync) after its window closes: the
///      inner's wait-on-process never returns, and gamescope — which only unmaps its host window when the
///      game has none — never exits either. Once a window has appeared, its absence for ~3 s drives
///      `signals::cancel()`, the existing teardown path (wine: SIGTERM-the-tree + prefix-scoped
///      `wineserver -k`; THIN: the process-group kill), which reaps the hung game. (Closing gamescope's own
///      window needs no watcher: gamescope shuts down and SIGTERMs its tree itself.)
/// A lost connection means gamescope is gone; `watch_child` owns that exit, so the watcher just stops.
pub fn watch_window(tx: Sender<Progress>, ready: PathBuf, x11_dir: PathBuf) {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};

    // gamescope writes its DISPLAY before it spawns the inner; ~175 s, under watch_child's 180 s fallback.
    let deadline = Instant::now() + Duration::from_secs(175);
    loop {
        if crate::signals::cancelled() || Instant::now() > deadline {
            return;
        }
        if crate::gamescope::nested_socket(&ready, &x11_dir).is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let Some(conn) = crate::gamescope::connect_nested(&ready, &x11_dir) else {
        return;
    };
    let root = conn.setup().roots[0].root;
    let Ok(focused_window) = conn
        .intern_atom(false, b"GAMESCOPE_FOCUSED_WINDOW")
        .map_err(x11rb::errors::ReplyError::from)
        .and_then(|c| c.reply())
        .map(|r| r.atom)
    else {
        return;
    };
    // Some(true) = gamescope is showing a game window; None = the connection is gone (gamescope exited).
    let showing = || -> Option<bool> {
        let reply = conn
            .get_property(false, root, focused_window, AtomEnum::CARDINAL, 0, 1)
            .ok()?
            .reply()
            .ok()?;
        Some(reply.value32().and_then(|mut v| v.next()).is_some_and(|w| w != 0))
    };

    let step = Duration::from_millis(400);
    // Phase 1: wait for a game window → dismiss the splash.
    loop {
        if crate::signals::cancelled() || Instant::now() > deadline {
            return;
        }
        match showing() {
            None => return,
            Some(true) => {
                std::thread::sleep(Duration::from_millis(750)); // let the first frame paint
                let _ = tx.send(Progress::Presented);
                break;
            }
            Some(false) => std::thread::sleep(step),
        }
    }
    // Phase 2: watch for the game's windows to go away for good → force teardown. Several consecutive
    // absences (~3 s), so a game swapping one window for another (a launcher window for the main one, a
    // fullscreen re-create) does not read as a close.
    let mut gone = 0u32;
    loop {
        std::thread::sleep(step);
        if crate::signals::cancelled() {
            return; // teardown already under way (normal exit or Ctrl-C)
        }
        match showing() {
            None => return,
            Some(true) => gone = 0,
            Some(false) => {
                gone += 1;
                if gone >= 8 {
                    crate::signals::cancel();
                    return;
                }
            }
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

    // Steam-emulated build (cfg.steam_emu): gbe_fork generates its own identity and saves it under
    // drive_c/users — the PERSISTENT users overlay — so on wine it is stable across launches with no help
    // from us. The launcher does not seat a stored SteamID64 here: that would read the credential store as
    // the launching human, which the group-ownership contract does not permit on declarative/shared hosts.

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_status_round_trips_through_the_status_file() {
        let dir = std::env::temp_dir().join(format!("propnix-status-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let status = dir.join("status-1");
        assert_eq!(reported_exit(&status), None); // not reported yet
        report_exit(&status, 7);
        assert_eq!(reported_exit(&status), Some(7));
        assert!(!status.with_extension("tmp").exists()); // renamed into place, no partial file left
        let _ = std::fs::remove_dir_all(&dir);
    }
}
