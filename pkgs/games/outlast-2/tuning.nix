# Outlast 2 — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this states
# only what is SPECIFIC to Outlast 2. Unreal Engine 3 survival-horror (Red Barrels; same studio + engine
# family as Outlast), renders D3D11 → native ARM64EC DXVK → Vulkan.
#
# Renders on STOCK DEFAULTS (graphics=wayland, d3d=dxvk) — VERIFIED: launches to the first-run gamma-
# calibration screen (a full 3D scene) at 2560x1664. UNLIKE Outlast 1, it needs NO `extraSystem32`: Outlast 2
# imports the newer MSVCP140/VCRUNTIME140 (VC++ 2015+) runtime, whose wine ARM64EC builtins load + init
# cleanly under FEX (only Outlast 1's older VC++ 2010 msvcp100 builtin access-violates). It also needs no
# Galaxy SDK stub (it starts + renders offline without one). So only the save mount is game-specific.
#
# NB (cosmetic): the Asahi/Mesa Vulkan driver logs "Clamping massive framebuffer" repeatedly — UE3 requests
# an oversized shadow/render target that the GPU clamps to its max dimension. It does NOT break rendering
# (the scene renders crisply); a future PROPNIX_QUALITY / shadow-resolution tune could silence it.
{
  # Save: UE3 (shipping) redirects user config + saves + logs to Documents\My Games\Outlast2 (the game
  # writes OLGame\Config\OL*.ini + saves there — VERIFIED: OLSystemSettings.ini ResX/ResY landed in the
  # bound dir). Bind the whole folder so saves + settings travel together, out to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/outlast-2).
  mounts."drive_c/users/propnix/Documents/My Games/Outlast2" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
