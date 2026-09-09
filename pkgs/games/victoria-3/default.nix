# Victoria 3 (Steam, WINDOWS build) via wine — on aarch64 through FEX + native ARM64EC DXVK, on x86_64
# natively. Paradox grand strategy on the Clausewitz/Jomini stack, i.e. the SAME engine family as
# pkgs/games/stellaris; the binaries depot ships the engine's own provenance files, and they say so:
# `clausewitz_branch.txt` = "caligula/release/1.13.x", `caligula_branch.txt` = "release/1.13.11"
# ("caligula" is this title's internal codename). ARCH-AGNOSTIC: this spec is identical on both hosts;
# mkApp + the scope pick the arch-appropriate emulator set and the SAME Windows payload (a
# content-addressed FOD) is shared across arches.
#
# WHY WINE + THE WINDOWS BUILD — and NOT stellaris' box64 + native-Linux route: only Windows depots are
# pinned for app 529340. Whether Paradox ships a Linux build of Victoria 3 at all was NOT checked in this
# packaging pass; if one exists it can be pinned as a second platform and ranked in `platformPreference`
# (the hollow-knight shape), at which point stellaris' finding — that the WINDOWS Clausewitz build hangs
# under FEX/ARM64EC on early-init worker-thread stack overflow — becomes the reason to prefer it on
# aarch64. Until then the fetch matrix has exactly the one steam/x86_64-windows pair and any other
# selection is a legible mkApp error.
#
# WHY STEAM: Steam pins content by (appId, depotId, manifestId) and retains every manifest forever, so a
# pin is a permanently-reproducible FOD (lib/fetchers/fetchSteamDepot.nix). Requires an account that owns
# the title: `propnix cred add steam`.
#
# STATUS — PLAYS (x86_64-linux, 2026-09-03). Verified to the MAIN MENU: loading screen with the engine's
# live "N shaders compiled so far" counter, then the frontend — Single player (Continue / New Game / Load
# Game), Multiplayer (Host / Join), Exit to Desktop, the DLC strip, and the engine's own version stamp
# "Game Version: Matcha (1.13.11) / MP Checksum: a47f". Two knobs were needed to get there and BOTH are
# measured, not reasoned: `steam.emu.offline = false` and a native `d3dcompiler_47` — see the two blocks
# at the bottom of this file, which record what each one was blocking and how that was observed.
#
# The two inferences this file used to flag as unverified are now CONFIRMED by the engine's own logs:
#   * `workingDir` — debug.log opens with four `virtualfilesystem_physfs.cpp:460: Mounted Data:` lines
#     (C:/game/{clausewitz,jomini,platform_specific_game_data,game}), i.e. the VFS candidate set resolved.
#   * `saveBinds`  — the bound dir fills with `pdx_settings.json`, `logs/`, `shadercache/` (6840 files on a
#     first run), `crashes/`, `dumps/`, `exceptions/`. Nothing landed in a sibling.
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
    appid = "victoria-3";
    name = "Victoria 3";

    # THREE base depots, UNIONED READ-ONLY by overlayfs at launch — no build-time merge, no store copy.
    # They are DISJOINT at the top level (verified against all three realised trees), so the list order is
    # not load-bearing here the way stellaris' binaries-before-data order is; it is the pin order:
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

    # Run the game binary DIRECTLY, bypassing the Paradox launcher — and here that is not merely the
    # stellaris preference (skip an Electron/Chromium stack that need not survive emulation), it is the
    # only option the payload offers: depot 529345 ships `launcher/dowser.exe` plus
    # `launcher/launcher-installer-windows_2026.10.exe`, an InstallShield SELF-EXTRACTOR (per `file`) —
    # the launcher proper is installed by Steam post-download and simply is not present in the content.
    #
    # `launcher/launcher-settings.json` records what the launcher would exec, and we run exactly that:
    #     "exePath": "../binaries/victoria3.exe", "exeArgs": [ "-gdpr-compliant" ]
    # (its one `alternativeExecutables` entry is the same exe plus `-debug_mode`). The sibling
    # `binaries/victoria3_win_console.exe` is NOT a second game build — it is a 166 KB CUI-subsystem shim
    # whose entire import table is SHLWAPI + KERNEL32, i.e. the "give me a console window" wrapper.
    exe = "binaries/victoria3.exe";
    exeArgs = [ "-gdpr-compliant" ];

    # OBSERVED CORRECT — debug.log's first four lines are `virtualfilesystem_physfs.cpp:460: Mounted Data:`
    # for C:/game/clausewitz, C:/game/jomini, C:/game/platform_specific_game_data and C:/game/game, so the
    # candidate set below resolved against `binaries/` exactly as predicted. The derivation that got it
    # right is worth keeping, because it is what says the value is not merely one that happens to work:
    # victoria3.exe's Clausewitz VFS bootstrap
    # (`C:\mnt\gsg\caligula\caligula\cw\clausewitz\pdx_core\vfs\virtualfilesystem_physfs.cpp`, PhysicsFS)
    # carries these as an ordered CANDIDATE SET, immediately beside its own failure message
    # `No subdirs mounted for game dir from candidates: {}` and its success message `Mounted Data: {}`:
    #
    #     ../../../game   ../game   ../../game
    #     ../../platform_specific_game_data   ../../../platform_specific_game_data
    #     ../platform_specific_game_data                        (and ../clausewitz ../jomini alongside)
    #
    # THE SET CONTAINS NO BARE `game`. So the resolution base is never the install root: one `..` is the
    # minimum, which lands on `binaries/` — the exe's own directory — and the deeper variants exist for the
    # editor/tool layouts that sit further down. propnix's default cwd IS the game root, one level too high
    # for every candidate, so pin cwd to `binaries/`. Correct whether the engine anchors on the cwd or on
    # its own module path, since with this setting the two agree.
    # `.apply { workingDir = null; }` is the one-line revert; the mount log above is what argues against it.
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

    # Save/settings: `launcher/launcher-settings.json` states the engine's data root as
    #   "gameDataPath": "%USER_DOCUMENTS%/Paradox Interactive/Victoria 3"
    # with "ingameSettingsPath": "pdx_settings.json" inside it (and `pdx_settings.json` is indeed a literal
    # in victoria3.exe). On wine, `dst` is joined onto the wine profile home
    # (drive_c/users/propnix/), so this binds the persistent propnix save dir at the exact path the engine
    # writes — saves, settings, logs and mods together — while the game tree stays read-only.
    # VERIFIED at runtime (the check skyrim-se's cautionary tale calls for — there the GOG build used a
    # differently SUFFIXED folder and the first guess silently dropped saves). After a launch to the menu
    # the bound dir holds `pdx_settings.json`, `logs/` (the 21 Clausewitz logs), `shadercache/dx11/`,
    # `crashes/`, `dumps/` and `exceptions/`; no sibling directory is created.
    saveBinds = [
      {
        src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
        dst = "Documents/Paradox Interactive/Victoria 3";
      }
    ];

    # DLC — the textbook Paradox convention (modules/steam-emu.nix names it): each DLC ships as its OWN
    # depot of the BASE app (529340) and the depotId IS the DLC's store appid, which is why no row needs a
    # `dlcAppId` override. CONFIRMED here rather than assumed: every tree's own descriptor states its
    # `steam_id`, and each equals its depotId — dlc002 "American Buildings Pack" = 2071471, dlc006 "Voice
    # of the People Preorder" = 2366580, dlc008 = 2591240 (the `.dlc` calls it "Region Pack 1", the
    # `.dlc.json` displayName is "Colossus of the South" — the store name, which is what versions.json
    # carries), dlc013 "Charters of Commerce" = 3450170.
    #
    # Each tree is install-root-relative and holds exactly `game/dlc/<dlcNNN_slug>/{<name>.dlc,
    # <name>.dlc.json, thumbnail.png}` (+ a `gfx/` for the two content packs) — a PURE directory union: the
    # base data depot's own `game/dlc/` is EMPTY, so no DLC ever modifies a base file. The `.dlc` descriptor
    # is the ownership marker the engine gates on; `game/dlc_metadata/00_dlc_metadata.txt` in the base
    # depot already lists the whole catalogue by steam_id, so the base build knows about DLC it has no
    # content for, which is the usual Paradox shape.
    #
    # NOT part of the base package: `victoria-3` builds vanilla (a default of "all" would make the default
    # derivation depend on the packager's own entitlements). `victoria-3.withAllDlc` / `.withDlc [ … ]` /
    # `.apply { dlc.enabled = [ … ]; }` union the selected trees ABOVE the base at mount time (wine's
    # multi-lower `drive_c/game` overlay, DLC first), so an enabled DLC costs no second copy of the base.
    #
    # This is the set the packaging Steam account owns; Steam refuses the decryption key (eresult 15) for
    # the rest of the catalogue, so an unowned DLC is simply not listed. Nothing here writes
    # `dlc_load.json` — that file belongs to the bypassed Paradox launcher, and with it absent the game
    # disables nothing.
    #
    # Staging the trees is only half the job: a Steam build resolves ENTITLEMENT through the Steam client,
    # which is absent here. Declaring `dlc.available` on a Steam-fetched build leaves `steam.emu.enable`
    # at its default (on for every Steam fetch), and modules/steam-emu.nix projects the entitlement list
    # from these SAME rows — see `steam.emu.libPaths`.
    dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

    # victoria3.exe STATICALLY imports steam_api64.dll (verified in the PE import table), and wine resolves
    # a static import from the exe's own directory first — so the file that matters is the one beside the
    # exe, `binaries/steam_api64.dll`. On wine the mechanism is UNION-REPLACEMENT: steam.emu mirrors the
    # gbe_fork PE shim at this exact relative path inside its settings tree, and that tree ranks above the
    # payload in the game-dir overlay, so the dll the PE loader maps IS the shim with its settings beside
    # it. Declaring it is also mandatory — mkApp refuses steam.emu on wine with no `.dll` path rather than
    # ship a silently-inert shim.
    steam.emu.libPaths = [ "binaries/steam_api64.dll" ];

    # NO d3d / graphics override, deliberately — and this now has a run behind it rather than only the
    # import table. The exe imports d3d11.dll + dxgi.dll (and dxcompiler / D3DCOMPILER_47), i.e. it is a
    # D3D11 title, which is precisely what the tree default d3d=dxvk is for; DXVK 2.7.1 takes it at
    # D3D_FEATURE_LEVEL_11_0 on a real adapter with a 1920x1080 / 4-image swapchain, and the engine's own
    # `contextowner.cpp:868: GPU Name:` line agrees with the card DXVK picked. Nothing argues for wined3d,
    # nor for x11 over the winewayland default. (`wine.dllOverrides.d3dcompiler_47` below is a separate
    # axis — the runtime HLSL COMPILER, not the D3D runtime.)

    # ── BLOCKER 1 OF 2: THE SHIM MUST NOT CLAIM STEAM IS IN OFFLINE MODE ──────────────────────────────────
    # MEASURED, not reasoned. With the tree default (`offline = true`) the launch stops dead at the propnix
    # splash: no window, no engine log, and `$XDG_STATE_HOME/propnix/victoria-3/wine/users` — the profile
    # overlay's UPPER, so exactly what the run WROTE — contains one file,
    # `propnix/AppData/Roaming/GSE Saves/settings/configs.user.ini` (`account_name=gse orca`), gbe_fork's
    # identity file, written on the first Steamworks call. So the exe mapped, the static steam_api64.dll
    # import resolved to the union-replaced shim, the shim answered — and then the process stopped.
    #
    # WHERE IT STOPPED, from the hung process rather than from a guess:
    #   * All 13 threads idle. The engine's job system HAD come up (thread names `victoria3.exe:disk$0`,
    #     `:cs0`, `:sh0`, `:sh_opt0`, `:traceq0`, `:gdrv0`, `:gl0`); every one of them parked in futex.
    #   * The MAIN thread sat in `read(fd, buf, 16)` on a pipe whose write end the process holds itself.
    #     `strace -k -e trace=pipe2` names that pipe: wine's own `server_pipe`/`init_thread_pipe`, i.e. the
    #     per-thread wineserver wait pipe, and a 16-byte read from it is `server_select()` collecting a
    #     `struct wake_up_reply`. That is a wineserver-mediated Win32 wait that never gets signalled — a
    #     block, not a fault (consistent with `binaries/crash_reporter/CrashReporter.exe` and the
    #     `submit.backtrace.io/paradoxinteractive/…/minidump` endpoint never firing).
    #   * `PROPNIX_WINEDEBUG=+sync` ends with ~5900 `RtlWakeAddressAll` calls from the main thread and then
    #     silence. Their addresses land at +0x9FA390 and +0xA847E8 from the load base of
    #     `C:\game\binaries\steam_api64.dll` — inside the 11,429,288-byte gbe_fork PE shim, whose image the
    #     next module's base bounds to 11.06 MB. The spin that precedes the deadlock is IN the shim.
    #
    # WHY THIS KEY REACHES IT. `steam.emu.offline` (lib/modules/steam-emu.nix) writes
    # `[main::connectivity] offline` into the shim's `configs.main.ini`; in the pinned gbe_fork that key has
    # exactly three consumers, all in `dll/steam_user.cpp`: `BLoggedOn()` → false, `BConnected()` → false,
    # `GetLogonState()` → k_ELogonStateNotLoggedOn. `PDXSDK.dll` is the PARADOX ACCOUNT SDK, statically
    # imported, and debug.log's `pdx_account.cpp:600: Starting up PDX SDK` sits at exactly this point in a
    # working run — the Steam↔Paradox link at boot is the handshake that waits on a logon state.
    #
    # THE EVIDENCE THAT IT IS THIS KEY: flipping it alone turns "no log at all" into the engine's full
    # 21-file log set plus a D3D11 device. This file's earlier note reasoned the flip was a POOR fit here
    # (unlike pkgs/games/rust, Victoria 3 has a first-class single-player mode and so "ought to" have an
    # offline path); that reasoning was WRONG, and the run is why the knob is set. Note what the flip still
    # does not buy: no real Steam session, no ticket that validates with Valve — only that the shim stops
    # volunteering a "no" to a question this title cannot take "no" for.
    steam.emu.offline = false;

    # ── BLOCKER 2 OF 2: HLSL MUST BE COMPILED BY THE SHIPPED D3DCOMPILER, NOT WINE'S ──────────────────────
    # With blocker 1 cleared the engine reaches its renderer and then EXITS — `gfx_dx11_shaderstate.cpp:161:
    # Failed getting shader for PixelTexture` / `gfx_dx11_master_context.cpp:521: Failed creating shader
    # state`, on an error.log full of `E5002: Can't implicitly convert from float2 to float3` and
    # `E5000: Failed to evaluate constant expression`. Those E-codes are vkd3d-shader's HLSL front end, and
    # `PROPNIX_WINEDEBUG=+loaddll` says why it is in the picture:
    #
    #     Loaded L"C:\\game\\binaries\\D3DCOMPILER_47.dll" … : builtin
    #
    # Wine FOUND the shipped file and loaded its OWN implementation over it, because d3dcompiler_47 is a DLL
    # wine implements and the default load order is builtin-first. Clausewitz compiles its `ps_5_0` shaders
    # from HLSL at runtime through that dll, and wine's from-scratch compiler rejects source that Microsoft's
    # accepts — so every shader fails and the renderer gives up. This is NOT a missing-file problem: depot
    # 529342 ships `binaries/d3dcompiler_47.dll`, and the exe's own directory is where wine resolves it.
    # Asking for the native one is the whole fix; with it, error.log carries ZERO E5000/E5002 lines and the
    # first run compiles and caches 6840 shaders under `shadercache/dx11/`.
    #
    # Scoped to this one DLL deliberately: `dxcompiler.dll`/`dxil.dll` (the SM6 path, also shipped beside the
    # exe) are NOT wine-implemented names, so they already load native and need no entry.
    wine.dllOverrides.d3dcompiler_47 = {
      value = "n";
      reason = "native: the engine compiles its ps_5_0 HLSL at runtime and wine's builtin d3dcompiler_47 rejects it (E5002/E5000 from vkd3d-shader) → 'Failed creating shader state' and exit. Depot 529342 ships the real dll beside the exe; native loads it and the errors go to zero.";
    };

    # ── HOW A WORKING LAUNCH LOOKS, FOR THE NEXT PERSON ───────────────────────────────────────────────────
    # ~90 s of first-run shader compilation behind the engine's own loading screen (it draws a live
    # "N shaders compiled so far" counter), then the frontend. Subsequent launches reuse `shadercache/`.
    # If it ever regresses, the engine's logs are the first stop and they are host-visible: the saveBinds row
    # above puts `logs/{system,error,debug,game,…}.log` straight into `$PROPNIX_SAVE_DIR/victoria-3/logs`.
    # `system.log` alone confirms CPU/RAM/GPU detection and `debug.log` traces VFS mount → worker spawn →
    # PDX SDK → adapter select → FMOD → shaders, so the failing stage names itself.
    #
    # NOT a blocker, so nothing is set for them — two DXVK complaints survive into the working run and are
    # cosmetic: `readMonitorEdidFromKey: Failed to get EDID reg key size` (no EDID in the wine registry) and
    # `DXGI: MakeWindowAssociation: Ignoring flags`.
    #
    # The suspects this file used to nominate are all EXONERATED by the working run: `nakama-sdk.dll`,
    # `fmod.dll`/`fmodstudio.dll` (debug.log: `pdx_audio2.cpp:614: Creating FMOD sound engine`) and the D3D11
    # path itself all initialise fine once the two knobs above are in place.
  }
)
