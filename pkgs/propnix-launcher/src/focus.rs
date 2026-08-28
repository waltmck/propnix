//! Single-instance guard + best-effort raise-the-running-window (§5.1 / §5).
//!
//! The lock is an flock on `$XDG_RUNTIME_DIR/propnix/<appid>/lock`, held by the OUTER launcher. Rust opens
//! files O_CLOEXEC by default, so the lock fd is NOT inherited into the wine child — the lock tracks the
//! launcher's lifetime exactly (§5.1). A duplicate launch finds it busy, tries to raise the already-running
//! game window, and exits 0.
//!
//! Raising another client's window is deliberately restricted, so we try the paths that exist, best-effort:
//!   * X11 / Xwayland — EWMH `_NET_ACTIVE_WINDOW`, matched by WM_CLASS.
//!   * Wayland — `wlr-foreign-toplevel-management`, matched by app_id/title. This is the widely-implemented
//!     cross-compositor protocol WITH an `activate` verb (wlroots family: Hyprland/sway/Wayfire/…, plus
//!     COSMIC). It's what lets the launcher raise a window it doesn't own WITHOUT wine's cooperation
//!     (wine has no xdg-activation).
//!   * KDE — KWin implements neither of the above's activate verbs; its equivalent is its own
//!     `org_kde_plasma_window_management` (`set_state(active)` is how Plasma's taskbar raises windows),
//!     tried after wlr. Multiple clients may bind it despite the XML's stale "only one client" line —
//!     KWin broadcasts to every bound resource (plasmashell itself holds one on a real desktop). KWin
//!     HIDES this global from unauthorized clients: the grant is an installed desktop file whose Exec
//!     canonicalizes to the connecting binary and declares it in X-KDE-Wayland-Interfaces — which the
//!     launcher package ships and every game package installs (see propnix-launcher default.nix). An
//!     ungranted client (plain `nix run`, nothing installed) simply never sees the global.
//! A graceful no-op where none of these is available (GNOME Wayland has no activate verb at all for
//! foreign clients), and where there is no display at all.

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
use wayland_protocols_plasma::plasma_window_management::client::{
    org_kde_plasma_window::{self, OrgKdePlasmaWindow},
    org_kde_plasma_window_management::{self, OrgKdePlasmaWindowManagement},
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
    if matches!(try_raise_wayland(needle, title, splash_app_id), Ok(true)) {
        return;
    }
    let _ = try_raise_plasma(needle, title, splash_app_id);
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
    /// The compositor advertises none of the toplevel-list protocols (ext / wlr / plasma), or there's no
    /// display — this signal is unavailable; the caller should stop polling and rely on its fallback.
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
/// it uses the portable `ext-foreign-toplevel-list-v1` (GNOME Mutter 45+, wlroots) and falls back to
/// `wlr-foreign-toplevel-management`, then to KDE's `plasma-window-management` — KWin implements NEITHER
/// of the first two (verified against its src/wayland tree), so plasma is the only KDE signal, and it
/// requires the installed X-KDE-Wayland-Interfaces grant (see the module header); on a pure X11 session it
/// uses EWMH `_NET_CLIENT_LIST`. Absent protocol / transport error → NoManager (the caller relies on its
/// own fallback, NEVER on a false "gone").
pub fn game_window_probe(needle: &str, title: &str, splash_app_id: &str) -> Probe {
    // On a Wayland session the Wayland toplevel protocols are the ONLY authority: an Xwayland
    // (`_NET_CLIENT_LIST`) query would report a native-wayland game window as absent → a false NotFound → a
    // false close-to-quit. So never fall through to X11 while WAYLAND_DISPLAY is set (ext/wlr list Xwayland
    // toplevels too, so x11-driver games are still covered).
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        for probe in [
            probe_ext as fn(&str, &str, &str) -> Result<Probe, Box<dyn std::error::Error>>,
            probe_wlr,
            probe_plasma,
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

/// Detection via the portable ext-foreign-toplevel-list-v1 (GNOME Mutter 45+, wlroots; NOT KWin).
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

/// Detection via KDE's plasma-window-management — the only toplevel list ANY KWin has (it implements
/// neither ext nor wlr), so on KDE this is what the window-watcher runs on.
fn probe_plasma(
    needle: &str,
    title: &str,
    splash_app_id: &str,
) -> Result<Probe, Box<dyn std::error::Error>> {
    let (state, _queue) = plasma_enumerate()?;
    if state.manager.is_none() {
        return Ok(Probe::NoManager);
    }
    let title_lc = title.to_lowercase();
    let found = state
        .windows
        .iter()
        .any(|w| !w.dead && matches_game(&w.app_id, &w.title, needle, &title_lc, splash_app_id));
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

// ── ext-foreign-toplevel-list-v1 dispatch (portable DETECTION — GNOME Mutter 45+/wlroots) ────────────

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

// ── KDE: plasma-window-management (BOTH the raise and the window-watcher signal on KWin) ─────────────
//
// KWin's own protocol, and the only toplevel list AND the only activate verb it offers a foreign client
// (it implements neither wlr FTM nor the ext list; plasmashell's taskbar raises windows through exactly
// this request). KWin hides the global from clients without the installed X-KDE-Wayland-Interfaces
// desktop-file grant (see propnix-launcher default.nix) — ungranted, these paths see no manager and
// no-op. Verified against KWin's plasmawindowmanagement.cpp AND live against a nested kwin_wayland:
//   * multiple clients bind fine — the XML's "only one client" line is stale; KWin broadcasts to every
//     bound resource, and on a real desktop plasmashell already holds one.
//   * BOUND AT VERSION 13 — the `window_with_uuid` announce + `get_window_by_uuid` surface (Plasma
//     5.24+; an older KWin advertising <13 reads as no manager and no-ops). NOT the v1 `window(id)` +
//     `get_window(id)` path, which looks equivalent but is BROKEN in KWin: its by-id handler falls
//     through after serving the real window and unconditionally creates a throwaway temp window on the
//     SAME new_id, so every well-formed lookup is chased by a spurious `state=0` + `unmapped` (observed
//     live: every window read as dead). The by-uuid handler has the early return the by-id one lost.
//   * a stale uuid yields a synthetic window that immediately sends `unmapped` — which is why `dead`
//     windows are tracked and excluded rather than assumed impossible.

/// `org_kde_plasma_window_management.state` bit for "active" (frozen since v1). The `set_state` args are
/// plain uints in the protocol, so the generated request takes u32s rather than the enum type.
const PLASMA_STATE_ACTIVE: u32 = 0x1;

struct PlasmaWindow {
    handle: OrgKdePlasmaWindow,
    app_id: String,
    title: String,
    /// `unmapped` seen: the window is gone (or the id was stale — see the section header). Never match it.
    dead: bool,
}

#[derive(Default)]
struct PlasmaState {
    manager: Option<OrgKdePlasmaWindowManagement>,
    windows: Vec<PlasmaWindow>,
}

/// Connect and enumerate KWin's window list: three roundtrips, exactly like the wlr path (globals; the
/// `window(id)` announcements, answered with `get_window` from inside the dispatch; each window's
/// title/app_id/unmapped burst). Returns the queue too — the raise path issues one more request and
/// needs a roundtrip to flush it.
fn plasma_enumerate(
) -> Result<(PlasmaState, wayland_client::EventQueue<PlasmaState>), Box<dyn std::error::Error>> {
    let conn = Connection::connect_to_env()?;
    let display = conn.display();
    let mut queue = conn.new_event_queue::<PlasmaState>();
    let qh = queue.handle();
    let _registry = display.get_registry(&qh, ());
    let mut state = PlasmaState::default();
    queue.roundtrip(&mut state)?; // globals
    if state.manager.is_none() {
        return Ok((state, queue)); // not KWin — the caller reads this as NoManager / not raised
    }
    queue.roundtrip(&mut state)?; // window(id) announcements → get_window requests
    queue.roundtrip(&mut state)?; // each window's title/app_id/unmapped
    Ok((state, queue))
}

/// Raise via KWin's activate verb, with the same preference order as the wlr path: the game by app_id,
/// the game by title, then this game's own splash by title.
fn try_raise_plasma(
    needle: &str,
    title: &str,
    splash_app_id: &str,
) -> Result<bool, Box<dyn std::error::Error>> {
    let (mut state, mut queue) = plasma_enumerate()?;
    if state.manager.is_none() {
        return Ok(false); // compositor isn't KWin
    }
    let title_lc = title.to_lowercase();
    let live = |w: &&PlasmaWindow| !w.dead;
    let title_hit =
        |w: &PlasmaWindow| !title_lc.is_empty() && w.title.to_lowercase().contains(&title_lc);
    let matched = state
        .windows
        .iter()
        .filter(live)
        .find(|w| {
            w.app_id != splash_app_id && !needle.is_empty() && w.app_id.to_lowercase().contains(needle)
        })
        .or_else(|| {
            state
                .windows
                .iter()
                .filter(live)
                .find(|w| w.app_id != splash_app_id && title_hit(w))
        })
        .or_else(|| {
            state
                .windows
                .iter()
                .filter(live)
                .find(|w| w.app_id == splash_app_id && title_hit(w))
        });

    match matched {
        Some(w) => {
            // flags = which bits this request sets, state = their values: activate.
            w.handle.set_state(PLASMA_STATE_ACTIVE, PLASMA_STATE_ACTIVE);
            queue.roundtrip(&mut state)?; // flush the request
            Ok(true)
        }
        None => Ok(false),
    }
}

impl Dispatch<WlRegistry, ()> for PlasmaState {
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
            if interface == "org_kde_plasma_window_management" && version >= 13 {
                // Version 13 exactly, never lower — see the section header (the pre-uuid announce path
                // is broken in KWin) — and never higher (nothing above 13 is consumed, and the XML
                // reserves the right to change incompatibly).
                state.manager =
                    Some(registry.bind::<OrgKdePlasmaWindowManagement, _, _>(name, 13, qh, ()));
            }
        }
    }
}

impl Dispatch<OrgKdePlasmaWindowManagement, ()> for PlasmaState {
    fn event(
        state: &mut Self,
        manager: &OrgKdePlasmaWindowManagement,
        event: org_kde_plasma_window_management::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        // The announcement carries a uuid, not a new_id: the window OBJECT is client-created, by asking
        // for it (which is also what makes its title/app_id burst arrive — see enumerate). By-uuid, never
        // by the deprecated numeric id — see the section header.
        if let org_kde_plasma_window_management::Event::WindowWithUuid { uuid, .. } = event {
            state.windows.push(PlasmaWindow {
                handle: manager.get_window_by_uuid(uuid, qh, ()),
                app_id: String::new(),
                title: String::new(),
                dead: false,
            });
        }
    }
}

impl Dispatch<OrgKdePlasmaWindow, ()> for PlasmaState {
    fn event(
        state: &mut Self,
        handle: &OrgKdePlasmaWindow,
        event: org_kde_plasma_window::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(w) = state.windows.iter_mut().find(|w| &w.handle == handle) else {
            return;
        };
        match event {
            org_kde_plasma_window::Event::AppIdChanged { app_id } => w.app_id = app_id,
            org_kde_plasma_window::Event::TitleChanged { title } => w.title = title,
            org_kde_plasma_window::Event::Unmapped => w.dead = true,
            // For verifying an activation landed (the nested-KWin smoke test, or a user's desktop).
            org_kde_plasma_window::Event::StateChanged { flags } => {
                if std::env::var_os("PROPNIX_FOCUS_DEBUG").is_some() {
                    eprintln!(
                        "propnix: plasma window {:?} ({:?}) state flags {flags:#x}",
                        w.app_id, w.title
                    );
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Diagnostic, not a gate (`--ignored`): dump what every Wayland backend sees on WAYLAND_DISPLAY,
    /// and optionally exercise the raise paths. Run it against a compositor to debug focus issues:
    ///
    ///     WAYLAND_DISPLAY=… cargo test dump_toplevels -- --ignored --nocapture
    ///     PROPNIX_TEST_RAISE=<needle> … cargo test dump_toplevels -- --ignored --nocapture
    ///
    /// With PROPNIX_FOCUS_DEBUG=1 the plasma pass also prints each window's state flags — bit 0x1 set
    /// after a raise is the proof the activation landed (that is how the nested-KWin smoke test asserts).
    #[test]
    #[ignore]
    fn dump_toplevels() {
        let raise = std::env::var("PROPNIX_TEST_RAISE").unwrap_or_default();

        match plasma_enumerate() {
            Ok((state, _q)) => {
                eprintln!("plasma manager: {}", state.manager.is_some());
                for w in &state.windows {
                    eprintln!("  plasma: app_id={:?} title={:?} dead={}", w.app_id, w.title, w.dead);
                }
            }
            Err(e) => eprintln!("plasma: {e}"),
        }
        for (name, probe) in [
            ("ext", probe_ext as fn(&str, &str, &str) -> Result<Probe, Box<dyn std::error::Error>>),
            ("wlr", probe_wlr),
            ("plasma", probe_plasma),
        ] {
            let got = match probe(&raise, "", "org.propnix.test") {
                Ok(Probe::NoManager) => "NoManager".into(),
                Ok(Probe::NotFound) => "NotFound".into(),
                Ok(Probe::Found) => "Found".into(),
                Err(e) => format!("error: {e}"),
            };
            eprintln!("{name} probe (needle {raise:?}): {got}");
        }
        if !raise.is_empty() {
            eprintln!("wlr raise: {:?}", try_raise_wayland(&raise, "", "org.propnix.test").map_err(|e| e.to_string()));
            eprintln!("plasma raise: {:?}", try_raise_plasma(&raise, "", "org.propnix.test").map_err(|e| e.to_string()));
        }
    }
}
