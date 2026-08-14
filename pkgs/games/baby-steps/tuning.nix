# Baby Steps — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this states
# only what is SPECIFIC to Baby Steps. Well-behaved on the global defaults (d3d=dxvk, graphics=wayland):
# Baby Steps is a Unity IL2CPP title (UnityPlayer.dll + GameAssembly.dll, NO Managed/ dir — native IL2CPP,
# NOT Mono, so none of the KSP managed-assembly overlay issue) that renders D3D11 → DXVK → Vulkan. Only the
# Unity fullscreen pref and the save location are game-specific.
{
  # Force fullscreen via Unity's persisted PlayerPref (re-applied to HKCU every launch by the launcher, so it
  # always wins on startup). WHY the registry and not a `-screen-fullscreen 1` exe arg: the CLI arg is applied
  # at startup but the game's own saved setting then overrides it, so a fullscreen window flashes and drops
  # back to windowed — setting the pref itself leaves nothing to revert to. WHY fullscreen matters: on a
  # fractionally-scaled winewayland output, a WINDOWED Unity app renders its backbuffer at the LOGICAL size
  # while the window is shown at physical size, confining the in-game (Unity-drawn) cursor to the upper-left
  # ~1/scale of the window (the wine hardware cursor is unaffected); fullscreen makes the render target the
  # whole output, so input maps across the entire screen. This is the general winewayland Unity behaviour
  # (same fix as Papers, Please).
  #
  # Unity stores PlayerPrefs in HKCU\Software\<company>\<product> with a per-key hash suffix; the company/
  # product for this build are DefaultCompany/BabySteps (BabySteps_Data/app.info). "Screenmanager Fullscreen
  # mode" hashes to the Unity-standard _h3630240806 suffix (the hash is of the key STRING, so it is identical
  # across all Unity titles); value 1 = the Unity FullScreenMode enum FullScreenWindow (borderless fullscreen).
  # No resolution keys are set → Unity uses the native desktop resolution, keeping this host-agnostic.
  userReg."Software\\DefaultCompany\\BabySteps"."Screenmanager Fullscreen mode_h3630240806" = {
    value = "1";
    type = "REG_DWORD";
    reason = "FullScreenWindow (1): a windowed Unity app on fractional-scale winewayland confines the in-game cursor to ~1/scale of the window; fullscreen fixes it. Set via the pref (not -screen-fullscreen) so the game doesn't revert it to windowed.";
  };

  # Save: Unity's Application.persistentDataPath = %USERPROFILE%\AppData\LocalLow\<company>\<product> =
  # AppData\LocalLow\DefaultCompany\BabySteps (company/product from BabySteps_Data/app.info). The IL2CPP
  # build writes its save data (and Player.log) there. Bound to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/baby-steps).
  mounts."drive_c/users/propnix/AppData/LocalLow/DefaultCompany/BabySteps" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
