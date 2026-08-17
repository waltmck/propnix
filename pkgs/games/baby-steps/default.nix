# Baby Steps (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. ARCH-AGNOSTIC: identical on both hosts; the wine builder + the scope pick the arch-appropriate
# emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across arches. Payload =
# the pinned GOG Galaxy build fetched with gogdl (D15), the game tree directly (no InnoSetup).
#
# Well-behaved on the global wine defaults (d3d=dxvk, graphics=wayland): Baby Steps is a Unity IL2CPP
# title (UnityPlayer.dll + GameAssembly.dll, NO Managed/ dir — native IL2CPP, NOT Mono, so none of the
# KSP managed-assembly overlay issue) that renders D3D11 → DXVK → Vulkan. Only the Unity fullscreen
# pref (the preset) and the save location are game-specific.
#
#   nix run .#baby-steps --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "baby-steps";
  appid = "baby-steps";
  name = "Baby Steps";
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "BabySteps.exe";

  # Save: Unity's Application.persistentDataPath = %USERPROFILE%\AppData\LocalLow\<company>\<product> =
  # AppData\LocalLow\DefaultCompany\BabySteps (company/product from BabySteps_Data/app.info). The IL2CPP
  # build writes its save data (and Player.log) there. Bound to the app's host save dir
  # ($PROPNIX_SAVE_DIR/$PROPNIX_APPID, default $XDG_DATA_HOME/propnix-saves/baby-steps).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/DefaultCompany/BabySteps";
    }
  ];

  # The Unity fullscreen PlayerPref (winewayland fractional-scale cursor confinement fix; see the preset).
  wine = presets.unity.fullscreen "Software\\DefaultCompany\\BabySteps";
}
