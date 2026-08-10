//! Single-instance guard + best-effort raise-the-running-window (§5.1 / §5).
//!
//! The lock is an flock on `$XDG_RUNTIME_DIR/propnix/<appid>/lock`, held by the OUTER launcher. Rust opens
//! files O_CLOEXEC by default, so the lock fd is NOT inherited into the wine child — the lock tracks the
//! launcher's lifetime exactly (§5.1). A duplicate launch finds it busy, tries to raise the already-running
//! game window, and exits 0.
//!
//! Raising another client's window is deliberately restricted, so we try two portable paths, best-effort:
//!   * X11 / Xwayland — EWMH `_NET_ACTIVE_WINDOW`, matched by WM_CLASS.
//!   * Wayland — `wlr-foreign-toplevel-management`, matched by app_id/title. This is the widely-implemented
//!     cross-compositor protocol WITH an `activate` verb (wlroots family: Hyprland/sway/Wayfire/…, plus
//!     COSMIC). It's what lets the launcher raise a window it doesn't own WITHOUT wine's cooperation
//!     (wine has no xdg-activation). A graceful no-op where the compositor doesn't advertise it (GNOME,
//!     KDE — KDE uses its own plasma-window-management), and where there is no display at all.

use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::path::Path;

use wayland_client::protocol::{
    wl_registry::{self, WlRegistry},
    wl_seat::WlSeat,
};
use wayland_client::{event_created_child, Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::foreign_toplevel::v1::client::{
    zwlr_foreign_toplevel_handle_v1::{self, ZwlrForeignToplevelHandleV1},
    zwlr_foreign_toplevel_manager_v1::{self, ZwlrForeignToplevelManagerV1},
};

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

/// Best-effort: activate the already-running game's window. `needle` is the lowercased exe stem (matched
/// against WM_CLASS on X11 and app_id on Wayland); `title` is the human name (matched against the window
/// title on Wayland). Every failure — no server, no matching window, protocol absent — is swallowed: this
/// is a nicety, never a launch blocker. X11 is tried first; if it doesn't find a match (e.g. the game is a
/// native Wayland window, not an Xwayland one), fall through to the Wayland path.
pub fn raise_running(needle: &str, title: &str) {
    if matches!(try_raise_x11(needle), Ok(true)) {
        return;
    }
    let _ = try_raise_wayland(needle, title);
}

fn try_raise_x11(needle: &str) -> Result<bool, Box<dyn std::error::Error>> {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{AtomEnum, ClientMessageEvent, ConnectionExt, EventMask};

    let (conn, screen_num) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen_num].root;
    let net_client_list = conn.intern_atom(false, b"_NET_CLIENT_LIST")?.reply()?.atom;
    let net_active = conn.intern_atom(false, b"_NET_ACTIVE_WINDOW")?.reply()?.atom;

    let list = conn
        .get_property(false, root, net_client_list, AtomEnum::WINDOW, 0, u32::MAX)?
        .reply()?;

    for win in list.value32().into_iter().flatten() {
        let cls = conn
            .get_property(false, win, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 256)?
            .reply()?;
        let text = String::from_utf8_lossy(&cls.value).to_lowercase();
        if !needle.is_empty() && text.contains(needle) {
            // source-indication=1 (application), timestamp=0 (CurrentTime), no requestor window.
            let event = ClientMessageEvent::new(32, win, net_active, [1u32, 0, 0, 0, 0]);
            conn.send_event(
                false,
                root,
                EventMask::SUBSTRUCTURE_NOTIFY | EventMask::SUBSTRUCTURE_REDIRECT,
                event,
            )?;
            conn.flush()?;
            return Ok(true);
        }
    }
    Ok(false) // connected, but no matching X window (e.g. the game is a Wayland toplevel)
}

// ── Wayland: wlr-foreign-toplevel-management ─────────────────────────────────────────────────────────

/// Our own GTK splash's app_id (splash.rs `application_id`). The splash's TITLE is the game name, so it
/// would match the title fallback below — we must prefer the real game window over it, but DO activate it
/// as a last resort (the splash is the running instance's only window while the game is still cold-starting).
const SPLASH_APP_ID: &str = "org.propnix.launcher";

struct Toplevel {
    handle: ZwlrForeignToplevelHandleV1,
    app_id: String,
    title: String,
}

#[derive(Default)]
struct WlState {
    seat: Option<WlSeat>,
    manager: Option<ZwlrForeignToplevelManagerV1>,
    toplevels: Vec<Toplevel>,
}

fn try_raise_wayland(needle: &str, title: &str) -> Result<bool, Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let display = conn.display();
    let mut queue = conn.new_event_queue::<WlState>();
    let qh = queue.handle();
    let _registry = display.get_registry(&qh, ());

    let mut state = WlState::default();
    // Round 1: receive the globals (binds wl_seat + the toplevel manager, if advertised).
    queue.roundtrip(&mut state)?;
    if state.manager.is_none() {
        return Ok(false); // compositor doesn't implement wlr-foreign-toplevel-management (GNOME/KDE)
    }
    // Round 2+3: the manager enumerates existing toplevels, each of which emits app_id/title/done.
    queue.roundtrip(&mut state)?;
    queue.roundtrip(&mut state)?;

    // Preference order, so the real game wins over our own "starting…" splash while both are up, but the
    // splash is still focusable when the game window isn't mapped yet:
    //   1. game by app_id  — winewayland sets app_id to the exe's process name (e.g. "hollow knight.exe").
    //   2. game by title   — fallback for a title whose process name doesn't contain the exe stem.
    //   3. THIS game's splash — app_id is our splash's, matched by title (== the game name) so we grab this
    //      game's splash, not another propnix app's, when the game window hasn't appeared yet.
    let title_lc = title.to_lowercase();
    let title_hit = |t: &Toplevel| !title_lc.is_empty() && t.title.to_lowercase().contains(&title_lc);
    let matched = state
        .toplevels
        .iter()
        .find(|t| t.app_id != SPLASH_APP_ID && !needle.is_empty() && t.app_id.to_lowercase().contains(needle))
        .or_else(|| state.toplevels.iter().find(|t| t.app_id != SPLASH_APP_ID && title_hit(t)))
        .or_else(|| state.toplevels.iter().find(|t| t.app_id == SPLASH_APP_ID && title_hit(t)));

    match (matched, &state.seat) {
        (Some(t), Some(seat)) => {
            t.handle.activate(seat);
            queue.roundtrip(&mut state)?; // flush the activate request
            Ok(true)
        }
        _ => Ok(false),
    }
}

impl Dispatch<WlRegistry, ()> for WlState {
    fn event(
        state: &mut Self,
        registry: &WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_seat" => {
                    state.seat = Some(registry.bind::<WlSeat, _, _>(name, version.min(1), qh, ()));
                }
                "zwlr_foreign_toplevel_manager_v1" => {
                    state.manager = Some(registry.bind::<ZwlrForeignToplevelManagerV1, _, _>(
                        name,
                        version.min(3),
                        qh,
                        (),
                    ));
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<WlSeat, ()> for WlState {
    fn event(_: &mut Self, _: &WlSeat, _: <WlSeat as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<ZwlrForeignToplevelManagerV1, ()> for WlState {
    fn event(
        state: &mut Self,
        _: &ZwlrForeignToplevelManagerV1,
        event: zwlr_foreign_toplevel_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zwlr_foreign_toplevel_manager_v1::Event::Toplevel { toplevel } = event {
            state.toplevels.push(Toplevel {
                handle: toplevel,
                app_id: String::new(),
                title: String::new(),
            });
        }
    }

    // The `toplevel` event creates a child object (the handle); declare its dispatch target.
    event_created_child!(WlState, ZwlrForeignToplevelManagerV1, [
        zwlr_foreign_toplevel_manager_v1::EVT_TOPLEVEL_OPCODE => (ZwlrForeignToplevelHandleV1, ()),
    ]);
}

impl Dispatch<ZwlrForeignToplevelHandleV1, ()> for WlState {
    fn event(
        state: &mut Self,
        handle: &ZwlrForeignToplevelHandleV1,
        event: zwlr_foreign_toplevel_handle_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(t) = state.toplevels.iter_mut().find(|t| &t.handle == handle) else {
            return;
        };
        match event {
            zwlr_foreign_toplevel_handle_v1::Event::AppId { app_id } => t.app_id = app_id,
            zwlr_foreign_toplevel_handle_v1::Event::Title { title } => t.title = title,
            _ => {}
        }
    }
}
