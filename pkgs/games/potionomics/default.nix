# Potionomics (Steam, Windows build) via wine.
# Voracious Games' UE4 potion-shop deck-builder; single x86_64-windows depot.
#
#   nix run .#potionomics --extra-sandbox-paths /propnix=/var/lib/propnix
{
  lib,
  mkApp,
}:
mkApp {
  pname = "potionomics";
  appid = "potionomics";
  name = "Potionomics";

  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "Potionomics/Binaries/Win64/Potionomics-Win64-Shipping.exe";

  # The single shipped Steamworks copy (engine-side, UE4 OnlineSubsystemSteam layout; SDK 1.51 — within
  # the gbe_fork pin, 1.64). gbe_fork union-replaces it with the entitlement settings beside it.
  steam.emu.libPaths = [
    "Engine/Binaries/ThirdParty/Steamworks/Steamv151/Win64/steam_api64.dll"
  ];

  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Local/Potionomics/Saved";
    }
  ];
}
