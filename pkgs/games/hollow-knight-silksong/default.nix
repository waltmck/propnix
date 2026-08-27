# Hollow Knight: Silksong (GOG, Windows x86_64 build) via wine — on aarch64 through FEX + native ARM64EC
# DXVK, on x86_64 natively. Team Cherry's Unity sequel to Hollow Knight; ARCH-AGNOSTIC like the HK spec:
# mkApp + the scope pick the arch-appropriate emulator set, and the SAME Windows payload (a
# content-addressed FOD) is shared across arches. Payload = the pinned GOG Galaxy build fetched by fetchGogGalaxyBuild
# (D15), delivered as the game tree directly (no InnoSetup).
#
# Well-behaved on the global wine defaults (d3d=dxvk, graphics=wayland, DLL hygiene) — the only per-title
# tuning is the Unity frame-pacing preset (Silksong persists the SAME `VidVSync`/`VidTFR` PlayerPrefs as
# Hollow Knight — verified: identical `_h<hash>` value names, the hash is a pure function of the pref name —
# under its own HKCU key), so the fragment is passed directly and there is no wine-tuning.nix.
#
#   nix run .#hollow-knight-silksong --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64/x86_64-linux
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "hollow-knight-silksong";
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

  wine = presets.unity.framePacing "Software\\Team Cherry\\Hollow Knight Silksong";
}
