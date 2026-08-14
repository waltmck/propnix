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

        // WINEPREFIX is the ephemeral view (assembled by propnix-mount); the persistent state is the upper
        // bound in as its base. Set inside the namespace, where the view is live.
        push("WINEPREFIX", paths.view.to_string_lossy().into_owned());
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

            // PROPNIX_FPS policy (three-state; resolved in settings.rs). DXVK_FRAME_RATE is the timer-paced
            // limiter honored by BOTH DXVK and vkd3d-proton (its swapchain reads it and overrides the game's
            // own target); `dxgi.syncInterval` / `d3d9.presentInterval` force the swapchain's vsync (0=off for
            // D3D10/11 and D3D9 respectively, 1=on). The forced knob is appended to any inherited DXVK_CONFIG
            // (vkd3d ignores DXVK_CONFIG but honors the limiter, presenting unlocked when uncapped). wined3d
            // has no such knob, so every mode is a no-op there (it is not DXVK).
            //   Fixed(N): cap at N AND force vsync OFF. The cap must pace, not FIFO: FIFO vsync re-imposes
            //             vblank quantization, turning any frame-time jitter (FEX-JIT'd game thread,
            //             compositor round-trip) into a bimodal 16.7/33.3 ms stutter — measured on HK as
            //             ~50-55 fps vsync-on vs a steady 60 with the cap.
            //   Vrr:      no cap + force vsync ON. On a VRR output the compositor varies the refresh to follow
            //             the GPU (true VRR); on a fixed output it degrades to plain vsync capped at refresh.
            //             Never tears.
            //   Unmanaged: touch neither knob — the game's own present mode / cap stand.
            use crate::settings::FpsMode;
            let forced_sync = match settings.fps {
                FpsMode::Fixed(fps) => {
                    push("DXVK_FRAME_RATE", fps.to_string());
                    Some("dxgi.syncInterval=0;d3d9.presentInterval=0")
                }
                FpsMode::Vrr => Some("dxgi.syncInterval=1;d3d9.presentInterval=1"),
                FpsMode::Unmanaged => None,
            };
            if let Some(forced) = forced_sync {
                let combined = match std::env::var("DXVK_CONFIG") {
                    Ok(base) if !base.is_empty() => format!("{base};{forced}"),
                    _ => forced.to_string(),
                };
                push("DXVK_CONFIG", combined);
            }

            // PROPNIX_BENCH → on-screen overlay via MangoHud's Vulkan implicit layer. DXVK (d3d9/10/11) and
            // vkd3d (d3d12) are BOTH Vulkan (host-Vulkan via winevulkan), so ONE layer covers the whole
            // backend — unlike DXVK_HUD, which is DXVK-only and shows nothing for a vkd3d/D3D12 game. Enable
            // it the SAFE way: MANGOHUD=1 + the layer manifest dir on XDG_DATA_DIRS — NOT the `mangohud`
            // wrapper / its GL LD_PRELOAD, whose host-GL hook white-screens on this stack (MangoHud's glad
            // loader is GLX-only, but wine 10.17+ defaults to EGL). The aarch64 manifest has an ABSOLUTE
            // library_path, so the layer loads despite the seal scrubbing LD_*. On Asahi, GPU load/temp are
            // blank (driver unsupported by MangoHud) but fps/frametime/CPU/versions render. Respect an
            // inherited MANGOHUD_CONFIG. (wined3d has no Vulkan swapchain to hook — its bench fps prints to
            // the console via wine's `+fps` channel; see settings.winedebug.)
            if settings.bench {
                push("MANGOHUD", "1".to_string());
                let base = match std::env::var("XDG_DATA_DIRS") {
                    Ok(v) if !v.is_empty() => v,
                    _ => "/usr/share".to_string(),
                };
                push(
                    "XDG_DATA_DIRS",
                    format!("{}/share:{base}", cfg.emulators.mangohud),
                );
                if std::env::var_os("MANGOHUD_CONFIG").is_none() {
                    push(
                        "MANGOHUD_CONFIG",
                        "fps,frame_timing,cpu_stats,gpu_stats,engine_version,wine".to_string(),
                    );
                }
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
