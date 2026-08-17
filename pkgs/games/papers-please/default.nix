# Papers, Please (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. ARCH-AGNOSTIC: identical on both hosts; the wine builder + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. Papers, Please (1.4.x GOG) is a Unity IL2CPP title (GameAssembly.dll + UnityPlayer.dll,
# rendering D3D11 → DXVK → Vulkan at a steady 30 fps, its own frame cap; NOT the original custom engine,
# and NOT Mono — so no managed-assembly overlay issue). Payload = the pinned GOG Galaxy build fetched
# with gogdl (D15), the game tree directly. Well-behaved on the global wine defaults; only the Unity
# fullscreen pref (the preset) and the save location are game-specific.
#
#   nix run .#papers-please --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "papers-please";
  appid = "papers-please";
  name = "Papers, Please";
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "PapersPlease.exe";
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  icon.symbolic = ./papers-please-symbolic.svg;

  # Save: the game logs its own save dir on launch —
  #   [Game] Save dir: C:\users\<user>\AppData\Roaming\3909\PapersPlease
  # and writes settings.sav + its save games there. (Despite being a Unity port, saves go to the classic
  # Roaming\3909 path for compatibility with the original engine, NOT Unity's LocalLow persistentDataPath,
  # which only receives Player.log.) Bound to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID,
  # default $XDG_DATA_HOME/propnix-saves/papers-please).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Roaming/3909/PapersPlease";
    }
  ];

  # The Unity fullscreen PlayerPref (winewayland fractional-scale cursor confinement fix; see the preset —
  # the pref, not a `-screen-fullscreen` exe arg, because the game's own persisted setting overrides the arg).
  wine = presets.unity.fullscreen "Software\\3909\\PapersPlease";
}
