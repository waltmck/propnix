# R.E.P.O. (semiwork) — the Steam WINDOWS build via wine: on aarch64 through FEX + ARM64EC DXVK, on
# x86_64 natively. Unity **2022.3.67f2** (version string in UnityPlayer.dll), Mono scripting backend
# (`MonoBleedingEdge/` + a 143-assembly `REPO_Data/Managed/`, not IL2CPP), Addressables content in
# `REPO_Data/StreamingAssets/aa/StandaloneWindows64`.
#
# Steam-only, Windows-only, ONE depot: app 3241660 ships exactly `3241661` on the public branch,
# with no macOS or Linux depot and no DLC depot at all (Steam appinfo). So `platformPreference`
# derives itself, `dlc` is absent rather than empty-by-omission, and any other selection is a
# legible mkApp error.
#
#   nix run .#repo --extra-sandbox-paths /propnix=/var/lib/propnix
#
# Verified render (main menu): docs/verified/repo-win.json. No per-title workaround row is needed.
{
  lib,
  mkApp,
  presets,
}:
mkApp {
  pname = "repo";
  maintainers = [ "waltmck" ];
  appid = "repo";
  name = "R.E.P.O.";

  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

  # The sole Steam launch entry, a stock Unity player stub. Unity resolves `REPO_Data/` from the
  # exe's directory, so `workingDir` stays null.
  exe = "REPO.exe";
  # Full-color icon auto-extracted from the exe's PE resources (icon.auto default).

  # Unity 2022.3 (the player's version string, above), Mono scripting backend: on aarch64 the stream's
  # ARM64EC Mono runtime (emulators/unity-mono) replaces the shipped x64 one in the game dir, so the
  # game's C# is JIT-compiled to native ARM64 rather than emulated (lib/modules/unity-mono.nix).
  unity.mono.stream = "2022.3";

  # `online` stays at its default (true): a co-op game built on Photon (a hosted relay plus voice
  # chat), so a netns would remove the game. `.apply { online = false; }` gives a single-player,
  # kernel-enforced-offline run. steam.emu answers the Steam lobby calls locally, so whether
  # host/join falls back to Photon-only is untested.

  # steam.emu replaces the Unity plugin at its only copy, REPO_Data/Plugins/x86_64/steam_api64.dll
  # (wrapped by Facepunch.Steamworks); required on wine, where mk-app.nix refuses a steam.emu with
  # no `.dll` path. Shim export coverage: docs/research/galaxy-sdk-offline.md (gbe_fork section).
  steam.emu.libPaths = [ "REPO_Data/Plugins/x86_64/steam_api64.dll" ];

  # Save: Unity's persistentDataPath, LocalLow/<companyName>/<productName> = semiwork/REPO, with the
  # casing REPO_Data/app.info gives. Player.log lands here too.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/LocalLow/semiwork/REPO";
    }
  ];

  # The Unity fullscreen PlayerPref, for the winewayland fractional-scale cursor confinement (see
  # the preset). The pref name is live in this player; the key comes from the same app.info pair.
  # Set by default because mouse-look with a confined cursor is unplayable; the confinement itself
  # is unconfirmed on this title.
  #
  # No `presets.unity.framePacing`: it writes Hollow Knight's own VidVSync/VidTFR prefs, which this
  # title does not have, so the rows would be inert (docs/research/unity-player-facts.md).
  wine = presets.unity.fullscreen "Software\\semiwork\\REPO";

  # No `<Data>/Managed` tmpfs (iron-lung/KSP): this player loads its assemblies off the multi-lower
  # read-only overlay (docs/research/unity-player-facts.md).
}
