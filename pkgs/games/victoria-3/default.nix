# Victoria 3 (Steam, WINDOWS build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Paradox grand strategy on the Clausewitz/Jomini stack, i.e. the SAME engine family as
# pkgs/games/stellaris. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick
# the arch-appropriate emulator set and the SAME Windows payload (a content-addressed FOD) is shared
# across arches. Only the Windows depots are pinned (steam/x86_64-windows).
#
# Engine facts (VFS candidate set, log reading, how a working launch looks, the Windows-vs-Linux
# build question): docs/research/clausewitz-engine.md.
#
#   nix run .#victoria-3 --extra-sandbox-paths /propnix=/var/lib/propnix   # aarch64-linux or x86_64-linux
{
  lib,
  mkApp,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp (
  { config, ... }:
  {
    pname = "victoria-3";
    maintainers = [ "waltmck" ];
    appid = "victoria-3";
    name = "Victoria 3";

    # THREE base depots, UNIONED READ-ONLY by overlayfs at launch — no build-time merge, no store copy.
    # They are DISJOINT at the top level, so the list order is not load-bearing here the way
    # stellaris' binaries-before-data order is; it is the pin order:
    #   529341 → `game/`                      the data root (common/, events/, gfx/, localization/, map_data/,
    #                                         the empty `dlc/` the DLC depots below fill in)
    #   529342 → `binaries/` + `clausewitz/` + `jomini/` + `platform_specific_game_data/` + the four
    #                                         *_branch/_rev provenance files — the engine and its shared
    #                                         Clausewitz/Jomini asset trees
    #   529345 → `launcher/`                  the Paradox launcher's assets + settings (see `exe` below —
    #                                         the launcher itself is NOT in the depot, only its installer)
    #
    # (The `pname`s in versions.json are the pin tool's mechanical names. They are load-bearing: an FOD's
    # store path is hash(name, outputHash), so renaming one re-fetches that depot.)
    fetchInfo = versions.fetchInfo;

    # Run the game binary DIRECTLY, bypassing the Paradox launcher: depot 529345 ships only the
    # launcher's installer (`launcher/launcher-installer-windows_*.exe`), not the launcher itself.
    # We run exactly what `launcher/launcher-settings.json` names:
    #     "exePath": "../binaries/victoria3.exe", "exeArgs": [ "-gdpr-compliant" ]
    # (`binaries/victoria3_win_console.exe` is a console-window wrapper, not a second game build.)
    exe = "binaries/victoria3.exe";
    exeArgs = [ "-gdpr-compliant" ];

    # The Clausewitz VFS resolves the data root from candidates `../game`, `../../game`, … (no bare
    # `game`), so the base must be one level down from the install root: `binaries/`, the exe's own
    # directory.
    workingDir = "binaries";

    # The launcher depot's own 512x512 app icon: the gold "V3" monogram over a maroon disc, no text, alpha
    # already clean — autocropped + recentred into the hicolor theme + splash (lib/icons/from-png.nix).
    # PREFERRED over `icon.auto`, which would extract victoria3.exe's PE icon (the exe does carry
    # RT_ICON/RT_GROUP_ICON): same artwork, but this is a single high-res source rather than a Windows icon
    # group. It lives in the LAUNCHER depot = the 3rd payload.
    icon.png = "${lib.elemAt config.payloads 2}/launcher/assets/app-icon.png";

    # NOT `online = false`. Victoria 3 carries a real online stack, statically imported by the exe (PE
    # import table): `nakama-sdk.dll` (Paradox's multiplayer transport), `PDXSDK.dll` (the Paradox account
    # SDK) and WS2_32 — and the game has cross-platform multiplayer. Cutting the network namespace would
    # break that and be miserable to debug, which is exactly the case the option's default is written for.
    # A single-player-only user can still opt in: `.apply { online = false; }`.

    # Save/settings: `launcher/launcher-settings.json` names the engine's data root,
    #     "gameDataPath": "%USER_DOCUMENTS%/Paradox Interactive/Victoria 3"
    # (with `pdx_settings.json` inside it); on wine `dst` joins onto the profile home. Saves,
    # settings, logs and mods land there together. Only `shadercache/` is routed elsewhere (the row
    # below); the logs stay beside the saves deliberately, host-visible so a regression is
    # debuggable.
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/Paradox Interactive/Victoria 3";
      }
      # …with the SHADER CACHE redirected back out of it. The engine caches its runtime-compiled
      # shaders under `shadercache/dx11/`: DERIVED data, rebuilt from the payload when missing and
      # invalidated by a driver or DXVK bump, so it belongs in `$PROPNIX_CACHE` beside the
      # launcher's DXVK/vkd3d caches, not in a dir the user backs up. One DIRECTORY row routes the
      # whole subtree (any future backend dir included). Nesting it under the row above is
      # supported: propnix-mount stubs the missing child into the parent's skeleton, so no empty
      # dir appears in the host save dir.
      {
        src = "$PROPNIX_CACHE/shadercache";
        dst = "Documents/Paradox Interactive/Victoria 3/shadercache";
      }
    ];

    # DLC — the textbook Paradox convention (modules/steam-emu.nix names it): each DLC is its OWN
    # depot of the base app (529340) and the depotId IS the DLC's store appid (each tree's
    # descriptor states it), so no row needs a `dlcAppId` override. Each tree holds only
    # `game/dlc/<dlcNNN_slug>/…`, a PURE directory union over the base's empty `game/dlc/`.
    # `victoria-3` builds vanilla (a default of "all" would tie the default derivation to the
    # packager's entitlements); `.withAllDlc` / `.withDlc [ … ]` union the selected trees ABOVE the
    # base at mount time. The set is what the packaging account owns. Nothing writes `dlc_load.json`
    # (the bypassed launcher's file; absent, the game disables nothing). steam.emu (on for every
    # Steam fetch) projects the entitlement list from these SAME rows.
    dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

    # victoria3.exe STATICALLY imports steam_api64.dll, resolved from the exe's own directory, so
    # the shim is union-replaced at `binaries/steam_api64.dll` (mkApp refuses steam.emu on wine
    # without a `.dll` path).
    steam.emu.libPaths = [ "binaries/steam_api64.dll" ];

    # NO d3d / graphics override: a D3D11 title (imports d3d11/dxgi), so the default d3d=dxvk
    # applies. (`wine.dllOverrides.d3dcompiler_47` below is a separate axis: the HLSL COMPILER.)

    # The Paradox account SDK (PDXSDK.dll) waits on a Steam logon state at boot. gbe_fork's offline
    # mode answers "not logged on" and the engine deadlocks before any log, so the shim must not
    # claim offline (hung-process analysis: docs/research/steam-entitlement.md).
    steam.emu.offline = false;

    # The engine compiles its ps_5_0 HLSL at runtime and wine's builtin d3dcompiler_47
    # (vkd3d-shader) rejects it; depot 529342 ships Microsoft's dll beside the exe, so the override
    # is native-only (`"n"`, no builtin fallback). `dxcompiler.dll`/`dxil.dll` are not
    # wine-implemented names, so they already load native (docs/research/wine-builtin-gaps.md).
    wine.dllOverrides.d3dcompiler_47 = {
      value = "n";
      reason = "native: the engine compiles its ps_5_0 HLSL at runtime and wine's builtin d3dcompiler_47 rejects it (E5002/E5000 from vkd3d-shader) → 'Failed creating shader state' and exit. Depot 529342 ships the real dll beside the exe.";
    };
  }
)
