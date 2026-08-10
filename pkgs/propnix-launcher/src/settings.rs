//! Runtime settings = the baked `defaults` with `PROPNIX_*` env overrides layered on top. §5's promise is
//! that a user (or a NixOS module) can export any `PROPNIX_*` once to steer *every* game; this is where
//! that layering happens. The config bakes only defaults — never the live env.

use crate::config::Config;
use crate::util;
use std::path::PathBuf;

pub struct Settings {
    pub appid: String,
    pub graphics: String,
    pub d3d: String, // "dxvk" | "wined3d"
    pub fps: Option<u32>,
    pub dpi: Option<u32>,
    pub winedebug: String,
    pub bench: bool,
    pub no_prefetch: bool,
    pub save_dir_override: Option<String>,
    pub wine_bind: Option<String>, // extra ';'-separated GUESTREL|HOSTPATH binds (winefex escape hatch)
    pub unseal: bool,              // --propnix-unseal: skip the env scrub (debug)
    pub shell: bool,               // --shell: drop into a shell in the prefix instead of launching (debug)
    pub console: bool,             // forward the game's piped stdout/stderr to the terminal (else drained)
}

pub struct Paths {
    pub state: PathBuf,      // $XDG_STATE_HOME/propnix/<appid>
    pub cache: PathBuf,      // $XDG_CACHE_HOME/propnix/<appid>
    pub prefix: PathBuf,     // state/prefix (the symlink farm / WINEPREFIX)
    pub runtime: PathBuf,    // $XDG_RUNTIME_DIR/propnix/<appid> (the single-instance lock lives here)
    pub dxvk_cache: PathBuf,  // cache/dxvk (DXVK_STATE_CACHE_PATH — the shader cache; NOT a log dir)
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
    pub fn resolve(cfg: &Config, unseal: bool, shell: bool) -> Settings {
        let appid = env_nonempty("PROPNIX_APPID").unwrap_or_else(|| cfg.appid.clone());
        let graphics =
            env_nonempty("PROPNIX_WINE_GRAPHICS").unwrap_or_else(|| cfg.defaults.graphics.clone());
        let d3d = env_nonempty("PROPNIX_WINE_D3D").unwrap_or_else(|| cfg.defaults.d3d.clone());
        // A positive integer from the env wins; anything else (non-numeric, 0, negative) is ignored and we
        // fall back to the default rather than aborting. Not restricted to the game's UI options (30/60):
        // we cap at the DXVK/vkd3d layer, which takes any positive fps, independent of the game.
        let fps = env_nonempty("PROPNIX_FPS")
            .and_then(|v| v.parse::<u32>().ok())
            .filter(|&n| n > 0)
            .or(cfg.defaults.fps);
        let dpi = env_nonempty("PROPNIX_DPI")
            .and_then(|v| v.parse::<u32>().ok())
            .or(cfg.defaults.dpi);
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
            save_dir_override: env_nonempty("PROPNIX_SAVE_DIR"),
            wine_bind: env_nonempty("PROPNIX_WINE_BIND"),
            unseal,
            shell,
            // Forward the game's (noisy: DXVK info, Unity, wine) piped output to the terminal only when the
            // user opts in via PROPNIX_BENCH or an explicit PROPNIX_WINEDEBUG. By default the launcher just
            // drains + scans the pipe (for the splash marker), so a plain `nix run` has a quiet console.
            console: env_set("PROPNIX_BENCH") || env_nonempty("PROPNIX_WINEDEBUG").is_some(),
        }
    }

    pub fn is_dxvk(&self) -> bool {
        self.d3d == "dxvk"
    }

    pub fn paths(&self) -> Paths {
        let state = util::state_home().join("propnix").join(&self.appid);
        let cache = util::cache_home().join("propnix").join(&self.appid);
        let runtime = util::runtime_dir().join("propnix").join(&self.appid);
        let prefix = state.join("prefix");
        let dxvk_cache = cache.join("dxvk");
        let vkd3d_cache = cache.join("vkd3d");
        Paths {
            state,
            cache,
            prefix,
            runtime,
            dxvk_cache,
            vkd3d_cache,
        }
    }
}
