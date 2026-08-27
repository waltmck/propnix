# Don't Starve (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Klei's custom C++/Lua engine (renders via OpenGL/D3D). ARCH-AGNOSTIC: the same spec runs on
# both hosts; the wine backend + the scope pick the arch-appropriate emulator set, and the SAME Windows
# payload (a content-addressed FOD) is shared across arches. Payload = the pinned GOG Galaxy build fetched
# with fetchGogGalaxyBuild (D15), delivered as the game tree directly (no InnoSetup).
#
#   nix run .#dont-starve --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  mkSetupScript,
}:
mkApp {
  pname = "dont-starve";
  appid = "dont-starve";
  name = "Don't Starve";
  # GOG-Windows, 32-bit (i386): this build ships NO 64-bit binary (only bin/, no bin64/), so it runs via wine
  # WoW64 on aarch64 — box64's wowbox64.dll, Hangover's hardcoded default i386 emulator (FEX's libwow64fex.dll
  # is the staged alternative; see wine-prefix-lower.nix). i386-windows also selects the platform-default
  # d3d = wined3d (the game's bundled ANGLE calls Direct3D 9 in-process, so the servicing d3d9 must be 32-bit
  # too; wined3d's default GL renderer measures well on this host).
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  # The goggame-1207659210.info isPrimary FileTask: bin/dontstarve.exe. The real game binary (not a stub).
  exe = "bin/dontstarve.exe";
  # Klei's engine resolves its data root from the CWD (not the exe path) and expects cwd = the exe's own dir,
  # finding assets at ..\data — the goggame workingDir "bin". Without this the default cwd (C:\game root) makes
  # it look for ..\data = C:\data and it dies at startup (`Missing Shader 'shaders/font.ksh'` — verified).
  workingDir = "bin";
  # Save: the GOG install script (goggame-1207659210.script → savePath "{userdocs}/Klei/DoNotStarve")
  # redirects saves to Documents\Klei\DoNotStarve. Bind the whole folder (saves + settings.ini together) out
  # to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default …/propnix-saves/dont-starve).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/Klei/DoNotStarve";
    }
  ];
  # Run setup.sh before wine: force `[graphics] fullscreen = true` in Klei's settings.ini so the game starts
  # fullscreen (its default is windowed). Klei keeps this in settings.ini, NOT the registry, so a `userReg`
  # entry cannot express it (see setup.sh). ini-lib's `ini_set` does the edit (Klei's INI dialect is set at
  # the top of setup.sh: CRLF, `key = value` spacing, `;`-comment skip).
  setupScript = mkSetupScript {
    name = "dont-starve-setup";
    script = ./setup.sh;
    withIniLib = true;
  };
}
