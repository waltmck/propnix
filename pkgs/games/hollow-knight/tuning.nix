# Hollow Knight — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this
# states only what is SPECIFIC to Hollow Knight. HK is well-behaved on the global defaults
# (d3d=dxvk, graphics=wayland, the mono/gecko/menubuilder DLL hygiene), so nothing is overridden here —
# only `save` is game-specific. To change a default for HK alone, add the knob here, e.g.
#   graphics = { value = "x11"; reason = "…"; };                 # scalar knob: replaces the global
#   dllOverrides.d3d11 = { value = "b"; reason = "…"; };         # per-DLL: merges into the global map
{
  # Save: HK's Unity persistentDataPath, bound out of the rebuildable prefix to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/hollow-knight).
  mounts."drive_c/users/propnix/AppData/LocalLow/Team Cherry/Hollow Knight" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };

  # Frame pacing: make HK's own engine settings agree with the DXVK layer (env.rs) so the two don't fight.
  # HK stores these as Unity PlayerPrefs under HKCU\Software\Team Cherry\Hollow Knight (value names carry
  # Unity's deterministic `_h<hash>` suffix): `VidVSync` (0/1) and `VidTFR` (target frame rate, literal fps).
  #   Fixed (PROPNIX_FPS>0): DXVK caps + forces vsync OFF → HK vsync OFF (else Unity paces to vblank and
  #   fights the cap) and HK's target frame rate = the cap.
  fpsUserReg."Software\\Team Cherry\\Hollow Knight"."VidVSync_h382800143" = {
    value = "0";
    type = "REG_DWORD";
    reason = "Fixed FPS: disable HK's engine vsync so the DXVK frame cap (DXVK_FRAME_RATE) paces, not Unity vblank sync.";
  };
  fpsUserReg."Software\\Team Cherry\\Hollow Knight"."VidTFR_h3151569246" = {
    value = "$PROPNIX_FPS";
    type = "REG_DWORD";
    reason = "Fixed FPS: set HK's target frame rate to the cap so the engine target agrees with DXVK.";
  };
  #   VRR (PROPNIX_FPS=0): DXVK forces vsync ON, uncapped → enable HK's engine vsync so it presents FIFO and
  #   the display's variable refresh follows it.
  vsyncUserReg."Software\\Team Cherry\\Hollow Knight"."VidVSync_h382800143" = {
    value = "1";
    type = "REG_DWORD";
    reason = "VRR (PROPNIX_FPS=0): enable HK's engine vsync so it presents FIFO and the display's variable refresh follows.";
  };
}
