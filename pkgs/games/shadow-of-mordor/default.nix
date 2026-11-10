# Middle-earth: Shadow of Mordor — Game of the Year Edition (Monolith / WB Games) via wine — on
# aarch64 through FEX + native ARM64EC DXVK, on x86_64 natively. Monolith's LithTech-derived
# "Firebird" engine (the exe's own registry root is `SOFTWARE\WB Games\Firebird\1.00.0000`), renders
# D3D11 → DXVK → Vulkan: `ShadowOfMordor.exe` imports d3d11.dll + dxgi.dll and nothing else
# graphical, so the tree's DXVK default is exactly right and no `d3d` override belongs here.
# ARCH-AGNOSTIC: the spec is identical on both hosts; mkApp + the scope pick the arch-appropriate
# emulator set and the SAME Windows payload (a content-addressed FOD) is shared. Windows-only
# content — neither store ships a Linux build.
#
#   nix run .#shadow-of-mordor --extra-sandbox-paths /propnix=/var/lib/propnix  # gog/x86_64-windows
#   nix run '.#shadow-of-mordor.apply { fetcher = "steam"; }'                   # the Steam build
#   nix run '.#shadow-of-mordor.apply { fetcher = "steam"; }.withAllDlc'        # …+ 20 DLC depots
#
# Owned on both stores. Both pin x86_64-windows, so `platformPreference` derives and the default
# `preferredFetchers` order picks GOG (no game-authored `fetcher`, which lib/tests/resolution.nix
# forbids). The arms differ only in store integration; the exe and engine files are byte-identical.
#
# The GOG tree is the complete GOTY edition plus the HD texture pack; every Steam DLC depot is a
# byte-identical subset of it, so DLC rows exist only on the Steam arm. The Steam `pname`s are the
# `propnix pin --new` placeholders: renaming one repoints its FOD and forces a ~55 GB refetch. Depot
# contents, the dropped macOS depots and the DLC naming: docs/research/multi-store-payloads.md.
#
# The sole play task is x64/ShadowOfMordor.exe, and `workingDir = "x64"` is required:
# x64/default.archcfg lists every archive as `..\<name>.arch05`. That list is a static superset and
# the engine tolerates an absent archive, which is why the Steam DLC can be a pure union
# (docs/research/engine-working-directory.md).
#
# 16K-page aarch64 hosts rely on emulators/wine-hangover/patches/0007 (this exe's 8-byte `.SHARED`
# section).
{
  lib,
  mkApp,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp (
  { config, lib, ... }:
  let
    onSteam = config.fetcher == "steam";
  in
  {
    pname = "shadow-of-mordor";
    maintainers = [ "waltmck" ];
    appid = "shadow-of-mordor";
    name = "Middle-earth: Shadow of Mordor";

    fetchInfo = versions.fetchInfo;

    # See the header: the sole play task, and the sole executable, in either payload.
    exe = "x64/ShadowOfMordor.exe";
    # REQUIRED, not cosmetic — x64/default.archcfg addresses every archive as `..\<name>.arch05`.
    workingDir = "x64";

    # Full-color icon auto-extracted from the exe's PE resources (icon.auto default; 256 px
    # present). No symbolic variant yet.

    # The exe links WS2_32 and the Steam matchmaking/game-server API, but both arms already
    # neutralize the SDK (below), so the netns is a second, kernel-side guarantee.
    # `.apply { online = true; }` reverts.
    online = false;

    # Saves: {userdocs}/WB Games/Shadow of Mordor (the goggame script's savePath). Bind the whole
    # folder: saves and config persist together.
    #
    # Open: `USER\render.cfg`/`settings.cfg` may land in the read-only game dir. If settings don't
    # persist, trace `+file` and add a `wine.mounts` row over drive_c/game/USER (the KSP pattern).
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/WB Games/Shadow of Mordor";
      }
    ];

    # steam_api64.dll is a static import, so it can't be masked; each arm puts something benign
    # behind it. On GOG it is GOG's own bridge onto Galaxy, so the no-op stub goes beneath it at
    # Galaxy64.dll (the payload's only copy): the bridge's calls answer offline / not signed in. The
    # stub-bound GOG arm plays on aarch64 (in-game, 2026-11-09). Import coverage and the residual
    # DLC-ownership risk: docs/research/galaxy-sdk-offline.md.
    wine.galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [ "x64/Galaxy64.dll" ];

    # Declared unconditionally (house rule); only the Steam arm consumes it, where gbe_fork
    # union-replaces the dll, and mk-app.nix requires it there.
    steam.emu.libPaths = [ "x64/steam_api64.dll" ];

    # Steam arm only: 19 single-file entitlement layers plus 311670 (HD Content), each a pure
    # addition to the base depot. `mkIf onSteam` because on GOG this content is already in the base
    # payload. The steam.emu entitlement list is projected from these rows (each depot's `depotId`).
    # The attr names come from each depot's archive filename, not a store listing.
    dlc.available = lib.mkIf onSteam (lib.mapAttrs (_: fetchSteamDepot) versions.dlc);
  }
)
