# Hollow Knight — per-title tuning. Layered over lib/winefex-defaults.nix (sealing.mergeTuning), so this
# states only what is SPECIFIC to Hollow Knight. HK is well-behaved on the global defaults
# (d3d=dxvk, graphics=wayland, the mono/gecko/menubuilder DLL hygiene), so nothing is overridden here —
# only `save` is game-specific. To change a default for HK alone, add the knob here, e.g.
#   graphics = { value = "x11"; reason = "…"; };                 # scalar knob: replaces the global
#   dllOverrides.d3d11 = { value = "b"; reason = "…"; };         # per-DLL: merges into the global map
{
  # Save location: SHARE Unity's persistentDataPath with a native Linux build. userN.dat are
  # engine-serialized + platform-independent, so the save game carries across; PlayerPrefs
  # (keybinds/resolution) do NOT (Windows registry vs. Linux file). Bound out of the rebuildable prefix.
  # PROPNIX_SAVE_DIR overrides the root, namespaced per app ($PROPNIX_SAVE_DIR/hollow-knight).
  save = {
    guestRel = "AppData/LocalLow/Team Cherry/Hollow Knight";
    hostDefault = "$HOME/.config/unity3d/Team Cherry/Hollow Knight";
  };
}
