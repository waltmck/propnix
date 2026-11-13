//! Single-instance guard + raise-the-running-game (§5.1 / §5).
//!
//! The lock is an flock on `$XDG_RUNTIME_DIR/propnix/<appid>/lock`, held by the OUTER launcher. Rust opens
//! files O_CLOEXEC by default, so the lock fd is NOT inherited into the game — the lock tracks the launcher's
//! lifetime exactly (§5.1). A duplicate launch finds it busy, asks the running launcher to focus its window,
//! and exits 0.
//!
//! Focus goes through xdg-activation, the one portable way to have any compositor focus a window: whoever
//! wants a window focused holds an activation token — a launch from a desktop carries one in
//! `XDG_ACTIVATION_TOKEN` (the game's `.desktop` entry declares StartupNotify) — and the window's OWN client
//! presents it. So a duplicate launch never touches the window: it hands its token to the running launcher
//! over `<runtime>/activate` (`raise_running` → `serve`), which passes it to whichever window it is showing —
//! the GTK splash, which GTK activates with it, or the game, whose gamescope activates its own window
//! (gamescope.rs `activate`). A launch from a shell has no token; gamescope then asks for one stamped with its
//! own last input, and the compositor decides what that earns — focus, or only an urgency hint (GNOME's
//! "is ready" notification; Hyprland focuses on activation only with `misc:focus_on_activate`).

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub enum Lock {
    Acquired(File), // keep this alive for the whole process — dropping it releases the lock
    Busy,
}

pub fn acquire(runtime_dir: &Path) -> std::io::Result<Lock> {
    std::fs::create_dir_all(runtime_dir)?;
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(runtime_dir.join("lock"))?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        Ok(Lock::Acquired(file))
    } else {
        let err = std::io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EWOULDBLOCK) => Ok(Lock::Busy),
            _ => Err(err),
        }
    }
}

/// Where the running launcher takes activation requests (in its runtime dir, so per app).
fn socket_path(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join("activate")
}

/// DUPLICATE launch: hand this launch's activation token (empty when it has none) to the running launcher.
/// Best-effort — no listener, or a stale socket from a crashed launch, is silently a no-op: a nicety, never
/// a launch blocker.
pub fn raise_running(runtime_dir: &Path) {
    let token = std::env::var("XDG_ACTIVATION_TOKEN").unwrap_or_default();
    if let Ok(mut stream) = UnixStream::connect(socket_path(runtime_dir)) {
        let _ = stream.write_all(token.as_bytes());
    }
}

/// RUNNING launcher: bind the activation socket. Holding the single-instance lock makes this launcher the
/// only one for the app, so a socket file already there is a crashed launch's and is replaced. Bind before
/// spawning anything (the fd is CLOEXEC, so the game never inherits it); serve it with `serve`.
pub fn listen(runtime_dir: &Path) -> std::io::Result<UnixListener> {
    let path = socket_path(runtime_dir);
    let _ = std::fs::remove_file(&path);
    UnixListener::bind(path)
}

/// RUNNING launcher: on a thread, hand every request's token (empty = none) to `on_request`.
pub fn serve(listener: UnixListener, on_request: impl Fn(String) + Send + 'static) {
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            let mut token = String::new();
            match stream.read_to_string(&mut token) {
                Ok(_) => on_request(token.trim().to_string()),
                Err(e) => {
                    if std::env::var_os("PROPNIX_DEBUG").is_some() {
                        eprintln!("propnix: focus request unreadable: {e}");
                    }
                }
            }
        }
    });
}
