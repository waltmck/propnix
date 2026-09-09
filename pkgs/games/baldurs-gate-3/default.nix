# Baldur's Gate 3 (GOG, Windows build) via wine — on aarch64 through FEX + ARM64EC, on x86_64 natively.
# Larian's Divinity 4.0 engine. ARCH-AGNOSTIC: this spec is identical on both hosts; mkApp + the scope pick
# the arch-appropriate emulator set and the SAME Windows payload (a content-addressed FOD) is shared.
#
# Windows-only: Larian ship no Linux build on either store. BOTH stores are now pinned for that one
# platform — so `platformPreference` stays derived (the ratchet in modules/app-options.nix counts PINNED
# PLATFORMS, not pinned pairs, and there is still exactly one) and the fetcher alone distinguishes them:
#
#   * gog   / x86_64-windows — the GOG Galaxy build. THE VERIFIED PATH: everything under "VERIFIED BY
#                              PLAYING IT" below was measured on this payload, and it is what the default
#                              `preferredFetchers` (every registered fetcher in registry order — `gog`
#                              sorts before `steam`) still resolves to. Unchanged by the Steam pins.
#   * steam / x86_64-windows — the Steam build, four depots. NEVER LAUNCHED. Pinned for comparison, as the
#                              old note here said it would be; reachable only via an explicit
#                              `.apply { fetcher = "steam"; }`. See "THE STEAM MATRIX" below for what
#                              differs and what is therefore still unverified.
#
#   nix run .#baldurs-gate-3 --extra-sandbox-paths /propnix=/var/lib/propnix
#   nix run '.#baldurs-gate-3.apply { fetcher = "steam"; }'    # the untested Steam payload
#
# ── THE STEAM MATRIX ────────────────────────────────────────────────────────────────────────────────────
# Steam splits this title across four depots, and the split is not cosmetic — the ORDER in versions.json is
# load-bearing because builders/wine.nix takes `head payloads` as C:\game's primary tree, the launch cwd,
# and the tree it extracts the PE icon from. Measured contents of the pinned trees:
#
#   1419652  bin/       ~189 MB  bg3.exe, bg3_dx11.exe, steam_api64.dll, DXVK-adjacent vendor DLLs   ← head
#   1419653  Launcher/  ~190 MB  LariLauncher.exe + CefSharp + its own steam_api64.dll
#   1086941  Data/      ~137 GB  every .pak, plus DotNetCore/ and InstallScript.vdf
#   1086942  Data/Localization/language.lsx   (573 B; byte-identical to the copy in 1086941 — `cmp` clean,
#            so the union order between those two arbitrates nothing)
#
# 1419652 is first because `exe` and the icon both live there. Nothing else overlaps at all.
#
# WHAT IS UNVERIFIED ON THE STEAM PATH: everything below that was measured against the GOG tree. The exe
# paths are identical (`bin/bg3_dx11.exe` exists in 1419652), `workingDir = "bin"` is a property of the
# engine rather than the store, and the LOCALAPPDATA save location is a Larian convention with no store
# suffix (`bin/bg3_dx11.exe` carries the plain "Larian Studios" string, no GOG/Steam variant) — but none of
# that has been observed running. Treat the Steam path as pinned-and-plausible, not as tested.
#
# NOT PINNED HERE: depot 2330358 of this same app was also downloaded and is in the store. It is NOT DLC
# content — 126,748 files, 3.3 GB, of which 3.3 GB is `Data/Editor/` (gizmos, previews, wiki help) with the
# rest `Data/Mods/{Gustav,GustavDev,GustavX,Shared,SharedDev}/Story/RawFiles` and `Data/Projects/GustavDev`,
# and NOT ONE .pak. That is Larian's modding-toolkit source data, not the Digital Deluxe bonus content it
# was pinned as. Wiring it into `dlc.available` would union 126k editor files over the game dir for no
# runtime effect AND emit a bogus steam.emu entitlement row (the projection would take depotId 2330358 as
# a DLC store appid, which it is not). Left out until someone identifies the real Digital Deluxe depot.
#
# ── WHICH EXECUTABLE, AND WHY THE D3D11 ONE ────────────────────────────────────────────────────────────
# `goggame-1456460669.info` lists three play tasks:
#   isPrimary=true   Launcher/LariLauncher.exe   category=launcher   121 KB
#   isPrimary=false  bin/bg3.exe                 category=game        35 MB   (native Vulkan)
#   isPrimary=false  bin/bg3_dx11.exe            category=game        34 MB   (D3D11)
# We launch a game binary DIRECTLY, not the isPrimary task. LariLauncher is a .NET WPF app that embeds
# CefSharp — running it would drag in the whole Chromium-under-wine problem for no benefit: its own
# `Launcher/launcher.cfg` shows its "DirectX 11 vs Vulkan" option is nothing but an exe pick
# ({ "vulkan": "..\bin\bg3.exe", "dx11": "..\bin\bg3_dx11.exe" }), so launching a game binary directly
# loses no setup — choosing `exe` here IS the launcher's renderer setting.
#
# bg3_dx11.exe (D3D11 → DXVK) over bg3.exe (native Vulkan) is the HDR choice, and it INVERTS the
# fewer-layers preference this spec used to follow (Vulkan → winevulkan beats D3D11 → DXVK → Vulkan):
#   * bg3.exe does HDR — it reads HDR10 colorspaces straight off the Vulkan surface (mesa ≥25.1 wayland
#     WSI color management + a compositor output in HDR mode; winevulkan passes surface formats through)
#     — but only ENGAGES it in its exclusive-fullscreen display mode, and that mode loses a state fight
#     between winewayland and the compositor: the mode-set transition bounces the toplevel out of
#     fullscreen (observed settling as a floating window), and a compositor-initiated fullscreen resizes
#     the window from outside, which knocks the engine back out of its fullscreen mode and turns its HDR
#     gate off with it.
#   * bg3_dx11.exe gets HDR through DXVK's DXGI (`env.DXVK_HDR` below) in ANY display mode — no
#     exclusive-fullscreen requirement, so no state fight to lose.
# `.apply { exe = "bin/bg3.exe"; }` is the one-line switch back to the Vulkan renderer.
#
# ── VERIFIED BY PLAYING IT ─────────────────────────────────────────────────────────────────────────────
# bg3.exe (the previous default): reaches the main menu, starts a new game, plays through the intro and
# autosaves (engine state machine reaches Running/Save); two ~18-minute sessions exited cleanly with no
# page faults. bg3_dx11.exe: verified on x86_64 (2026-09-01) — launches and plays, and with DXVK_HDR the
# swapchain presents HDR10_ST2084 on an HDR wayland session (Hyprland 0.56, mesa 26.1, RADV). The
# FEX/ARM64EC soak tests above were all bg3.exe; DXVK is already the aarch64 d3d default (RESEARCH §22),
# but re-verify on that host before trusting a long session there.
#
# graphics: the tree default (winewayland) is CORRECT here — do not add an x11 override. A/B measured
# (on bg3.exe): wayland 18 min clean exit / 0 faults / 0 swapchain recreates, x11 17 min clean exit /
# 0 faults. The fullscreen-Vulkan swapchain-recreate NULL-deref that forces x11 for Skyrim SE does not
# reproduce.
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

    # De-store-integration on the STEAM path (inert on GOG: `steam.emu.enable` defaults to `fetcher ==
    # "steam"`). Both shipped copies are declared — `bin/steam_api64.dll` is the one `exe` above loads, and
    # `Launcher/steam_api64.dll` is what LariLauncher would load if anyone ever selected it — so whichever
    # binary a `.apply` points at gets the gbe_fork shim rather than the genuine dll. On wine the mechanism
    # is union-replacement at exactly these paths (the settings tree ranks above the payload in the game
    # overlay); it is also REQUIRED, since mk-app.nix refuses a wine build that enables the emu without
    # naming a `.dll` — a shim nothing loads would be silently inert.
    #
    # The GOG payload's own store SDK — `bin/Galaxy64.dll` — gets the no-op stub, as policy: propnix binds
    # it over every bundled Galaxy SDK so the SDK is never engaged, rather than engaged-and-failing behind
    # the netns. GATED ON THE FETCHER because the two payloads differ: the Steam depots carry no Galaxy DLL
    # at all (checked — zero `*alaxy*` files across all four bg3 depots in the store), and an ungated row
    # would ask propnix-mount to bind a stub over a path that does not exist on that tree.
    # UNVERIFIED PATH: `bin/Galaxy64.dll` is taken from this spec's own earlier note, NOT re-checked — the
    # GOG payload is not fetched on the machine this was written on, so nothing here confirms the filename
    # or its directory. If the stub row turns out to point at nothing, correct it against the real tree
    # rather than assuming the mount silently no-ops.
    wine.galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [ "bin/Galaxy64.dll" ];
    steam.emu.libPaths = [
      "bin/steam_api64.dll"
      "Launcher/steam_api64.dll"
    ];

    # DXVK's stand-in for the Windows "HDR on" display toggle: with it set, DXGI reports an HDR10 display
    # and the engine offers HDR. Without it DXVK NEVER reports HDR under winewayland — wine writes no EDID
    # into the registry, so there is nothing for DXVK to auto-detect from (its dxgi logs "colorimetry
    # info, using blank"). Safe when the session is SDR: the engine also gates on CheckColorSpaceSupport,
    # which follows the REAL Vulkan surface (sRGB-only unless the compositor output is in HDR mode), so it
    # degrades to SDR instead of rendering PQ into an sRGB swapchain; HDR brightness is calibrated
    # in-game. (Not a tree-wide default on purpose: careless titles trust the DXGI report alone — UE4 DX11
    # games even crash on it, see DXVK's own isHDRDisallowed guard — so each title opts in knowingly.)
    env.DXVK_HDR = "1";

    # The engine writes its log as `gold.<timestamp>.log` into the GAME directory, which is read-only here,
    # so CreateFileW fails with STATUS_ACCESS_DENIED and it runs with NO log sink at all. `--logPath <dir>`
    # (two separate argv entries — the option parser does not accept `=`) redirects it into the already-bound
    # writable state directory. Worth keeping beyond debugging: a user reporting a bug now has a real log,
    # and it is what made every diagnosis on this title possible.
    exeArgs = [
      "--logPath"
      "C:\\users\\propnix\\AppData\\Local\\Larian Studios\\Baldur's Gate 3"
    ];

    # THE fix for this title: run with the working directory set to the executable's own directory.
    # The engine derives its khonsu path roots as `<cwd>/../Data/...` — measured directly out of the game's
    # base-path global at runtime: "C:/game/../Data/Scripts". With propnix's default cwd (the game root)
    # that collapses to `C:\Data\Scripts`, i.e. the DRIVE ROOT, so every script path — and the VFS key
    # built from it — is wrong, and the engine silently fails to resolve `Scripts/**` out of the paks
    # (verified: it reads the pak's whole file list, then issues ZERO reads for any script entry).
    # With cwd = bin, `bin/../Data/Scripts` is correct, which is what a normal install gets.
    workingDir = "bin";

    # Full-colour icon from the game binary's own PE resources.
    icon.auto = true;

    # Larian keeps EVERYTHING under one LOCALAPPDATA directory — settings, the Vulkan pipeline cache, and the
    # actual savegames — so it is split across two binds by KIND rather than persisted wholesale. Both are
    # `saveBinds` rows because that is the mechanism for binding under the wine profile home (the builder joins
    # `dst` onto `drive_c/users/<wineUser>/`, so a game file never has to know the profile name); `src` is just
    # a path, and pointing one at $PROPNIX_STATE is what puts regenerable data in the state dir.
    #
    # VERIFIED by running it: graphicSettings.lsx, vkDeviceConfig.lsx, PlayerProfiles/, the engine logs and
    # pipelineCacheTimestampVk.bin all appear here; savegames land under PlayerProfiles.
    #
    # The SHADER CACHE is the reason for the split. `bin/bg3.exe` strings name
    # `pipelineCacheVk.bin` / `pipelineCacheVk.bin.tmp` / `pipelineCacheTimestampVk.bin` /
    # `abstractPipelineCache.psoCache`, all written into this same directory — so the expensive first-launch
    # pipeline compile lands here. It is CACHE, not save data: it belongs in the state dir, where it is not
    # entangled with savegames (which a user may back up, sync or wipe independently).
    #
    # NOTE the `.tmp` suffix above: the game writes the cache then RENAMEs it into place. That is why the cache
    # must sit inside a bound DIRECTORY and must never be given a per-FILE bind row — rename(2) cannot replace a
    # bind-mounted file (EBUSY), the same trap that shapes how user.reg is handled in the wine builder.
    saveBinds = [
      {
        # Settings + the Vulkan pipeline cache: regenerable, so state rather than saves.
        src = "$PROPNIX_STATE/larian";
        dst = "AppData/Local/Larian Studios/Baldur's Gate 3";
      }
      {
        # The savegames proper, nested inside the row above (propnix-mount lays parents first and builds the
        # missing child mountpoint).
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "AppData/Local/Larian Studios/Baldur's Gate 3/PlayerProfiles";
      }
    ];
  }
)
