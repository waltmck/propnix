# Stellaris — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this states
# only what is SPECIFIC to Stellaris. Paradox Clausewitz engine (D3D11/D3D9 → DXVK), well-behaved on the
# global defaults (d3d=dxvk, graphics=wayland); only `save` is game-specific.
{
  # Save: Stellaris (Clausewitz) writes saves, settings, and mods under
  # Documents\Paradox Interactive\Stellaris (save games in the `save games/` subfolder). Bound to the
  # app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/stellaris).
  mounts."drive_c/users/propnix/Documents/Paradox Interactive/Stellaris" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
