//! SIGINT/SIGTERM → cancel, so the launcher tears down PREFIX-SCOPED on Ctrl-C or a kill (the plan's
//! "teardown on EXIT/INT/TERM"; winefex.nix did this with a bash trap). The handler only flips a lock-free
//! atomic (async-signal-safe); the worker's poll loop observes it, kills the game's process group, runs
//! `wineserver -k`, and reports Exited(130) so the GTK loop quits cleanly. The GTK splash's close_request
//! sets the same flag.

use std::sync::atomic::{AtomicBool, Ordering};

pub static CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn handle(_sig: libc::c_int) {
    // AtomicBool::store is async-signal-safe (lock-free); nothing else runs in the handler.
    CANCELLED.store(true, Ordering::SeqCst);
}

pub fn install() {
    unsafe {
        libc::signal(libc::SIGINT, handle as libc::sighandler_t);
        libc::signal(libc::SIGTERM, handle as libc::sighandler_t);
    }
}

pub fn cancelled() -> bool {
    CANCELLED.load(Ordering::SeqCst)
}

pub fn cancel() {
    CANCELLED.store(true, Ordering::SeqCst);
}
