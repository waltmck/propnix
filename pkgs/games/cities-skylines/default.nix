# Cities: Skylines (Colossal Order / Paradox) — the Steam WINDOWS build via wine: on aarch64 through
# FEX + ARM64EC DXVK, on x86_64 natively. Unity **5.6.7f1** (read out of Cities.exe's version
# string), D3D11 renderer — the exe carries the whole `d3d11: …` diagnostic string table, so DXVK is
# the d3d layer that actually runs; the statically-imported OPENGL32.dll is Unity 5's
# `-force-opengl` fallback path, not the default.
#
# Steam-only, Windows-only: the fetch matrix has exactly that pair, so `platformPreference` derives
# itself and any other selection is a legible mkApp error. Steam also ships macOS/Linux depots
# (255712/255713) of this build. Unpinned: the Linux one is untested.
#
#   nix run .#cities-skylines --extra-sandbox-paths /propnix=/var/lib/propnix
#   nix run '.#cities-skylines.withAllDlc'
#
# Launch Cities.exe directly (Steam's `baseline` launch option). dowser.exe only installs and runs
# the Paradox Launcher MSI, whose launcher-settings.json just names Cities.exe
# (docs/research/publisher-launcher-bypass.md). Unity resolves Cities_Data/ beside the exe and
# Files/ sits beside it, so workingDir stays null. Run record:
# docs/verified/cities-skylines-win.json.
{
  lib,
  mkApp,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp {
  pname = "cities-skylines";
  maintainers = [ "waltmck" ];
  appid = "cities-skylines";
  name = "Cities: Skylines";

  fetchInfo = versions.fetchInfo;

  exe = "Cities.exe";

  # `-logfile` (lowercase, as Cities.exe's argv table spells it) redirects the Unity log, whose
  # default `Cities_Data/output_log.txt` is in the read-only game dir, into the save bind. The path
  # is a literal DOS path because exeArgs are not expanded; `propnix` is the fixed profile user. A
  # flag rather than a CoW overlay on Cities_Data/, which holds the Mono assemblies (some Unity
  # players fail to load `Managed/` through an overlay). Both: docs/research/unity-player-facts.md.
  exeArgs = [
    "-logfile"
    "C:\\users\\propnix\\AppData\\Local\\Colossal Order\\Cities_Skylines\\output_log.txt"
  ];

  # Full-colour icon auto-extracted from Cities.exe's PE resources (icon.auto default; 16-256 px).

  # Single-player. The netns cuts the Paradox Mods browser, the news feed and the store links (EOS
  # and PopsApi plugins); their connects fail immediately and are caught.
  online = false;

  # steam_api64.dll sits at the payload root and is loaded by name only by
  # Cities_Data/Plugins/ColossalNative.dll (LoadLibrary + GetProcAddress, no static import);
  # steam.emu replaces it. Its 2015 SDK revisions (SteamClient017) come from the build-time
  # interface scan (docs/research/steam-entitlement.md).
  steam.emu.libPaths = [ "steam_api64.dll" ];

  # ── DLC ── Four radio-station packs, each a depot of the base app 255710 and a pure additive
  # union under Files/Radio (no base file shadowed), mounted read-only above the base. The depot id
  # is not the DLC appid, so versions.json carries `dlcAppId`, which steam.emu (on for every Steam
  # fetch) projects into the entitlement list (docs/research/steam-dlc-appids.md). The packs build;
  # their ownership in the in-game Content Manager is unverified. Not in the base package:
  # `.withAllDlc` / `.withDlc [ "all-that-jazz" ]` select.
  dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

  # %LOCALAPPDATA%/Colossal Order/Cities_Skylines holds Saves, Addons and config; bound whole.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Local/Colossal Order/Cities_Skylines";
    }
  ];

  # Deliberately unset (docs/research/unity-player-facts.md):
  # * `presets.unity.framePacing`: inert here. `VidVSync`/`VidTFR` are Hollow Knight's own script
  #   prefs, not Unity engine prefs, and this title has no such prefs.
  # * `presets.unity.fullscreen`: the wrong key. Unity 5.6 reads `Screenmanager Is Fullscreen mode`;
  #   if cursor confinement appears, use a hand-written userReg row under that name.
  # * a d3d/graphics override: the defaults run D3D11 on DXVK under winewayland.
}
