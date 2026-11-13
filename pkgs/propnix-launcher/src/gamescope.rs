//! gamescope — the nested compositor every game runs inside (emulators/gamescope).
//!
//! The OUTER launcher stays a native client of the host compositor (the splash, the single-instance raise,
//! the display facts) and spawns gamescope where it used to spawn the inner launcher: gamescope runs the
//! inner as its child, so gamescope, the inner and the game all live in the mount namespace propnix-mount
//! lays in the spawn's pre_exec, and the inner builds the game's sealed env on top of gamescope's. To the
//! host the game is then ONE Wayland toplevel whatever it speaks: wine draws through winex11 and SDL
//! through x11 into gamescope's own Xwayland, which needs no Xwayland from the host compositor.
//!
//! What gamescope is told:
//!   * `--backend wayland -f --no-hotkeys` — a fullscreen Wayland client of the host that passes every key
//!     to the game (patch 0005: gamescope's own Super+key shortcuts are off; window management, fullscreen
//!     included, is the compositor's).
//!   * `-W/-H` = `PROPNIX_WIDTH/HEIGHT` (display.rs defaults them to the primary output's mode). With no
//!     `-w/-h`, gamescope sizes the X screen the game sees from these too, so they are the game's
//!     resolution. That screen is fixed at launch, while gamescope's window follows the compositor: a
//!     fullscreen area smaller than the mode (a compositor that keeps a notch out of fullscreen) is
//!     letterboxed into, never cropped, and setting `PROPNIX_HEIGHT` to that area makes the two agree.
//!   * `--app-id org.propnix.<appid>` + `--title <name>` (emulators/gamescope patch 0002) — the game's
//!     desktop-entry id and human name, so the compositor shows the game's icon and name, and focus.rs
//!     finds the window by id.
//!   * `--hdr-enabled` — HDR output when the host output is in HDR mode (gamescope asks the compositor's
//!     color management; an SDR output is unaffected). A title still opts in itself (env.rs, DXVK_HDR).
//!   * `-R <file>` — gamescope writes its nested DISPLAY there before it spawns the inner; the window
//!     watcher (run::watch_window) and `activate` reach gamescope's X server through it. See `Session` for
//!     that file and the X socket directory.
//!   * PROPNIX_FPS (settings.rs `FpsMode`): a cap N → `--framerate-limit N`, gamescope's limiter, which
//!     holds back the game's frame callbacks and so works for every graphics API. On a fixed-refresh
//!     output it rounds to a divisor of the refresh (60 Hz: 60/30/20/15 — a cap of 40 leaves 60), on a VRR
//!     output it paces exactly; the DXVK/vkd3d limiter (env.rs) keeps exact caps for those titles either
//!     way, and the two never conflict (the lower one wins). VRR mode (0) → `--adaptive-sync`: gamescope
//!     follows the host output's VRR when the compositor runs it (it cannot turn VRR on itself).
//!   * `-F <filter>` / `-S <scaler>` (`scaling`): how the game's image is scaled to the window when the two
//!     differ. The filter defaults to `fsr` — FSR 1, a portable shader that gamescope runs only while
//!     upscaling, so a game rendering at the window's size never pays for it — and a game may choose its
//!     own (pixel art: `scaler = "integer"`, `filter = "nearest"`).
//!   * `--expose-wayland` when an SDL game is set to draw through Wayland (its SDL driver is `wayland`):
//!     gamescope then serves a Wayland display of its own and points the game's WAYLAND_DISPLAY at it.
//!     Without the flag gamescope unsets WAYLAND_DISPLAY, and a Wayland client would fail to connect or fall
//!     back to the host's `wayland-0`, bypassing gamescope. A Wayland game inside gamescope gets no HDR (the
//!     WSI layer and gamescope's server offer HDR to X11 swapchains only). Wine never asks for it: winewayland
//!     cannot run on gamescope's server (no wl_subcompositor), so the wine path refuses `graphics = "wayland"`.
//!   * `--mangoapp` under PROPNIX_BENCH — gamescope's performance overlay, fed from gamescope's own view of
//!     the game's frames, so it covers every graphics API alike (DXVK, vkd3d, wined3d/GL, native GL).
//!
//! gamescope's own environment is the session's (it is a host client), plus the GL/Vulkan fallback stack
//! when the host has none (it composites with Vulkan; mangoapp draws with GL) and `<mangohud>/bin` on PATH
//! under bench (gamescope finds `mangoapp` there).

use crate::config::FallbackGl;
use crate::settings::FpsMode;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::process::Command;

/// What the game's gamescope is configured from.
pub struct Options<'a> {
    /// The gamescope package root (`bin/gamescope`, plus the WSI layer under `share`).
    pub root: &'a str,
    /// The host toplevel's app_id: the game's `org.propnix.<appid>` (= its desktop-entry id).
    pub app_id: &'a str,
    /// The host toplevel's title: the game's human-readable name.
    pub title: &'a str,
    /// PROPNIX_BENCH: run the mangoapp overlay.
    pub bench: bool,
    /// PROPNIX_FPS.
    pub fps: FpsMode,
    /// The game draws through Wayland: serve it gamescope's own Wayland display.
    pub expose_wayland: bool,
    pub scaling: &'a Scaling,
    /// The MangoHud package root (`bin/mangoapp`).
    pub mangohud: Option<&'a str>,
    pub fallback_gl: Option<&'a FallbackGl>,
    /// `Session::ready`.
    pub ready: &'a Path,
}

/// The gamescope command line, up to (not including) the `--` that precedes the inner launcher's argv,
/// which `run::spawn_mounted` appends.
pub fn command(o: &Options) -> Command {
    let mut cmd = Command::new(format!("{}/bin/gamescope", o.root));
    cmd.args(["--backend", "wayland", "-f", "--no-hotkeys"]);
    if let (Some(w), Some(h)) = (dimension("PROPNIX_WIDTH"), dimension("PROPNIX_HEIGHT")) {
        cmd.arg("-W").arg(w.to_string()).arg("-H").arg(h.to_string());
    }
    cmd.arg("--app-id").arg(o.app_id).arg("--title").arg(o.title);
    cmd.arg("--hdr-enabled");
    cmd.arg("-R").arg(o.ready);
    if o.expose_wayland {
        cmd.arg("--expose-wayland");
    }
    cmd.arg("-F").arg(&o.scaling.filter);
    if let Some(scaler) = &o.scaling.scaler {
        cmd.arg("-S").arg(scaler);
    }
    match o.fps {
        FpsMode::Fixed(n) => {
            cmd.arg("--framerate-limit").arg(n.to_string());
        }
        FpsMode::Vrr => {
            cmd.arg("--adaptive-sync");
        }
        FpsMode::Unmanaged => {}
    }

    if o.bench {
        cmd.arg("--mangoapp");
        if let Some(mh) = o.mangohud {
            let path = std::env::var("PATH").unwrap_or_default();
            cmd.env("PATH", format!("{mh}/bin:{path}"));
        }
    }

    // gamescope composites with Vulkan and mangoapp draws with GL, so on a host without its own stack they
    // need the fallback exactly as the game does. Inherited by the inner, whose seal scrubs and re-derives
    // LD_LIBRARY_PATH for the game; the discovery vars reach the game unchanged, which is what it would
    // have been given anyway.
    if let Some(gl) = crate::glstack::resolve(o.fallback_gl) {
        let ld = match std::env::var("LD_LIBRARY_PATH") {
            Ok(v) if !v.is_empty() => format!("{}:{v}", gl.lib_dir),
            _ => gl.lib_dir.clone(),
        };
        cmd.env("LD_LIBRARY_PATH", ld);
        for (k, v) in &gl.vars {
            if std::env::var_os(k).is_none() {
                cmd.env(k, v);
            }
        }
    }
    cmd
}

/// gamescope's scaling of the game's image to its window: `-F` filter (always) and `-S` scaler (gamescope's
/// own default unless set).
pub struct Scaling {
    pub filter: String,
    pub scaler: Option<String>,
}

const FILTERS: [&str; 6] = ["linear", "nearest", "fsr", "nis", "pixel", "sgsr"];
const SCALERS: [&str; 5] = ["auto", "integer", "fit", "fill", "stretch"];

/// `PROPNIX_GAMESCOPE_FILTER` / `PROPNIX_GAMESCOPE_SCALER` over the game's baked choice (app-options
/// `gamescope`), the filter defaulting to `fsr`. An unknown value is an error naming the accepted ones — a
/// typo must not turn into a game that never starts (gamescope refuses an unknown name).
pub fn scaling(baked_filter: Option<&str>, baked_scaler: Option<&str>) -> Result<Scaling, String> {
    fn pick(var: &str, baked: Option<&str>, allowed: &[&str]) -> Result<Option<String>, String> {
        let value = match std::env::var(var) {
            Ok(v) if !v.is_empty() => Some(v),
            _ => baked.map(str::to_string),
        };
        match value {
            Some(v) if !allowed.contains(&v.as_str()) => {
                Err(format!("{var}='{v}' is invalid — expected one of: {}", allowed.join(", ")))
            }
            v => Ok(v),
        }
    }
    Ok(Scaling {
        filter: pick("PROPNIX_GAMESCOPE_FILTER", baked_filter, &FILTERS)?.unwrap_or_else(|| "fsr".to_string()),
        scaler: pick("PROPNIX_GAMESCOPE_SCALER", baked_scaler, &SCALERS)?,
    })
}

/// The game's XDG_DATA_DIRS: gamescope's `share` (its WSI layer's implicit-layer manifest) ahead of the
/// inherited dirs. The layer gives a winex11/x11 Vulkan swapchain straight to gamescope instead of through
/// Xwayland — the path HDR colorspaces take. It loads into the HOST Vulkan loader, which is the one
/// winevulkan and box64's wrapped libvulkan both use, and enables itself only inside gamescope
/// (ENABLE_GAMESCOPE_WSI, set by gamescope).
pub fn xdg_data_dirs(root: &str) -> String {
    let base = match std::env::var("XDG_DATA_DIRS") {
        Ok(v) if !v.is_empty() => v,
        _ => "/usr/local/share:/usr/share".to_string(),
    };
    format!("{root}/share:{base}")
}

/// A positive integer from `var`, or None (unset, empty, or not a number — gamescope then keeps its own
/// default size).
fn dimension(var: &str) -> Option<u32> {
    std::env::var(var).ok()?.trim().parse::<u32>().ok().filter(|&n| n > 0)
}

/// The per-launch host paths gamescope works through, in the launcher's runtime dir and keyed by the outer's
/// pid (so two instances of a multi-instance THIN game never share them); removed when the guard drops.
///   * `ready` — gamescope's `-R` target. gamescope opens it O_WRONLY without O_CREAT, so it is created here.
///   * `x11_dir` — bound over `/tmp/.X11-unix` inside the game's namespace (run::spawn_mounted), so
///     gamescope's Xwayland creates its sockets in a directory we own. Inside the user namespace the host's
///     root-owned `/tmp/.X11-unix` reads as owned by nobody (only our uid is mapped), and the Xwayland
///     socket code refuses such a directory. The bind also leaves the game no route to the host's X server,
///     and gives the window watcher a socket PATH, reachable even when an offline title's network namespace
///     hides the abstract socket. Mode 0700: no other user may touch our sockets.
///   * `status` — where the inner reports its exit code (run::report_exit), which gamescope's own exit status
///     does not carry.
pub struct Session {
    pub ready: PathBuf,
    pub x11_dir: PathBuf,
    pub status: PathBuf,
}

impl Session {
    pub fn create(runtime_dir: &Path) -> std::io::Result<Session> {
        let pid = std::process::id();
        let ready = runtime_dir.join(format!("gamescope-{pid}"));
        std::fs::File::create(&ready)?;
        let x11_dir = runtime_dir.join(format!("x11-{pid}"));
        let _ = std::fs::remove_dir_all(&x11_dir); // a crashed launch's, if the pid came round again
        std::fs::DirBuilder::new().mode(0o700).create(&x11_dir)?;
        let status = runtime_dir.join(format!("status-{pid}"));
        let _ = std::fs::remove_file(&status); // likewise: never read a crashed launch's report
        Ok(Session { ready, x11_dir, status })
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.ready);
        let _ = std::fs::remove_dir_all(&self.x11_dir);
        let _ = std::fs::remove_file(&self.status);
        let _ = std::fs::remove_file(self.status.with_extension("tmp"));
    }
}

/// The nested X server's socket, once gamescope has written its DISPLAY (`":N gamescope-N\n"`) to `ready`:
/// `<x11_dir>/X<N>`, or the host's `/tmp/.X11-unix/X<N>` when that directory did not exist to be bound over
/// (gamescope then created it itself).
pub fn nested_socket(ready: &Path, x11_dir: &Path) -> Option<PathBuf> {
    let s = std::fs::read_to_string(ready).ok()?;
    let display = s.split_whitespace().next()?.strip_prefix(':')?;
    let n: u32 = display.split('.').next()?.parse().ok()?;
    [x11_dir, Path::new(X11_SOCKET_DIR)]
        .iter()
        .map(|d| d.join(format!("X{n}")))
        .find(|p| p.exists())
}

/// Where X clients look for a display's socket.
pub const X11_SOCKET_DIR: &str = "/tmp/.X11-unix";

/// A connection to gamescope's nested X server, by socket PATH (`Session`; the server runs without
/// authentication), once gamescope has written its DISPLAY.
pub fn connect_nested(ready: &Path, x11_dir: &Path) -> Option<x11rb::rust_connection::RustConnection> {
    use x11rb::rust_connection::{DefaultStream, RustConnection};
    let socket = nested_socket(ready, x11_dir)?;
    let stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
    let (stream, _) = DefaultStream::from_unix_stream(stream).ok()?;
    RustConnection::connect_to_stream(stream, 0).ok()
}

/// Ask gamescope to focus its window (emulators/gamescope patch 0004): set `GAMESCOPE_XDG_ACTIVATION_TOKEN`
/// on its root to `token` — an xdg-activation token, or empty to have gamescope request one itself
/// (focus.rs says what each earns). Best-effort.
pub fn activate(ready: &Path, x11_dir: &Path, token: &str) {
    let result = set_activation_token(ready, x11_dir, token);
    if std::env::var_os("PROPNIX_DEBUG").is_some() {
        match result {
            Ok(()) => eprintln!("propnix: focus request handed to gamescope (token: {})", if token.is_empty() { "none" } else { "yes" }),
            Err(e) => eprintln!("propnix: focus request not handed to gamescope: {e}"),
        }
    }
}

fn set_activation_token(ready: &Path, x11_dir: &Path, token: &str) -> Result<(), String> {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, PropMode};
    use x11rb::wrapper::ConnectionExt as _;
    let conn = connect_nested(ready, x11_dir).ok_or("no connection to gamescope's X server")?;
    let root = conn.setup().roots[0].root;
    let atom = conn
        .intern_atom(false, b"GAMESCOPE_XDG_ACTIVATION_TOKEN")
        .map_err(|e| e.to_string())?
        .reply()
        .map_err(|e| e.to_string())?
        .atom;
    // Checked, so the server has applied it before the connection closes.
    conn.change_property8(PropMode::REPLACE, root, atom, AtomEnum::STRING, token.as_bytes())
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let _ = conn.flush();
    Ok(())
}

/// `activate` for this session, off the caller's thread (the splash calls it from the GTK main loop).
pub fn activator(session: &Session) -> impl Fn(String) + 'static {
    let (ready, x11_dir) = (session.ready.clone(), session.x11_dir.clone());
    move |token| {
        let (ready, x11_dir) = (ready.clone(), x11_dir.clone());
        std::thread::spawn(move || activate(&ready, &x11_dir, &token));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(fps: FpsMode) -> Vec<String> {
        let ready = Path::new("/run/ready");
        let scaling = Scaling { filter: "fsr".to_string(), scaler: None };
        let cmd = command(&Options {
            scaling: &scaling,
            root: "/gs",
            app_id: "org.propnix.test",
            title: "Test",
            bench: false,
            fps,
            expose_wayland: false,
            mangohud: None,
            fallback_gl: None,
            ready,
        });
        cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect()
    }

    #[test]
    fn scaling_defaults_and_validates() {
        let s = scaling(None, None).unwrap();
        assert_eq!(s.filter, "fsr");
        assert_eq!(s.scaler, None);
        let s = scaling(Some("nearest"), Some("integer")).unwrap();
        assert_eq!((s.filter.as_str(), s.scaler.as_deref()), ("nearest", Some("integer")));
        assert!(scaling(Some("bilinear"), None).is_err());
        assert!(scaling(None, Some("zoom")).is_err());
    }

    #[test]
    fn fps_modes_map_to_gamescope_flags() {
        let fixed = args(FpsMode::Fixed(30));
        let i = fixed.iter().position(|a| a == "--framerate-limit").expect("cap passed");
        assert_eq!(fixed[i + 1], "30");
        assert!(!fixed.contains(&"--adaptive-sync".to_string()));

        let vrr = args(FpsMode::Vrr);
        assert!(vrr.contains(&"--adaptive-sync".to_string()));
        assert!(!vrr.contains(&"--framerate-limit".to_string()));

        let unmanaged = args(FpsMode::Unmanaged);
        assert!(!unmanaged.iter().any(|a| a == "--adaptive-sync" || a == "--framerate-limit"));
    }
}
