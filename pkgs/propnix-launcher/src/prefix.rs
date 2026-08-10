//! Prefix assembly — the SYMLINK FARM (§7.2), ported stage-for-stage from winefex.nix L162-224.
//!
//! Read-only content is symlinked into the store `prefixLower`; writable content is real and persists in
//! the per-app state dir. Rebuilt every launch: cheap (a few dozen symlinks), needs no bump-detection, and
//! restores anything wine clobbered last run (it can't write the 0444 store target, so it drops a real
//! file over the symlink — discarded + relinked here). NO overlay, NO mount, NO namespace.

use crate::config::Config;
use crate::settings::{Paths, Settings};
use crate::util::{force_symlink, rm_rf};
use std::fs;
use std::io;
use std::os::unix::fs::symlink;
use std::path::Path;

/// Recreate the directory skeleton of `src` under `dst` (dirs only), mirroring
/// `( cd src && find . -type d -print0 ) | ( cd dst && xargs -0 mkdir -p )`. Idempotent: only ensures the
/// standard profile/ProgramData dirs exist; never touches user data already present under `dst`.
fn seed_dir_skeleton(src: &Path, dst: &Path) -> io::Result<()> {
    if !src.is_dir() {
        return Ok(());
    }
    // Iterative walk (no recursion depth surprises); create each dir under dst.
    let mut stack = vec![src.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let rel = dir.strip_prefix(src).unwrap();
        fs::create_dir_all(dst.join(rel))?;
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            // Don't follow symlinks in the store lower — only descend real dirs.
            if entry.file_type()?.is_dir() {
                stack.push(entry.path());
            }
        }
    }
    Ok(())
}

pub fn assemble(cfg: &Config, settings: &Settings, paths: &Paths) -> io::Result<()> {
    let lower = Path::new(&cfg.emulators.prefix_lower);
    let pfx = &paths.prefix;
    let dc = pfx.join("drive_c");

    // ── writable, real, persistent dirs ───────────────────────────────────────────────────────────
    for d in [
        dc.join("windows/temp"),
        dc.join("users"),
        dc.join("ProgramData"),
        pfx.join("dosdevices"),
    ] {
        fs::create_dir_all(&d)?;
    }

    // Writable profile / ProgramData skeleton (real dirs; wine + apps fill AppData etc. here → persists).
    seed_dir_skeleton(&lower.join("drive_c/users"), &dc.join("users"))?;
    seed_dir_skeleton(&lower.join("drive_c/ProgramData"), &dc.join("ProgramData"))?;

    // dosdevices: c: → the prefix's drive_c (relative, as winefex); z: → host root.
    force_symlink(Path::new("../drive_c"), &pfx.join("dosdevices/c:"))?;
    force_symlink(Path::new("/"), &pfx.join("dosdevices/z:"))?;

    // ── read-only → store: registry hives + freeze stamp ───────────────────────────────────────────
    // system.reg (HKLM) + userdef.reg (HKU\.Default) are Admin-only hives games never write; the store
    // copy is authoritative every launch (any file wine dropped over the link last run is discarded here).
    // user.reg (HKCU) is deliberately NOT symlinked — wine regenerates it as a real, writable file on
    // first launch, and the launcher re-applies its HKCU overrides (config.userReg) into it every launch.
    for name in ["system.reg", "userdef.reg", ".update-timestamp"] {
        force_symlink(&lower.join(name), &pfx.join(name))?;
    }

    // ── read-only → store: C:\Windows\* (except temp) ──────────────────────────────────────────────
    let win = dc.join("windows");
    // Clear ALL existing symlinks first (drops entries removed across a wine/FEX bump), then recreate the
    // current set. Real files/dirs (temp) are left; the loop below rm_rf's any name it's about to relink.
    for entry in fs::read_dir(&win)? {
        let entry = entry?;
        if entry.file_type()?.is_symlink() {
            fs::remove_file(entry.path())?;
        }
    }
    for entry in fs::read_dir(lower.join("drive_c/windows"))? {
        let entry = entry?;
        let name = entry.file_name();
        if name == "temp" {
            continue; // C:\Windows\Temp is real + writable
        }
        force_symlink(&entry.path(), &win.join(&name))?;
    }

    // ── read-only → store: C:\Program Files{, (x86)} ───────────────────────────────────────────────
    for d in ["Program Files", "Program Files (x86)"] {
        let link = dc.join(d);
        rm_rf(&link)?; // may be a real dir if an installer wrote here
        let src = lower.join("drive_c").join(d);
        if src.exists() {
            symlink(&src, &link)?;
        }
    }

    // ── DXVK: rebuild system32 as a real dir of per-file store symlinks + drop the native ARM64EC DLLs ─
    // wine's builtin wined3d Vulkan renderer stalls to ~12 fps here; native DXVK reaches 60 (RESEARCH §22).
    // DXVK needs REAL files in system32, so replace the whole-dir symlink made above with a real dir whose
    // entries are per-file symlinks, then overlay the DXVK/vkd3d DLLs. A wined3d launch keeps the whole-dir
    // symlink, so switching backends is clean either way.
    if settings.is_dxvk() {
        let sys = win.join("system32");
        rm_rf(&sys)?;
        fs::create_dir_all(&sys)?;
        for entry in fs::read_dir(lower.join("drive_c/windows/system32"))? {
            let entry = entry?;
            symlink(entry.path(), sys.join(entry.file_name()))?;
        }
        let dxvk = Path::new(&cfg.emulators.dxvk);
        for d in ["d3d11", "d3d10core", "dxgi", "d3d9"] {
            force_symlink(&dxvk.join(format!("{d}.dll")), &sys.join(format!("{d}.dll")))?;
        }
        // vkd3d-proton (D3D12): ships only d3d12/d3d12core; reuses DXVK's dxgi (installed just above).
        let vkd3d = Path::new(&cfg.emulators.vkd3d);
        for d in ["d3d12", "d3d12core"] {
            force_symlink(&vkd3d.join(format!("{d}.dll")), &sys.join(format!("{d}.dll")))?;
        }
    }

    Ok(())
}
