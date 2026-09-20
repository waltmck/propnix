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
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  icon.symbolic = ./papers-please-symbolic.svg;

  # Save + settings: the game logs its own dir on launch —
  #   [Game] Save dir: C:\users\<user>\AppData\Roaming\3909\PapersPlease
  # and writes BOTH its save games AND `settings.sav` there. (Despite being a Unity port, it uses the
  # classic Roaming\3909 path for compatibility with the original engine, NOT Unity's LocalLow
  # persistentDataPath, which only receives Player.log.)
  #
  # THE TWO ARE ROUTED APART, because they are not the same kind of data: progress belongs in the save dir
  # a user backs up and carries between machines, while `settings.sav` is per-MACHINE state — it holds the
  # display mode (measured: deleting it resets the game to its windowed default) and so, almost certainly,
  # the rest of the options screen. Routing it to $PROPNIX_STATE is the factorio shape: a `type = "file"`
  # row redirects ONE file out of a directory that is itself bound, which an overlay cannot do (an overlay
  # has a single upper, so it cannot split writes by filename).
  #
  # `type = "file"` also makes `create` TOUCH the source rather than mkdir it — a directory at that path
  # would make the game's open() fail obscurely. The game rewrites the file wholesale when the options
  # screen is closed, so a zero-byte file on first launch just reads as "no settings yet".
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

  # ── STARTING FULLSCREEN NEEDS BOTH OF THESE, and each was measured on a FRESH profile (no settings.sav,
  # so the game falls back to its own defaults — which is what a new user gets):
  #
  #   pref only, winewayland  size=[2560,1665] at=[-480,-295] fullscreen=0   ← oversized, off-screen
  #   pref only + x11         size=[1600,1040] at=[0,0]       fullscreen=2   ← correct
  #   pref=Windowed(3) + x11  size=[1600,1005] at=[0,35]      fullscreen=1   ← the pref really does decide
  #
  # THE PREF decides the mode: Unity's FullScreenWindow (1) vs Windowed (3) changes the result under x11,
  # so this is not an inert knob. `-screen-fullscreen 1` as an exe arg does NOT work (measured: byte-for-
  # byte the same broken geometry as no arg) — the game applies its own setting afterwards.
  #
  # THE DISPLAY DRIVER decides whether that mode is honoured correctly. Under winewayland the game asks for
  # a borderless window the size of the PHYSICAL desktop (2560x1664) and fractional scaling then places it
  # as a 2560x1665 LOGICAL window on a 1600x1040 screen — hanging off the top-left corner. Under Xwayland
  # the same request lands as a true fullscreen window. Same class of winewayland fractional-scale fault
  # that pins skyrim-se to x11, different symptom.
  #
  # Not a `setupScript`: `settings.sav` is a 316-byte ENCRYPTED blob (hex-encoded, no single-byte XOR, ~no
  # printable structure), so no script can seed a display mode into it. The pref + x11 reach the same end
  # without inventing a file format.
  wine = presets.mergeTuning [
    (presets.unity.fullscreen "Software\\3909\\PapersPlease")
    {
      graphics = {
        value = "x11";
        reason = "winewayland maps this Unity title's fullscreen request at the PHYSICAL desktop size onto a fractionally-scaled output, producing a 2560x1665 logical window at [-480,-295]; under Xwayland the same request is a correct 1600x1040 fullscreen window (both measured on a fresh profile).";
      };
    }
  ];
}
