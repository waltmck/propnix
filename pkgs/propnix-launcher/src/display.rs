//! Compositor-derived runtime facts (§5). The launcher fills geometry `PROPNIX_*` env vars from the primary
//! Wayland output's current mode when the user hasn't set them, so a game's `setupScript` gets a default that
//! matches the actual display:
//!   * `PROPNIX_WIDTH` / `PROPNIX_HEIGHT` — the output's current mode, in physical pixels.
//! These are SAFE to auto-populate: they have no side effect beyond being read by a setupScript.
//!
//! Refresh (`PROPNIX_FPS`) and DPI (`PROPNIX_DPI`) are deliberately NOT derived here: their consumers are
//! heavy and one is PERSISTENT — `PROPNIX_FPS` drives the DXVK frame-cap/vsync policy (settings.rs `FpsMode`)
//! and `PROPNIX_DPI` stamps `HKCU\…\LogPixels` into the prefix's user.reg, which survives in the overlay
//! upper and has misrendered games (it black-screened Skyrim). Both stay strictly opt-in (set them
//! explicitly to apply). We use the compositor's per-output logical POSITION only to pick the primary output.
//!
//! A user-set value ALWAYS wins — we only ever set what is unset. Wayland is a hard dependency of propnix, so
//! this is the only detection path: no X11/DRM fallback. Any failure here (no compositor, no output, protocol
//! absent) leaves the vars untouched — a graceful default, never a launch blocker. MUST be called
//! single-threaded (before any thread spawns): it mutates the process env.

use wayland_client::protocol::{
    wl_output::{self, WlOutput},
    wl_registry::{self, WlRegistry},
};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle, WEnum};
use wayland_protocols::xdg::xdg_output::zv1::client::{
    zxdg_output_manager_v1::ZxdgOutputManagerV1,
    zxdg_output_v1::{self, ZxdgOutputV1},
};

/// Per-object user-data: the index into `State::outputs` this wl_output / xdg_output refers to.
#[derive(Clone, Copy)]
struct OutputId(usize);

#[derive(Default, Clone)]
struct Output {
    x: i32,
    y: i32,
    mode_w: i32,
    mode_h: i32,
}

#[derive(Default)]
struct State {
    outputs: Vec<Output>,
    wl_outputs: Vec<WlOutput>, // parallel to `outputs`, to create the matching xdg_output
    xdg_mgr: Option<ZxdgOutputManagerV1>,
}

/// The compositor-derived facts.
struct Facts {
    width: u32,
    height: u32,
}

/// Populate `PROPNIX_WIDTH/HEIGHT` from the compositor when unset. Best-effort: any failure is swallowed,
/// leaving the vars as they were.
pub fn populate_facts() {
    let debug = std::env::var_os("PROPNIX_DEBUG").is_some();
    let facts = match detect() {
        Some(f) => f,
        None => {
            if debug {
                eprintln!("propnix: display facts: none (no compositor output detected)");
            }
            return;
        }
    };
    // Only the SAFE geometry facts are auto-set (they merely feed a setupScript). Refresh/DPI are deliberately
    // NOT derived — their consumers force vsync-off / stamp a persistent LogPixels into user.reg that
    // misrenders games (see the module doc). They stay opt-in via explicit PROPNIX_FPS/DPI.
    set_if_unset("PROPNIX_WIDTH", &facts.width.to_string());
    set_if_unset("PROPNIX_HEIGHT", &facts.height.to_string());
    if debug {
        // First-stop diagnostic: what the compositor reported for the primary output + the geometry vars we
        // auto-set (for a setupScript), shown with the effective env value so an explicit override is visible.
        let ev = |k: &str| std::env::var(k).unwrap_or_else(|_| "-".into());
        eprintln!(
            "propnix: display facts (compositor primary output): mode={}x{} → \
             set PROPNIX_WIDTH={} PROPNIX_HEIGHT={}",
            facts.width,
            facts.height,
            ev("PROPNIX_WIDTH"),
            ev("PROPNIX_HEIGHT"),
        );
    }
}

/// Set `k` to `v` only if it is currently unset or empty (a user-provided value always wins).
fn set_if_unset(k: &str, v: &str) {
    let already = std::env::var_os(k).map(|x| !x.is_empty()).unwrap_or(false);
    if !already {
        std::env::set_var(k, v);
    }
}

/// Query the compositor for the primary output's current mode + logical size, and derive the facts.
/// Returns None on any transport/protocol failure or when no output reports a usable mode.
fn detect() -> Option<Facts> {
    let conn = Connection::connect_to_env().ok()?;
    let display = conn.display();
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    display.get_registry(&qh, ());

    let mut state = State::default();
    queue.roundtrip(&mut state).ok()?; // globals → bind wl_outputs + the xdg-output manager

    // Now that the manager and the outputs are bound, request each output's xdg-output (logical size/pos).
    if let Some(mgr) = state.xdg_mgr.clone() {
        for (i, o) in state.wl_outputs.iter().enumerate() {
            mgr.get_xdg_output(o, &qh, OutputId(i));
        }
    }
    // Two more roundtrips to collect the wl_output (geometry/mode) + xdg_output (logical_size) events, which
    // arrive after the binds/requests above.
    queue.roundtrip(&mut state).ok()?;
    let _ = queue.roundtrip(&mut state);

    // Primary output = the usable one closest to the origin (compositors place the primary at 0,0). Ties
    // resolve topmost-then-leftmost.
    let primary = state
        .outputs
        .iter()
        .filter(|o| o.mode_w > 0 && o.mode_h > 0)
        .min_by_key(|o| (o.y, o.x))?;

    let width = primary.mode_w as u32;
    let height = primary.mode_h as u32;

    Some(Facts { width, height })
}

impl Dispatch<WlRegistry, ()> for State {
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
                "wl_output" => {
                    let idx = state.outputs.len();
                    state.outputs.push(Output::default());
                    let out =
                        registry.bind::<WlOutput, _, _>(name, version.min(4), qh, OutputId(idx));
                    state.wl_outputs.push(out);
                }
                "zxdg_output_manager_v1" => {
                    state.xdg_mgr = Some(registry.bind::<ZxdgOutputManagerV1, _, _>(
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

impl Dispatch<WlOutput, OutputId> for State {
    fn event(
        state: &mut Self,
        _: &WlOutput,
        event: wl_output::Event,
        id: &OutputId,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(o) = state.outputs.get_mut(id.0) else {
            return;
        };
        match event {
            wl_output::Event::Geometry { x, y, .. } => {
                o.x = x;
                o.y = y;
            }
            wl_output::Event::Mode {
                flags,
                width,
                height,
                ..
            } => {
                let current = matches!(flags, WEnum::Value(f) if f.contains(wl_output::Mode::Current));
                // The current mode is authoritative; otherwise take the first mode as a fallback.
                if current || o.mode_w == 0 {
                    o.mode_w = width;
                    o.mode_h = height;
                }
            }
            _ => {}
        }
    }
}

impl Dispatch<ZxdgOutputManagerV1, ()> for State {
    fn event(
        _: &mut Self,
        _: &ZxdgOutputManagerV1,
        _: <ZxdgOutputManagerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZxdgOutputV1, OutputId> for State {
    fn event(
        state: &mut Self,
        _: &ZxdgOutputV1,
        event: zxdg_output_v1::Event,
        id: &OutputId,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(o) = state.outputs.get_mut(id.0) else {
            return;
        };
        match event {
            zxdg_output_v1::Event::LogicalPosition { x, y } => {
                // xdg-output's logical position is more reliable than wl_output geometry for placement (it's
                // how we pick the primary output — the one closest to the origin).
                o.x = x;
                o.y = y;
            }
            _ => {}
        }
    }
}
