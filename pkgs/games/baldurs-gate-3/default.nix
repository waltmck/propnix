# Baldur's Gate 3 (GOG, Windows build) via wine — on aarch64 through FEX + ARM64EC, on x86_64
# natively. Larian's Divinity 4.0 engine. ARCH-AGNOSTIC: this spec is identical on both hosts;
# mkApp + the scope pick the arch-appropriate emulator set and the SAME Windows payload (a
# content-addressed FOD) is shared.
#
# Windows-only: both stores pin x86_64-windows, so `platformPreference` stays derived and the
# fetcher picks the store. GOG is the default (`preferredFetchers` order) and the played path; the
# four-depot Steam build has never been launched.
#
#   nix run .#baldurs-gate-3 --extra-sandbox-paths /propnix=/var/lib/propnix
#   nix run '.#baldurs-gate-3.apply { fetcher = "steam"; }'    # the untested Steam payload
#
# Depot order in versions.json is load-bearing: builders/wine.nix takes the head payload as
# C:\game's primary tree, cwd and icon source, so 1419652 (bin/, the exe) stays first. Depot 2330358
# is modding-toolkit source data (no .pak), not Digital Deluxe content, and is deliberately
# unpinned. Depot contents: docs/research/multi-store-payloads.md.
#
# The exe is a game binary launched directly, not the isPrimary LariLauncher (.NET + CefSharp): its
# DX11/Vulkan option is only an exe pick (Launcher/launcher.cfg), so choosing `exe` here IS that
# setting (docs/research/publisher-launcher-bypass.md).
#
# bg3_dx11.exe (D3D11 → DXVK → Vulkan) over bg3.exe (native Vulkan) is the HDR choice, and it
# inverts the fewer-layers preference on purpose: DXVK's DXGI reports HDR in any display mode
# (`env.DXVK_HDR` below), while bg3.exe engages HDR only in its exclusive-fullscreen mode, which
# winewayland cannot hold. `.apply { exe = "bin/bg3.exe"; }` switches back
# (docs/research/dxvk-hdr-under-winewayland.md).
#
# graphics stays on the tree default (winewayland): the fullscreen swapchain-recreate fault that
# pins Skyrim SE to x11 does not reproduce here.
#
# Verified play: docs/verified/baldurs-gate-3-win.json. The engine defects, the graphics A/B and
# the logging setup: docs/research/baldurs-gate-3.md.
{
  lib,
  mkApp,
}:
mkApp (
  { config, ... }:
  {
    pname = "baldurs-gate-3";
    maintainers = [ "waltmck" ];
    appid = "baldurs-gate-3";
    name = "Baldur's Gate 3";

    fetchInfo = (lib.importJSON ./versions.json).fetchInfo;

    exe = "bin/bg3_dx11.exe";
    # Full-color icon auto-extracted from the exe's PE resources (icon.auto default).

    # Both shipped steam_api64 copies (the one `exe` loads, and LariLauncher's) get the gbe_fork
    # shim, so whichever binary a `.apply` points at is covered; inert on GOG (`steam.emu.enable`
    # follows `fetcher`). Required: mk-app.nix refuses a wine steam.emu that names no `.dll` path.
    #
    # GOG's Galaxy64.dll gets the no-op stub as offline policy, gated on the fetcher because the
    # Steam depots ship no Galaxy DLL. The path is not yet checked against the GOG tree: if the row
    # points at nothing, correct it against the real payload.
    wine.galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [ "bin/Galaxy64.dll" ];
    steam.emu.libPaths = [
      "bin/steam_api64.dll"
      "Launcher/steam_api64.dll"
    ];

    # DXVK's stand-in for the Windows "HDR on" display toggle: with it set, DXGI reports an HDR10
    # display and the engine offers HDR. Without it DXVK NEVER reports HDR under winewayland — wine
    # writes no EDID into the registry, so there is nothing for DXVK to auto-detect from. Safe when
    # the session is SDR: the engine also gates on CheckColorSpaceSupport, which follows the REAL
    # Vulkan surface (sRGB-only unless the compositor output is in HDR mode), so it degrades to SDR
    # instead of rendering PQ into an sRGB swapchain; HDR brightness is calibrated in-game. (Not a
    # tree-wide default on purpose: careless titles trust the DXGI report alone — UE4 DX11 games
    # even crash on it, see DXVK's own isHDRDisallowed guard — so each title opts in knowingly.)
    env.DXVK_HDR = "1";

    # The engine writes its log as `gold.<timestamp>.log` into the GAME directory, which is
    # read-only here, so CreateFileW fails with STATUS_ACCESS_DENIED and it runs with NO log sink at
    # all. `--logPath <dir>` (two separate argv entries — the option parser does not accept `=`)
    # redirects it into the already-bound writable state directory. Worth keeping beyond debugging:
    # a bug report then carries a real log.
    exeArgs = [
      "--logPath"
      "C:\\users\\propnix\\AppData\\Local\\Larian Studios\\Baldur's Gate 3"
    ];

    # cwd = bin: the engine derives its data roots as `<cwd>/../Data/…`, so from the game root every
    # pak lookup lands under the drive root (docs/research/engine-working-directory.md).
    workingDir = "bin";

    # Larian keeps settings, the Vulkan pipeline cache and the savegames under one LOCALAPPDATA
    # directory, so it is split by kind: the directory goes to state (regenerable), PlayerProfiles
    # to saves. The pipeline cache is written as `.tmp` then renamed into place, so it must sit
    # inside a bound DIRECTORY and never get a per-file bind row: rename(2) cannot replace a
    # bind-mounted file (EBUSY).
    saveBinds = [
      {
        # Settings + the Vulkan pipeline cache: regenerable, so state rather than saves.
        src = "$PROPNIX_STATE/larian";
        dst = "AppData/Local/Larian Studios/Baldur's Gate 3";
      }
      {
        # The savegames proper, nested inside the row above (propnix-mount lays parents first and
        # builds the missing child mountpoint).
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/Local/Larian Studios/Baldur's Gate 3/PlayerProfiles";
      }
    ];
  }
)
