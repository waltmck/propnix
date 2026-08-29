//! The GL/Vulkan fallback stack (config.rs `FallbackGl`): activation policy + the env it derives.
//!
//! Nix-built glvnd and vulkan-loader find their vendor through `/run/opengl-driver` (their RUNPATH's first
//! entry / the loader's ICD dir) — a NixOS-ism. On any other distro that path does not exist, the union
//! carries no mesa, and every GL context / Vulkan instance fails: observed as Unity's "Couldn't find
//! matching GLX visual … exiting" one second into Hollow Knight on Fedora. So each app bakes a mesa and the
//! launcher activates it here IFF the host provides no stack of its own — or unconditionally when the
//! game's `mesa` knob FORCED one (a per-game driver patch must also beat the host's `/run/opengl-driver`).
//!
//! Activation is env-only, through the stacks' own official discovery knobs, so a host with real drivers
//! (NixOS, incl. proprietary-driver hosts) is untouched by default:
//!   * `lib_dir` → appended to the child's LD_LIBRARY_PATH: glvnd dlopens `libGLX_mesa.so.0` /
//!     `libEGL_mesa.so.0` by soname, and LD_LIBRARY_PATH is searched before the glvnd RUNPATH that would
//!     have found `/run/opengl-driver` — which is also exactly why a FORCED stack wins on NixOS.
//!   * `__GLX_VENDOR_LIBRARY_NAME` — skip the X-server vendor negotiation. The name is SNIFFED from the
//!     baked tree's `libGLX_<vendor>.so.0`, not hardcoded to mesa: the `mesa` knob's real contract is
//!     "any glvnd-layout vendor tree", which is the proprietary-driver escape hatch (below).
//!   * `LIBGL_DRIVERS_PATH` — where the mesa vendor libs find their DRI megadrivers; `LIBVA_DRIVERS_PATH`
//!     names the same dir (mesa's VA-API video drivers live there on the arches that build them).
//!   * `GBM_BACKENDS_PATH` — mesa ≥24 loads gbm's `dri_gbm.so` backend from here; winewayland allocates
//!     its presentation buffers through gbm, so wine titles need this beyond GLX/EGL.
//!   * `__EGL_VENDOR_LIBRARY_DIRS` — glvnd's EGL ICD dir override.
//!   * `VK_DRIVER_FILES` — the vulkan-loader's explicit ICD list (every *.json in the baked dir, sorted;
//!     the loader probes each and uses the one that matches the hardware). The MODERN spelling, not the
//!     deprecated `VK_ICD_FILENAMES` nixGL still sets: the loader reading it is always OUR ≥1.4 loader
//!     from the closure (union / wine RUNPATH), never the host's.
//!
//! Every var is set ONLY if neither the baked per-game env nor the inherited session env already carries
//! it — `env.VK_DRIVER_FILES = …` on a game, or a user's shell override, always wins over the knob.
//!
//! Tradeoff, made deliberately: on a foreign-distro host with a PROPRIETARY driver (NVIDIA), the default
//! fallback means software rendering (llvmpipe/lavapipe) instead of trying to load the host's vendor
//! libraries into our nix-glibc process — which mixes two glibc builds, the exact failure mode that
//! SIGBUSed host binaries in the LD_PRELOAD incident. Slow-but-correct beats fast-but-crashy. The escape
//! hatch is the `mesa` knob itself: point it at a NIX-BUILT glvnd-layout tree of the proprietary
//! userspace matching the host's kernel module (nixGL's recipe — e.g. nixpkgs `nvidia_x11` arranged as
//! lib/ + share/vulkan/icd.d + share/glvnd/egl_vendor.d), and the vendor sniffing plus the tree's own
//! ICD JSONs route everything through it with no glibc mixing. Unsupported but unblocked.

use crate::config::FallbackGl;
use std::path::Path;

/// What the fallback contributes to a launch: a dir for the child's LD_LIBRARY_PATH plus discovery vars.
pub struct GlEnv {
    pub lib_dir: String,
    pub vars: Vec<(&'static str, String)>,
}

/// The env the fallback stack contributes, or None when the host's own stack should serve (the default on
/// NixOS: `/run/opengl-driver` exists and nothing forced).
pub fn resolve(fg: Option<&FallbackGl>) -> Option<GlEnv> {
    let fg = fg?;
    if !fg.forced && Path::new("/run/opengl-driver").exists() {
        return None;
    }
    let mut vars: Vec<(&'static str, String)> = vec![
        ("LIBGL_DRIVERS_PATH", fg.dri_dir.clone()),
        ("LIBVA_DRIVERS_PATH", fg.dri_dir.clone()),
        ("__EGL_VENDOR_LIBRARY_DIRS", fg.egl_vendor_dir.clone()),
    ];
    if let Some(vendor) = glx_vendor(&fg.lib_dir) {
        vars.push(("__GLX_VENDOR_LIBRARY_NAME", vendor));
    }
    // Per-arch/per-vendor: the baked tree may not ship a gbm backend dir at all — only name what exists.
    if Path::new(&fg.gbm_dir).is_dir() {
        vars.push(("GBM_BACKENDS_PATH", fg.gbm_dir.clone()));
    }
    // Sorted for a deterministic value; the loader probes each ICD and keeps what matches the hardware.
    let mut icds: Vec<String> = std::fs::read_dir(&fg.vulkan_icd_dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false))
                .map(|p| p.to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    icds.sort();
    if !icds.is_empty() {
        vars.push(("VK_DRIVER_FILES", icds.join(":")));
    }
    Some(GlEnv {
        lib_dir: fg.lib_dir.clone(),
        vars,
    })
}

/// The tree's GLX vendor, sniffed from its `libGLX_<vendor>.so.0`: "mesa" for a mesa tree, "nvidia" for a
/// proprietary-userspace tree (the escape hatch in the module header). None when the tree carries no GLX
/// vendor, or more than one — then the var stays unset and glvnd's normal negotiation runs against
/// whatever the LD path provides.
fn glx_vendor(lib_dir: &str) -> Option<String> {
    let names: Vec<String> = std::fs::read_dir(lib_dir)
        .ok()?
        .flatten()
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.strip_prefix("libGLX_")?
                .strip_suffix(".so.0")
                .map(str::to_owned)
        })
        .collect();
    match names.as_slice() {
        [one] => Some(one.clone()),
        _ => None,
    }
}

/// `base` (a ':'-joined library path, possibly empty) with the fallback's lib dir appended. Appending, not
/// prepending: nothing else in a launch's path carries these sonames, and appending cannot shadow a union
/// entry; it still beats glvnd's RUNPATH, which the loader only consults after LD_LIBRARY_PATH.
pub fn extend_ld_path(base: &str, gl: Option<&GlEnv>) -> String {
    match gl {
        None => base.to_string(),
        Some(g) if base.is_empty() => g.lib_dir.clone(),
        Some(g) => format!("{base}:{}", g.lib_dir),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_the_single_glx_vendor() {
        let d = std::env::temp_dir().join(format!("glstack-vendor-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        // The proprietary escape hatch: a tree whose only GLX vendor is nvidia. The unversioned and
        // fully-versioned names must NOT confuse the sniff.
        std::fs::write(d.join("libGLX_nvidia.so.0"), b"").unwrap();
        std::fs::write(d.join("libGLX_nvidia.so.0.0.0"), b"").unwrap();
        std::fs::write(d.join("libEGL_nvidia.so.0"), b"").unwrap();
        assert_eq!(glx_vendor(d.to_str().unwrap()), Some("nvidia".into()));
        // Two vendors → ambiguous → unset, glvnd negotiates.
        std::fs::write(d.join("libGLX_mesa.so.0"), b"").unwrap();
        assert_eq!(glx_vendor(d.to_str().unwrap()), None);
        // No such dir → unset.
        assert_eq!(glx_vendor("/does/not/exist"), None);
        let _ = std::fs::remove_dir_all(&d);
    }
}
