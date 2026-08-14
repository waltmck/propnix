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
use wayland_protocols::ext::foreign_toplevel_list::v1::client::{
    ext_foreign_toplevel_handle_v1::{self, ExtForeignToplevelHandleV1},
    ext_foreign_toplevel_list_v1::{self, ExtForeignToplevelListV1},
};
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
/// title on Wayland); `splash_app_id` is our GTK splash's app_id (`org.propnix.<appid>`), used to tell the
/// splash apart from the game toplevel (both carry the game's TITLE). Every failure — no server, no matching
/// window, protocol absent — is swallowed: this is a nicety, never a launch blocker. X11 is tried first; if
/// it doesn't find a match (e.g. the game is a native Wayland window, not an Xwayland one), fall through to
/// the Wayland path.
pub fn raise_running(needle: &str, title: &str, splash_app_id: &str) {
    if matches!(try_raise_x11(needle), Ok(true)) {
        return;
    }
    let _ = try_raise_wayland(needle, title, splash_app_id);
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

/// Result of probing whether the game's window has appeared (see `game_window_probe`).
pub enum Probe {
    /// The compositor doesn't advertise wlr-foreign-toplevel-management (GNOME/KDE), or there's no display —
    /// this signal is unavailable; the caller should stop polling and rely on its fallback.
    NoManager,
    /// The manager is present but the game's toplevel hasn't mapped yet — keep polling.
    NotFound,
    /// The game's toplevel is mapped.
    Found,
}

/// Best-effort: has the GAME's window mapped yet? (a compositor toplevel whose `app_id` != `splash_app_id`
/// and whose app_id contains `needle` (the exe stem) or whose title contains `title`). Two callers depend on
/// this: the splash dismiss (backends that emit NO first-present stderr marker — OpenGL titles) and
/// close-to-quit (the window later DISAPPEARING). Detection must be RELIABLE across desktops, so on Wayland
/// it uses the portable `ext-foreign-toplevel-list-v1` (GNOME Mutter 45+, KDE KWin 6, wlroots) and falls back
/// to `wlr-foreign-toplevel-management`; on a pure X11 session it uses EWMH `_NET_CLIENT_LIST`. Absent
/// protocol / transport error → NoManager (the caller relies on its own fallback, NEVER on a false "gone").
pub fn game_window_probe(needle: &str, title: &str, splash_app_id: &str) -> Probe {
    // On a Wayland session the Wayland toplevel protocols are the ONLY authority: an Xwayland
    // (`_NET_CLIENT_LIST`) query would report a native-wayland game window as absent → a false NotFound → a
    // false close-to-quit. So never fall through to X11 while WAYLAND_DISPLAY is set (ext/wlr list Xwayland
    // toplevels too, so x11-driver games are still covered).
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        for probe in [
            probe_ext as fn(&str, &str, &str) -> Result<Probe, Box<dyn std::error::Error>>,
            probe_wlr,
        ] {
            match probe(needle, title, splash_app_id) {
                Ok(Probe::NoManager) | Err(_) => continue, // this protocol is unavailable — try the next
                Ok(p) => return p,                          // Found/NotFound is authoritative
            }
        }
        return Probe::NoManager; // Wayland session with no toplevel-list protocol — don't guess via X11
    }
    probe_x11(needle, title).unwrap_or(Probe::NoManager) // pure X11 session
}

/// Does a toplevel's (app_id, title) identify the GAME window (not the splash, which carries `splash_app_id`)?
fn matches_game(app_id: &str, title: &str, needle: &str, title_lc: &str, splash_app_id: &str) -> bool {
    app_id != splash_app_id
        && ((!needle.is_empty() && app_id.to_lowercase().contains(needle))
            || (!title_lc.is_empty() && title.to_lowercase().contains(title_lc)))
}

/// Detection via the portable ext-foreign-toplevel-list-v1 (GNOME/KDE/wlroots).
fn probe_ext(
    needle: &str,
    title: &str,
    splash_app_id: &str,
) -> Result<Probe, Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let display = conn.display();
    let mut queue = conn.new_event_queue::<ExtState>();
    let qh = queue.handle();
    let _registry = display.get_registry(&qh, ());
    let mut state = ExtState::default();
    queue.roundtrip(&mut state)?; // globals
    if state.manager.is_none() {
        return Ok(Probe::NoManager);
    }
    queue.roundtrip(&mut state)?; // toplevel handles
    queue.roundtrip(&mut state)?; // their app_id/title/done
    let title_lc = title.to_lowercase();
    let found = state
        .toplevels
        .iter()
        .any(|t| matches_game(&t.app_id, &t.title, needle, &title_lc, splash_app_id));
    Ok(if found { Probe::Found } else { Probe::NotFound })
}

/// Detection via wlr-foreign-toplevel-management (wlroots; fallback when ext isn't advertised).
fn probe_wlr(
    needle: &str,
    title: &str,
    splash_app_id: &str,
) -> Result<Probe, Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let display = conn.display();
    let mut queue = conn.new_event_queue::<WlState>();
    let qh = queue.handle();
    let _registry = display.get_registry(&qh, ());
    let mut state = WlState::default();
    queue.roundtrip(&mut state)?; // globals
    if state.manager.is_none() {
        return Ok(Probe::NoManager);
    }
    queue.roundtrip(&mut state)?; // toplevel handles
    queue.roundtrip(&mut state)?; // their app_id/title
    let title_lc = title.to_lowercase();
    let found = state
        .toplevels
        .iter()
        .any(|t| matches_game(&t.app_id, &t.title, needle, &title_lc, splash_app_id));
    Ok(if found { Probe::Found } else { Probe::NotFound })
}

/// Detection via EWMH `_NET_CLIENT_LIST` on a pure X11 session (matches WM_CLASS or WM_NAME).
fn probe_x11(needle: &str, title: &str) -> Result<Probe, Box<dyn std::error::Error>> {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};
    let (conn, screen_num) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen_num].root;
    let net_client_list = conn.intern_atom(false, b"_NET_CLIENT_LIST")?.reply()?.atom;
    let list = conn
        .get_property(false, root, net_client_list, AtomEnum::WINDOW, 0, u32::MAX)?
        .reply()?;
    let title_lc = title.to_lowercase();
    for win in list.value32().into_iter().flatten() {
        let cls = conn
            .get_property(false, win, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 256)?
            .reply()?;
        if !needle.is_empty()
            && String::from_utf8_lossy(&cls.value)
                .to_lowercase()
                .contains(needle)
        {
            return Ok(Probe::Found);
        }
        if !title_lc.is_empty() {
            let name = conn
                .get_property(false, win, AtomEnum::WM_NAME, AtomEnum::STRING, 0, 256)?
                .reply()?;
            if String::from_utf8_lossy(&name.value)
                .to_lowercase()
                .contains(&title_lc)
            {
                return Ok(Probe::Found);
            }
        }
    }
    Ok(Probe::NotFound) // connected to X, no matching window
}

// ── Wayland: wlr-foreign-toplevel-management ─────────────────────────────────────────────────────────

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

fn try_raise_wayland(
    needle: &str,
    title: &str,
    splash_app_id: &str,
) -> Result<bool, Box<dyn std::error::Error>> {
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
    // splash is still focusable when the game window isn't mapped yet (the splash now carries the game's
    // `org.propnix.<appid>` app_id for the icon, so it's told apart by that id, not the shared title):
    //   1. game by app_id  — winewayland sets app_id to the exe's process name (e.g. "hollow knight.exe").
    //   2. game by title   — fallback for a title whose process name doesn't contain the exe stem.
    //   3. THIS game's splash — app_id == splash_app_id, matched by title (== the game name) so we grab this
    //      game's splash, not another propnix app's, when the game window hasn't appeared yet.
    let title_lc = title.to_lowercase();
    let title_hit = |t: &Toplevel| !title_lc.is_empty() && t.title.to_lowercase().contains(&title_lc);
    let matched = state
        .toplevels
        .iter()
        .find(|t| t.app_id != splash_app_id && !needle.is_empty() && t.app_id.to_lowercase().contains(needle))
        .or_else(|| state.toplevels.iter().find(|t| t.app_id != splash_app_id && title_hit(t)))
        .or_else(|| state.toplevels.iter().find(|t| t.app_id == splash_app_id && title_hit(t)));

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

// ── ext-foreign-toplevel-list-v1 dispatch (portable DETECTION — GNOME/KDE/wlroots) ───────────────────

struct ExtToplevel {
    handle: ExtForeignToplevelHandleV1,
    app_id: String,
    title: String,
}

#[derive(Default)]
struct ExtState {
    manager: Option<ExtForeignToplevelListV1>,
    toplevels: Vec<ExtToplevel>,
}

impl Dispatch<WlRegistry, ()> for ExtState {
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
            if interface == "ext_foreign_toplevel_list_v1" {
                state.manager = Some(registry.bind::<ExtForeignToplevelListV1, _, _>(
                    name,
                    version.min(1),
                    qh,
                    (),
                ));
            }
        }
    }
}

impl Dispatch<ExtForeignToplevelListV1, ()> for ExtState {
    fn event(
        state: &mut Self,
        _: &ExtForeignToplevelListV1,
        event: ext_foreign_toplevel_list_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let ext_foreign_toplevel_list_v1::Event::Toplevel { toplevel } = event {
            state.toplevels.push(ExtToplevel {
                handle: toplevel,
                app_id: String::new(),
                title: String::new(),
            });
        }
    }

    // The `toplevel` event creates a child object (the handle); declare its dispatch target.
    event_created_child!(ExtState, ExtForeignToplevelListV1, [
        ext_foreign_toplevel_list_v1::EVT_TOPLEVEL_OPCODE => (ExtForeignToplevelHandleV1, ()),
    ]);
}

impl Dispatch<ExtForeignToplevelHandleV1, ()> for ExtState {
    fn event(
        state: &mut Self,
        handle: &ExtForeignToplevelHandleV1,
        event: ext_foreign_toplevel_handle_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(t) = state.toplevels.iter_mut().find(|t| &t.handle == handle) else {
            return;
        };
        match event {
            ext_foreign_toplevel_handle_v1::Event::AppId { app_id } => t.app_id = app_id,
            ext_foreign_toplevel_handle_v1::Event::Title { title } => t.title = title,
            _ => {}
        }
    }
}
