# Casualties: Unknown Demo (Steam, Windows build) via wine.
# single x86_64-windows depot.
#
#   nix run .#casualties-unknown-demo --extra-sandbox-paths /propnix=/var/lib/propnix
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "casualties-unknown-demo";
  appid = "casualties-unknown-demo";
  name = "Casualties: Unknown Demo";

  # demo is single-player survival.
  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "CasualtiesUnknown.exe";

  # The demo build ships NO Steam SDK at all — no steam_api(64).dll
  steam.emu.enable = false;

  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/Orsoniks/CasualtiesUnknown";
    }
  ];

  # Unity frame pacing
  wine = presets.unity.framePacing "Software\\Orsoniks\\CasualtiesUnknown";
}
