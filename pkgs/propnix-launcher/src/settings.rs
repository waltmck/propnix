//! Runtime settings = the baked `defaults` with `PROPNIX_*` env overrides layered on top. §5's promise is
//! that a user (or a NixOS module) can export any `PROPNIX_*` once to steer *every* game; this is where
//! that layering happens. The config bakes only defaults — never the live env.

use crate::config::Config;
use crate::util;
use std::path::PathBuf;

/// The resolved `PROPNIX_FPS` policy (consumed in env.rs). See `Settings::resolve`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FpsMode {
    /// `PROPNIX_FPS` unset (and no baked default): touch neither the cap nor vsync — the game's own present
    /// mode / cap stand.
    Unmanaged,
    /// `PROPNIX_FPS=0`: no frame cap + vsync ON. The display's variable refresh follows the GPU (true VRR on
    /// a VRR output; plain vsync capped at the refresh otherwise).
    Vrr,
    /// `PROPNIX_FPS=N` (N > 0): cap at N + vsync OFF, so the timer-paced limiter paces cleanly.
    Fixed(u32),
}

impl FpsMode {
    /// Map the raw resolved integer (env-or-default) to a mode: absent → Unmanaged, 0 → Vrr, N>0 → Fixed(N).
    fn from_raw(raw: Option<u32>) -> FpsMode {
        match raw {
            None => FpsMode::Unmanaged,
            Some(0) => FpsMode::Vrr,
            Some(n) => FpsMode::Fixed(n),
        }
    }
}

pub struct Settings {
    pub appid: String,
    pub graphics: String,
    pub d3d: String, // "dxvk" | "wined3d"
    pub fps: FpsMode,
    pub dpi: Option<u32>,
    pub winedebug: String,
    pub bench: bool,
    pub no_prefetch: bool,
    pub unseal: bool, // --propnix-unseal: skip the env scrub (debug)
    pub console: bool,             // forward the game's piped stdout/stderr to the terminal (else drained)
}

pub struct Paths {
    pub state: PathBuf, // $XDG_STATE_HOME/propnix/<appid> — the game's state root (backend-agnostic)
    /// `<state>/wine` — the WINE backend's namespace under the game state root (prefix upper, profile
    /// overlays, the userReg-managed JSON). A future box64/native backend gets its own `<state>/<backend>`;
    /// backend-agnostic data (saves) lives outside, under `$PROPNIX_SAVE_DIR`.
    pub wine_state: PathBuf,
    pub cache: PathBuf, // $XDG_CACHE_HOME/propnix/<appid>
    /// The WINEPREFIX the game sees: a per-launch mountpoint (a random /tmp dir) onto which propnix-mount
    /// mounts a fresh ns-private tmpfs, then lays the whole prefix. Ephemeral — nothing persists in the tmpfs
    /// itself (persistent state is the overlay uppers under `state`); an unclean exit leaves an empty dir.
    pub view: PathBuf,
    pub runtime: PathBuf, // $XDG_RUNTIME_DIR/propnix/<appid> (the single-instance lock lives here)
    pub dxvk_cache: PathBuf, // cache/dxvk (DXVK_STATE_CACHE_PATH — the shader cache; NOT a log dir)
    pub vkd3d_cache: PathBuf, // cache/vkd3d (VKD3D_SHADER_CACHE_PATH — D3D12 pipeline cache)
}

fn env_nonempty(k: &str) -> Option<String> {
    match std::env::var(k) {
        Ok(v) if !v.is_empty() => Some(v),
        _ => None,
    }
}

fn env_set(k: &str) -> bool {
    // Presence-with-nonempty semantics, matching winefex's `[ -n "${VAR:-}" ]`.
    env_nonempty(k).is_some()
}

impl Settings {
    pub fn resolve(cfg: &Config, unseal: bool) -> Settings {
        let appid = env_nonempty("PROPNIX_APPID").unwrap_or_else(|| cfg.appid.clone());
        let graphics =
            env_nonempty("PROPNIX_WINE_GRAPHICS").unwrap_or_else(|| cfg.defaults.graphics.clone());
        let d3d = env_nonempty("PROPNIX_WINE_D3D").unwrap_or_else(|| cfg.defaults.d3d.clone());
        // PROPNIX_FPS is three-state (the DXVK/vkd3d knobs it drives live in env.rs). Unset and empty-string
        // are IDENTICAL — both mean "not provided" → Unmanaged (touch nothing; the game's own vsync/cap
        // stand); `env_nonempty` collapses the two to `None`. A present, non-empty value is parsed: 0 → Vrr
        // (uncapped + vsync ON), N>0 → Fixed(N) (cap + vsync OFF); a non-numeric value is ignored → Unmanaged.
        // There is no baked fps default — a per-game way to steer this is deferred. The cap is applied at the
        // DXVK/vkd3d layer, independent of the game's own UI options.
        let fps = FpsMode::from_raw(env_nonempty("PROPNIX_FPS").and_then(|v| v.parse::<u32>().ok()));
        // DPI is env-only and opt-in: a positive `PROPNIX_DPI` becomes the HKCU LogPixels stamp (via the
        // `LogPixels = $PROPNIX_DPI` userReg entry, exported in graphics.rs); 0 / non-numeric / unset → no
        // stamp (the game/wine default DPI stands). There is deliberately no baked per-game DPI default — its
        // LogPixels stamp is persistent and has black-screened titles (e.g. Skyrim), so it's never auto-set.
        let dpi = env_nonempty("PROPNIX_DPI")
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|&n| n > 0);
        // WINEDEBUG: an explicit PROPNIX_WINEDEBUG wins verbatim. Otherwise "-all" (quiet) — EXCEPT on the
        // wined3d backend, where we also enable the `fps` channel: wine's wined3d logs `… @ approx N.NNfps`
        // there (dlls/wined3d/cs.c), which is the launcher's first-present marker for that backend (DXVK
        // and vkd3d emit their own). It's drained by default (piped), so it never reaches the console
        // unless PROPNIX_BENCH / PROPNIX_WINEDEBUG forward the stream.
        let winedebug = match env_nonempty("PROPNIX_WINEDEBUG") {
            Some(v) => v,
            None => {
                if d3d == "dxvk" {
                    "-all".to_string()
                } else {
                    "-all,+fps".to_string()
                }
            }
        };

        Settings {
            appid,
            graphics,
            d3d,
            fps,
            dpi,
            winedebug,
            bench: env_set("PROPNIX_BENCH"),
            no_prefetch: env_set("PROPNIX_NO_PREFETCH"),
            unseal,
            // Tee the game's (noisy: DXVK info, Unity, wine) piped stdout+stderr to OUR stdout only when the
            // user opts in: PROPNIX_DEBUG (the plain "show me the output" knob), PROPNIX_BENCH, or an
            // explicit PROPNIX_WINEDEBUG. Otherwise the launcher silently drains + scans the pipe (for the
            // splash marker), so a plain `nix run` has a quiet console.
            console: env_set("PROPNIX_BENCH")
                || env_set("PROPNIX_DEBUG")
                || env_nonempty("PROPNIX_WINEDEBUG").is_some(),
        }
    }

    /// THIN-mode settings (box64 / native Linux): no wine defaults to resolve — the backend has no
    /// graphics/d3d/fps/dpi knobs (those are wine's). We keep only the fields the shared OUTER machinery
    /// reads: `appid` (state paths, single-instance, PROPNIX_APPID), `console` (forward the game's piped
    /// stdout under PROPNIX_DEBUG/BENCH), `no_prefetch` (always true — there is no wine DLL lower to warm),
    /// and `unseal`. The wine-only fields get inert defaults so `paths()` / `watch_child` work unchanged.
    pub fn resolve_thin(appid: &str, unseal: bool) -> Settings {
        let appid = env_nonempty("PROPNIX_APPID").unwrap_or_else(|| appid.to_string());
        Settings {
            appid,
            graphics: String::new(),
            d3d: String::new(), // never "dxvk" → is_dxvk() is false, so the DXVK overlays/env never apply
            fps: FpsMode::Unmanaged,
            dpi: None,
            winedebug: String::new(),
            bench: env_set("PROPNIX_BENCH"),
            no_prefetch: true,
            unseal,
            console: env_set("PROPNIX_BENCH") || env_set("PROPNIX_DEBUG"),
        }
    }

    pub fn is_dxvk(&self) -> bool {
        self.d3d == "dxvk"
    }

    /// `view` is the per-launch WINEPREFIX mount root: the OUTER mints a fresh random /tmp dir
    /// (`mount::make_view`); the INNER receives that exact path back via `--view`.
    pub fn paths(&self, view: PathBuf) -> Paths {
        let state = util::state_home().join("propnix").join(&self.appid);
        let wine_state = state.join("wine");
        let cache = util::cache_home().join("propnix").join(&self.appid);
        let runtime = util::runtime_dir().join("propnix").join(&self.appid);
        let dxvk_cache = cache.join("dxvk");
        let vkd3d_cache = cache.join("vkd3d");
        Paths {
            state,
            wine_state,
            cache,
            view,
            runtime,
            dxvk_cache,
            vkd3d_cache,
        }
    }
}
