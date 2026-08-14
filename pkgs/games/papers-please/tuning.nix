# Papers, Please — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this
# states only what is SPECIFIC to Papers, Please. Well-behaved on the global defaults (d3d=dxvk,
# graphics=wayland): the 1.4.x GOG build is a Unity (IL2CPP) title that renders D3D11 → DXVK → Vulkan at
# a steady 30 fps (its own frame cap), so only `save` is game-specific.
{
  # Force fullscreen via Unity's persisted PlayerPref (re-applied to HKCU every launch by the launcher, so
  # it always wins on startup). WHY the registry and not a `-screen-fullscreen 1` exe arg: the CLI arg is
  # applied at startup but the game's own saved setting then overrides it, so a fullscreen window flashes and
  # drops back to windowed — setting the pref itself leaves nothing to revert to. WHY fullscreen matters: on
  # a fractionally-scaled winewayland output, a WINDOWED Unity app renders its backbuffer at the LOGICAL size
  # while the window is shown at physical size, confining the in-game (Unity-drawn) cursor to the upper-left
  # ~1/scale of the window (the wine hardware cursor is unaffected); fullscreen makes the render target the
  # whole output, so input maps across the entire screen.
  #
  # Unity stores PlayerPrefs in HKCU\Software\<company>\<product> with a per-key hash suffix; "Screenmanager
  # Fullscreen mode" = the Unity FullScreenMode enum, value 1 = FullScreenWindow (borderless fullscreen).
  # No resolution keys are set → Unity uses the native desktop resolution, keeping this host-agnostic.
  userReg."Software\\3909\\PapersPlease"."Screenmanager Fullscreen mode_h3630240806" = {
    value = "1";
    type = "REG_DWORD";
    reason = "FullScreenWindow (1): a windowed Unity app on fractional-scale winewayland confines the in-game cursor to ~1/scale of the window; fullscreen fixes it. Set via the pref (not -screen-fullscreen) so the game doesn't revert it to windowed.";
  };

  # Save: the game logs its own save dir on launch —
  #   [Game] Save dir: C:\users\<user>\AppData\Roaming\3909\PapersPlease
  # and writes settings.sav + its save games there. (Despite being a Unity port, saves go to the classic
  # Roaming\3909 path for compatibility with the original engine, NOT Unity's LocalLow persistentDataPath,
  # which only receives Player.log.) Bound to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID,
  # default $XDG_DATA_HOME/propnix-saves/papers-please).
  mounts."drive_c/users/propnix/AppData/Roaming/3909/PapersPlease" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
