# Papers, Please (GOG, Windows build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on
# x86_64 natively. ARCH-AGNOSTIC: identical on both hosts; the wine builder + the scope pick the
# arch-appropriate emulator set, and the SAME Windows payload (a content-addressed FOD) is shared across
# arches. Papers, Please (1.4.x GOG) is a Unity IL2CPP title (GameAssembly.dll + UnityPlayer.dll,
# rendering D3D11 → DXVK → Vulkan at a steady 30 fps, its own frame cap; NOT the original custom engine,
# and NOT Mono — so no managed-assembly overlay issue). Payload = the pinned GOG Galaxy build fetched
# with fetchGogGalaxyBuild (D15), the game tree directly. Well-behaved on the global wine defaults; only the Unity
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
  maintainers = [ "waltmck" ];
  appid = "papers-please";
  name = "Papers, Please";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
  # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
  # because this game is single-player; the exe links no socket library at all.
  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "PapersPlease.exe";
  # Art-led title: gamescope enlarges a smaller image by whole multiples only, so the art stays crisp.
  gamescope.scaler = "integer";
  # Pixel art: enlarge with hard pixel edges, not FSR's smoothing.
  gamescope.filter = "nearest";
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  icon.symbolic = ./papers-please-symbolic.svg;

  # Save + settings: the game logs its save dir on launch (`[Game] Save dir:
  # C:\users\<user>\AppData\Roaming\3909\PapersPlease`) and writes its saves AND `settings.sav`
  # there: the original engine's path, not Unity's LocalLow persistentDataPath (Player.log only).
  # Progress belongs in the save dir a user carries between machines; `settings.sav` holds the
  # display mode (without it the game starts windowed), which is per-MACHINE state, so a
  # `type = "file"` row routes that one file to $PROPNIX_STATE (the factorio shape; an overlay has
  # one upper and cannot split writes by filename). `type = "file"` also makes `create` touch the
  # source instead of mkdir'ing it; the game rewrites the file wholesale when the options screen
  # closes, so a zero-byte file on first launch reads as "no settings yet".
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Roaming/3909/PapersPlease";
    }
    {
      src = "$PROPNIX_STATE/settings.sav";
      dst = "AppData/Roaming/3909/PapersPlease/settings.sav";
      type = "file";
    }
  ];

  # ── Starting fullscreen needs both rows below. The Unity pref selects fullscreen (an exe arg
  # `-screen-fullscreen` does not: the game applies its own setting afterwards); winewayland places
  # this title's physical-size fullscreen request off-screen on a fractionally scaled output, while
  # Xwayland honours it. `settings.sav` is encrypted, so no setupScript can seed it. Geometry and
  # the test matrix: docs/research/winewayland-fractional-scaling.md.
  wine = presets.mergeTuning [
    (presets.unity.fullscreen "Software\\3909\\PapersPlease")
    {
      graphics = {
        value = "x11";
        reason = "winewayland places this Unity title's fullscreen window off-screen on fractional scaling; Xwayland is correct.";
      };
    }
  ];
}
