# Hollow Knight: Silksong (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC
# DXVK, on x86_64 natively. Team Cherry's Unity sequel to Hollow Knight; ARCH-AGNOSTIC like the HK spec:
# mkApp + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild
# (D15), delivered as the game tree directly (no InnoSetup).
#
# Well-behaved on the global wine defaults (d3d=dxvk, graphics=wayland, DLL hygiene) — the per-title tuning
# is the Unity frame-pacing preset (Silksong persists the SAME `VidVSync`/`VidTFR` PlayerPrefs as Hollow
# Knight — verified: identical `_h<hash>` value names, the hash is a pure function of the pref name — under
# its own HKCU key), so the fragment is passed directly and there is no wine-tuning.nix; the other per-title
# items are the Galaxy stub rows and the Unity stream declaration below. Nothing here works around the old
# loading-screen hang: that was the shared wine defaults' read-only `dosdevices` bind, fixed in
# lib/backends/wine/defaults.nix.
#
#   nix run .#hollow-knight-silksong --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64/x86_64-linux
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "hollow-knight-silksong";
  maintainers = [ "waltmck" ];
  appid = "hollow-knight-silksong";
  name = "Hollow Knight: Silksong";

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE for the game, so propnix's offline
  # guarantee is enforced by the kernel rather than by trusting the title and its bundled SDKs. Safe here
  # because this game is single-player like its predecessor; the exe links no socket library at all.
  online = false;
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;
  exe = "Hollow Knight Silksong.exe";
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default). Symbolic vendored (CC BY-SA 4.0).
  icon.symbolic = ./hollow-knight-silksong-symbolic.svg;

  # Save: Unity persistentDataPath (Company/Product from the payload's goggame-*.info: "Team Cherry" /
  # "Hollow Knight Silksong"), bound to the app's host save dir ($PROPNIX_SAVE_DIR/$PROPNIX_APPID,
  # default $XDG_DATA_HOME/propnix-saves/hollow-knight-silksong).
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/Team Cherry/Hollow Knight Silksong";
    }
  ];

  # ── De-Galaxy: the no-op stub (`wine.galaxyStubDlls`, below) is bound over both shipped copies of the
  # native SDK, exactly as Hollow Knight's GOG build does. The game's DesktopPlatform still selects the GOG
  # online subsystem (its probe is the existence of `Plugins/x86_64/GalaxyCSharpGlue.dll`), the stub
  # answers Init with a single OnAuthFailure, and the boot gate clears — the same clean failure the real
  # SDK reports with no network. Nothing is masked: a whiteout cannot sit in a multi-lower game dir (the
  # `maskFiles` docs), and the ARM64EC Mono runtime below arrives as an extra lower. The IL reading behind
  # the probe, the measured boots with the SDK live, and the mount-table hang this title was once blamed
  # for are in docs/research/silksong-galaxy-and-boot.md.

  # Unity 6 (player 6000.0.50f1, a Unity-internal branch build), Mono scripting backend: on aarch64 the
  # stream's ARM64EC Mono runtime (emulators/unity-mono) replaces the shipped x64 one in the game dir, as
  # for Hollow Knight (lib/modules/unity-mono.nix).
  unity.mono.stream = "6000.0";

  wine = lib.mkMerge [
    (presets.unity.framePacing "Software\\Team Cherry\\Hollow Knight Silksong")
    {
      # Both shipped copies of the native SDK: the plugin path the C# glue loads, and the root-level copy
      # beside the exe that the OS loader would otherwise find.
      galaxyStubDlls = [
        "Hollow Knight Silksong_Data/Plugins/x86_64/Galaxy64.dll"
        "Galaxy64.dll"
      ];
    }
  ];
}
