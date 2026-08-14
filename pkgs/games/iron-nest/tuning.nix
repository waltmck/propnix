# IRON NEST: Heavy Turret Simulator — per-title tuning. Layered over lib/wine-defaults.nix
# (sealing.mergeTuning), so this states only what is SPECIFIC to the game. It is well-behaved on the global
# defaults (d3d=dxvk, graphics=wayland): a Unity IL2CPP title that renders Direct3D → DXVK/vkd3d → Vulkan, so
# only fullscreen + save are game-specific.
{
  # Force borderless fullscreen via Unity's persisted PlayerPref (re-applied to HKCU every launch by the
  # launcher, so it always wins on startup). WHY the registry and not a `-screen-fullscreen 1` exe arg: the
  # CLI arg is applied at startup but the game's own saved setting then overrides it, so a fullscreen window
  # flashes and drops back to windowed — setting the pref itself leaves nothing to revert to. WHY fullscreen
  # matters: on a fractionally-scaled winewayland output a WINDOWED Unity app renders its backbuffer at the
  # LOGICAL size while the window is shown at physical size, confining the in-game (Unity-drawn) cursor to the
  # upper-left ~1/scale of the window; fullscreen makes the render target the whole output, so input maps
  # across the entire screen. (Same rationale and fix as Papers, Please.)
  #
  # Unity stores PlayerPrefs in HKCU\Software\<company>\<product> — here Software\Iron Nest\Iron Nest Heavy
  # Turret Simulator (company/product from _Data/app.info) — with a per-key hash suffix computed from the key
  # NAME only, so "Screenmanager Fullscreen mode_h3630240806" is the same suffix for every Unity title. Value
  # 1 = the Unity FullScreenMode enum FullScreenWindow (borderless fullscreen). No resolution keys are set →
  # Unity uses the native desktop resolution, keeping this host-agnostic.
  userReg."Software\\Iron Nest\\Iron Nest Heavy Turret Simulator"."Screenmanager Fullscreen mode_h3630240806" = {
    value = "1";
    type = "REG_DWORD";
    reason = "FullScreenWindow (1): a windowed Unity app on fractional-scale winewayland confines the in-game cursor to ~1/scale of the window; fullscreen fixes it. Set via the pref (not -screen-fullscreen) so the game doesn't revert it to windowed.";
  };

  # Save: an IL2CPP Unity title (GameAssembly.dll calls UnityEngine.Application.get_persistentDataPath and
  # serialises with Newtonsoft.Json), so saves + settings land in Unity's persistentDataPath =
  # %USERPROFILE%\AppData\LocalLow\<company>\<product> = AppData\LocalLow\Iron Nest\Iron Nest Heavy Turret
  # Simulator (company/product from _Data/app.info). Bound to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/iron-nest).
  mounts."drive_c/users/propnix/AppData/LocalLow/Iron Nest/Iron Nest Heavy Turret Simulator" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
