# Don't Starve — per-title tuning. Layered over lib/wine-defaults.nix (sealing.mergeTuning), so this
# states only what is SPECIFIC to Don't Starve. Klei's custom C++/Lua engine; the Windows build renders
# through its bundled ANGLE (libEGL.dll/libGLESv2.dll) → Direct3D 9. 32-bit i386 process (no 64-bit binary).
{
  # d3d = wined3d (NOT the default native ARM64EC DXVK). The game is a 32-bit (i386) process running under
  # wine WoW64 + FEX (libwow64fex.dll); its bundled ANGLE calls Direct3D 9 IN-PROCESS, so the d3d9 that
  # services it must ALSO be 32-bit. propnix's native ARM64EC DXVK is a 64-bit PE and cannot be loaded into a
  # 32-bit process, so DXVK is unavailable here — wine's builtin wined3d (which has an i386 build, archs
  # include i386) is the only D3D→GPU path. wined3d's default GL renderer measures well on this host.
  d3d = {
    value = "wined3d";
    reason = "32-bit (i386) process: its bundled ANGLE calls Direct3D 9 in-process, so d3d9 must be 32-bit too, but propnix's native ARM64EC DXVK is a 64-bit PE that a WoW64 process cannot load — wine's builtin wined3d (i386) is the only D3D path.";
  };

  # Save: the GOG install script (goggame-1207659210.script → savePath "{userdocs}/Klei/DoNotStarve")
  # redirects saves to Documents\Klei\DoNotStarve. Bind the whole folder (saves + settings.ini together) out
  # to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/dont-starve).
  mounts."drive_c/users/propnix/Documents/Klei/DoNotStarve" = {
    source = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    createIfNotExist = true;
  };
}
