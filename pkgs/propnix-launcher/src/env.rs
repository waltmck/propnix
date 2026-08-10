//! The §7 environment seal + the DXVK/vkd3d runtime env.
//!
//! TARGETED SCRUB, never env_clear(): we unset only the inherited vars whose names start with a scrub
//! prefix (WINE*/FEX_*/BOX64_*/LD_*), leave the entire rest of the session env intact (WAYLAND_DISPLAY,
//! DISPLAY, GL, MESA_* shader cache, XDG_*, DBUS/PULSE/PIPEWIRE, PATH, LANG …), then set the meant vars on
//! top. Nix computed the intended set (config.seal); we enforce it here. A clear+allowlist could drop one
//! GL/Wayland var and black-screen the game — the targeted scrub cannot. (See prefer-targeted-env-scrub.)

use crate::config::Config;
use crate::settings::{Paths, Settings};
use std::process::Command;

pub struct ChildEnv {
    unset: Vec<String>,          // inherited names matching a scrub prefix (empty under --propnix-unseal)
    set: Vec<(String, String)>,  // the meant vars, applied on top
}

impl ChildEnv {
    pub fn build(cfg: &Config, settings: &Settings, paths: &Paths) -> ChildEnv {
        // Which inherited vars to unset: every current-env name that starts with a scrub prefix.
        let unset: Vec<String> = if settings.unseal {
            Vec::new()
        } else {
            std::env::vars()
                .map(|(k, _)| k)
                .filter(|k| cfg.seal.scrub.iter().any(|p| k.starts_with(p)))
                .collect()
        };

        let mut set: Vec<(String, String)> = Vec::new();
        let mut push = |k: &str, v: String| set.push((k.to_string(), v));

        // The baked "meant" vars (USER/LOGNAME + any per-game extras). WINEDEBUG is recomputed below.
        for (k, v) in &cfg.seal.set_env {
            if k != "WINEDEBUG" {
                push(k, v.clone());
            }
        }

        push("WINEPREFIX", paths.prefix.to_string_lossy().into_owned());
        push("WINEDEBUG", settings.winedebug.clone());

        // WINEDLLOVERRIDES, composed from the STRUCTURED map: the baked per-DLL overrides
        // (mscoree=b; mshtml=; winemenubuilder.exe=), plus the native DXVK/vkd3d D3D DLLs when the DXVK
        // backend is active. Merging as a map (not string prepend) means per-DLL entries compose cleanly.
        let mut overrides = cfg.seal.dll_overrides.clone();
        if settings.is_dxvk() {
            for dll in ["d3d11", "d3d10core", "dxgi", "d3d9", "d3d12", "d3d12core"] {
                overrides.insert(dll.to_string(), "n".to_string());
            }
        }
        // BTreeMap → sorted, deterministic. Empty value = disabled (e.g. `mshtml=`).
        let joined = overrides
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join(";");
        push("WINEDLLOVERRIDES", joined);

        if settings.is_dxvk() {
            // Persist the pipeline/shader caches under XDG_CACHE_HOME so cold-start compile happens once.
            // Both DXVK (d3d9/10/11) and vkd3d-proton (d3d12) DLLs are installed on this backend, so a game
            // may use EITHER (e.g. Unity with `-force-d3d12` → vkd3d). vkd3d otherwise defaults its cache to
            // the cwd — the READ-ONLY store payload — and fails to write it, so pin it to a writable dir.
            push(
                "DXVK_STATE_CACHE_PATH",
                paths.dxvk_cache.to_string_lossy().into_owned(),
            );
            push(
                "VKD3D_SHADER_CACHE_PATH",
                paths.vkd3d_cache.to_string_lossy().into_owned(),
            );
            // No DXVK log FILE (`none`) — zero disk writes. `info` levels so the first-present markers reach
            // STDERR (DXVK's `Presenter:`; vkd3d's `Creating swapchain`), which run.rs pipes to the launcher
            // to drive the splash close (event-driven). Not console spam: the launcher only forwards that
            // pipe to the terminal under PROPNIX_BENCH / PROPNIX_WINEDEBUG; otherwise it drains + scans
            // silently. VKD3D_DEBUG=info is a no-op unless the game actually loads vkd3d (uses D3D12).
            push("DXVK_LOG_PATH", "none".to_string());
            push("DXVK_LOG_LEVEL", "info".to_string());
            push("VKD3D_DEBUG", "info".to_string());

            // PROPNIX_FPS: cap the frame rate AND force vsync OFF (only when a cap is set; otherwise the
            // game's own vsync/cap are left untouched). DXVK_FRAME_RATE is the timer-paced limiter, honored
            // by BOTH DXVK and vkd3d-proton (its swapchain reads DXVK_FRAME_RATE and overrides the game's
            // own target). Vsync must be off for the cap to pace cleanly: FIFO vsync re-imposes vblank
            // quantization, which turns any frame-time jitter (the FEX-JIT'd game thread, compositor
            // round-trip) into a bimodal 16.7/33.3 ms stutter — measured on HK as ~50-55 fps vsync-on vs a
            // steady 60 with the cap. `dxgi.syncInterval=0` forces vsync off for D3D10/11, `d3d9.*` for
            // D3D9; appended to any inherited DXVK_CONFIG. (vkd3d ignores DXVK_CONFIG, but with the limiter
            // active it presents via its unlocked, non-FIFO mode.) wined3d has no such knob → PROPNIX_FPS
            // is a no-op there (it is not DXVK).
            if let Some(fps) = settings.fps {
                push("DXVK_FRAME_RATE", fps.to_string());
                let forced = "dxgi.syncInterval=0;d3d9.presentInterval=0";
                let combined = match std::env::var("DXVK_CONFIG") {
                    Ok(base) if !base.is_empty() => format!("{base};{forced}"),
                    _ => forced.to_string(),
                };
                push("DXVK_CONFIG", combined);
            }

            // PROPNIX_BENCH → DXVK's on-screen HUD (upper-left): fps + frametime graph, GPU load, GPU
            // name/driver, DXVK version, D3D feature level. Respect an inherited DXVK_HUD if the user set
            // one (DXVK_* is outside the scrub namespaces, so it survives to here).
            if settings.bench && std::env::var_os("DXVK_HUD").is_none() {
                push(
                    "DXVK_HUD",
                    "fps,frametimes,gpuload,devinfo,version,api".to_string(),
                );
            }
        }

        ChildEnv { unset, set }
    }

    /// Apply the seal to a Command: inherit the parent env, unset the scrub matches, set the meant vars.
    pub fn apply(&self, cmd: &mut Command) {
        for k in &self.unset {
            cmd.env_remove(k);
        }
        for (k, v) in &self.set {
            cmd.env(k, v);
        }
    }
}
