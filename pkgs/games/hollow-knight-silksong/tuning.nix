# Hollow Knight: Silksong — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning),
# so this states only what is SPECIFIC to Silksong. Like Hollow Knight, this is a Team Cherry Unity title,
# expected to be well-behaved on the global defaults (d3d=dxvk, graphics=wayland, DLL hygiene) — only
# `save` is game-specific. To change a default for Silksong alone, add the knob here, e.g.
#   graphics = { value = "x11"; reason = "…"; };                 # scalar knob: replaces the global
#   dllOverrides.d3d11 = { value = "b"; reason = "…"; };         # per-DLL: merges into the global map
{
  # Save: Unity persistentDataPath (Company/Product from the payload's goggame-*.info: "Team Cherry" /
  # "Hollow Knight Silksong"), bound to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID,
  # default $XDG_DATA_HOME/propnix-saves/hollow-knight-silksong).
  mounts."drive_c/users/propnix/AppData/LocalLow/Team Cherry/Hollow Knight Silksong" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };

  # Frame pacing: make Silksong's own engine settings agree with the DXVK layer (env.rs) so the two don't
  # fight. Silksong stores the SAME Unity PlayerPrefs as Hollow Knight (verified: identical `_h<hash>` value
  # names — the hash is a pure function of the key string, game-independent), under HKCU\Software\Team
  # Cherry\Hollow Knight Silksong: `VidVSync` (0/1) and `VidTFR` (target frame rate, literal fps).
  #   Fixed (PROPNIX_FPS>0): DXVK caps + forces vsync OFF → Silksong vsync OFF (else Unity paces to vblank and
  #   fights the cap) and its target frame rate = the cap.
  fpsUserReg."Software\\Team Cherry\\Hollow Knight Silksong"."VidVSync_h382800143" = {
    value = "0";
    type = "REG_DWORD";
    reason = "Fixed FPS: disable Silksong's engine vsync so the DXVK frame cap (DXVK_FRAME_RATE) paces, not Unity vblank sync.";
  };
  fpsUserReg."Software\\Team Cherry\\Hollow Knight Silksong"."VidTFR_h3151569246" = {
    value = "$PROPNIX_FPS";
    type = "REG_DWORD";
    reason = "Fixed FPS: set Silksong's target frame rate to the cap so the engine target agrees with DXVK.";
  };
  #   VRR (PROPNIX_FPS=0): DXVK forces vsync ON, uncapped → enable Silksong's engine vsync so it presents FIFO
  #   and the display's variable refresh follows it.
  vsyncUserReg."Software\\Team Cherry\\Hollow Knight Silksong"."VidVSync_h382800143" = {
    value = "1";
    type = "REG_DWORD";
    reason = "VRR (PROPNIX_FPS=0): enable Silksong's engine vsync so it presents FIFO and the display's variable refresh follows.";
  };
}
