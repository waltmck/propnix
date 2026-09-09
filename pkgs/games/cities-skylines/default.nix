# Cities: Skylines (Colossal Order / Paradox) — the Steam WINDOWS build via wine: on aarch64 through
# FEX + ARM64EC DXVK, on x86_64 natively. Unity **5.6.7f1** (read out of Cities.exe's version string),
# D3D11 renderer — the exe carries the whole `d3d11: …` diagnostic string table, so DXVK is the d3d layer
# that actually runs; the statically-imported OPENGL32.dll is Unity 5's `-force-opengl` fallback path,
# not the default.
#
# Steam-only, Windows-only: the fetch matrix has exactly that pair, so `platformPreference` derives
# itself and any other selection is a legible mkApp error. Steam DOES publish macOS (depot 255712) and
# Linux (255713) builds of the same build id — pinning the Linux one would add an `x86_64-linux` /
# box64 face later, but nothing here has been measured against it, so it is deliberately not pinned.
#
#   nix run .#cities-skylines --extra-sandbox-paths /propnix=/var/lib/propnix
#   nix run '.#cities-skylines.withAllDlc'
#
# ── WHICH EXECUTABLE, AND WHY NOT THE LAUNCHER ─────────────────────────────────────────────────────────
# The depot ships FOUR executables' worth of launch surface:
#   Cities.exe                              22.8 MB   the Unity player (the game)
#   dowser.exe                               7.9 MB   Paradox Launcher bootstrapper
#   launcher-installer-windows_2024.10.msi  126.6 MB  the launcher itself, as an MSI to be INSTALLED
#   LauncherAssets/                                   its theme
# Steam's own appinfo names `dowser.exe` as the default Windows launch option — and a second, explicit
# option `"description": "baseline launch", "executable": "Cities.exe"` on the `baseline` betakey. We take
# the latter: dowser is a Go binary (its string table carries `--pdxlGameDir`, `--gameDir=` and an
# `%s_.*\.msi` pattern) whose whole job is to install and run the Electron-based Paradox Launcher out of
# that 126 MB MSI — an entire Chromium stack under wine, plus an installer step, for a launcher whose own
# `launcher-settings.json` tells us the only thing we would learn from it:
#
#   { "exePath": "Cities.exe", "gameDataPath": "%LOCALAPPDATA%/Colossal Order/Cities_Skylines",
#     "version": "1.21.1-f9", "distPlatform": "steam",
#     "steamWorkshopDisabled": true, "steamModsMigrationDisabled": true }
#
# So launching Cities.exe directly loses no setup — it IS what the launcher execs. (Same call as
# pkgs/games/stellaris, which bypasses Paradox's `dowser` for the same reason.) NB `steamWorkshopDisabled`:
# this build has already been cut over from Steam Workshop to Paradox Mods upstream, so nothing here
# removes a mod source that the pinned build still had.
#
# Unity 5.6 resolves `Cities_Data/` from the executable's own directory, and the game's `Files/` content
# root sits beside it in the same payload root, so `workingDir` stays null (the game dir).
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
  appid = "cities-skylines";
  name = "Cities: Skylines";

  fetchInfo = versions.fetchInfo;

  exe = "Cities.exe";

  # ── REDIRECT THE UNITY PLAYER LOG OUT OF THE READ-ONLY GAME DIR ────────────────────────────────────────
  # Unity 5.6's default log path is `<gamedir>/Cities_Data/output_log.txt` (the literal is in Cities.exe),
  # and C:\game is a READ-ONLY bind of the store payload — so by default this title produces NO log at all,
  # which is exactly the state a first debugging session finds itself in.
  #
  # `-logfile <path>` IS supported by this player, and that is read off the binary rather than assumed:
  # Cities.exe carries Unity's ARGV-name table verbatim, `logfile` and `nolog` adjacent at 0x10c5430/38,
  # in the same block as `screen-fullscreen` / `screen-width` / `popupwindow` / `single-instance` /
  # `show-screen-selector`. The names are stored LOWERCASE, so the flag is spelled the way the table spells
  # it (`-logfile`, not the docs' `-logFile`) — an exact-compare parser then still matches.
  #
  # The target is the save bind below, i.e. a directory that is already writable AND already visible on the
  # host: the log lands at `$PROPNIX_SAVE_DIR/cities-skylines/output_log.txt`
  # (default `~/.local/share/propnix-saves/cities-skylines/output_log.txt`) with no extra mount row. The DOS
  # path is spelled out because `exeArgs` is passed to the child VERBATIM — the launcher does no `$VAR`
  # expansion on it (builders/wine.nix passes `cfg.exe_args` straight through) — and `propnix` is the FIXED
  # wine profile user (emulators/wine-prefix-lower.nix: "not an option; game tuning hardcodes
  # drive_c/users/propnix/…"), the same way baldurs-gate-3 spells its `--logPath`.
  #
  # This also RETIRES the write that could itself have been the hang: with the flag set the player never
  # opens the read-only path at all.
  #
  # WHY NOT the other obvious fix — a writable `Cities_Data` (a `wine.mounts` CoW overlay, the no-mans-sky /
  # KSP shape, cheap here at 420 files). Because `Cities_Data/Managed/` holds this title's MONO ASSEMBLIES,
  # and kerbal-space-program measured what serving Mono assemblies out of an overlay costs: mono_image_open
  # MAP_SHARED-maps each assembly, which the kernel does not handle for an overlay LOWER-layer file, and the
  # run dies with "mscorlib.dll could not be loaded". Turning a missing log into a broken runtime is the
  # wrong trade when a launch flag does the whole job; the mount-based route is only worth reaching for if
  # something is found that needs to WRITE into Cities_Data beyond the log.
  exeArgs = [
    "-logfile"
    "C:\\users\\propnix\\AppData\\Local\\Colossal Order\\Cities_Skylines\\output_log.txt"
  ];

  # Full-colour icon from Cities.exe's own PE resources — VERIFIED extractable: `wrestool -l` lists a
  # group-icon whose members run 16/24/32/48/64/96/128/192/256 px at 32-bit depth, so the hicolor theme
  # gets every size and the splash gets a true 256px source (no upscaling). This is the default; stated
  # here because it is a fact about the payload rather than a hope.
  icon.auto = true;

  # VERIFIED BY PLAYING (x86_64-linux, 2026-09-03) — see the launch block at the bottom for the evidence.
  # Blocks that are still static analysis say so where they stand.

  # Offline by construction: the launcher unshares a NETWORK NAMESPACE, so the guarantee is the kernel's
  # rather than the title's. Cities: Skylines is a single-player city builder; with the Paradox Launcher
  # bypassed (above) nothing in the launch path has a legitimate online feature we are taking away.
  #
  # BUT NOTE WHAT IS STILL IN THE PROCESS, because this is the block to revisit if something misbehaves:
  # Cities.exe statically imports WINHTTP/DNSAPI/WS2_32/IPHLPAPI (Unity's own stack), and the payload
  # carries two online SDKs as Unity native plugins — `Cities_Data/Plugins/EOSSDK-Win64-Shipping.dll`
  # (Epic Online Services) and `Cities_Data/Plugins/pops_api.dll` + `Managed/PopsApiWrapper.dll` (Paradox
  # Online Platform Services, i.e. the Paradox Mods / account backend). In a netns their connect() calls
  # fail IMMEDIATELY with ENETUNREACH rather than hanging on a timeout, which is the failure mode you want
  # — but the in-game Paradox Mods browser is exactly the feature that stops working, and the DLC panel's
  # "buy this DLC" links (Assembly-CSharp carries a store.steampowered.com URL) go nowhere.
  #
  # VERIFIED — the title starts fine with the network removed, and says so in its own log rather than
  # stalling. A netns'd boot to the main menu prints exactly the expected complaints and nothing else:
  #
  #   PopsApi: [CurlCallManager::update] FAIL '…' http status was none of 100, 200, 304: 0
  #   ApplicationException … at PopsApi.PopsApiWrapper.EndLegalGetDocumentsList … LegalDocumentLoader
  #   Error loading news feed: Cannot connect to destination host
  #   Paradox Account not linked to current Steam user account.  [HTTP]
  #
  # All four are IMMEDIATE failures (curl status 0, not a timeout), all are caught, and the menu comes up
  # with them on screen as an empty news panel. `.apply { online = true; }` is the one-line revert if the
  # Paradox Mods browser is wanted.
  online = false;

  # De-store-integration. The Steam library is `steam_api64.dll` AT THE PAYLOAD ROOT (beside Cities.exe),
  # and `Cities_Data/Plugins/ColossalNative.dll` is its only consumer — it names the library and the entry
  # points as plain strings (`steam_api64.dll`, `SteamAPI_InitSafe`, `SteamAPI_GetHSteamPipe`,
  # `SteamAPI_GetHSteamUser`, `SteamAPI_RegisterCallback`, `SteamAPI_RunCallbacks`,
  # `SteamAPI_RestartAppIfNecessary`, `SteamAPI_Shutdown`, `SteamClient`) and carries NO static import of
  # it, i.e. LoadLibrary + GetProcAddress by name. Every one of those names is exported by the pinned
  # gbe_fork PE shim (checked by export-table diff), so union-replacement resolves them all.
  #
  # On wine this declaration is REQUIRED, not optional: union-replacement at the declared path is the only
  # PE mechanism (no preload exists), and mk-app.nix refuses `steam.emu` on wine without a `.dll` path
  # rather than shipping a silently-inert shim.
  #
  # THE OLD SDK DOES COST SOMETHING, BUT NOT HERE — and the shape of the gap is worth stating exactly,
  # because the obvious reading of it is wrong and sent one session down a dead end. The shipped dll
  # advertises `SteamClient017` / `SteamUser018` (2015-era Steamworks), and an export-table diff finds 12
  # entry points it has and gbe_fork does not: `SteamAPI_ISteamUnifiedMessages_*` (5),
  # `SteamAPI_ISteamClient_RunFrame`, `…_Set_SteamAPI_CCheckCallbackRegisteredInProcess`,
  # `…_{Set,Remove}_SteamAPI_CPostAPIResultInProcess`, `SteamAPI_ISteamUtils_RunFrame`, and
  # `SteamAPI_ISteamApps_{Get,Request}PublisherOwnedAppData`. Those are FLAT-API exports, none of them
  # appears in ColossalNative's name table, and a GetProcAddress miss returns NULL rather than faulting the
  # loader — so as EXPORTS they really are unused, exactly as first reasoned.
  #
  # What that reasoning missed is that ISteamUnifiedMessages also occupies a VTABLE SLOT, and a slot cannot
  # be "unused": a method the shim's class does not declare shifts every method after it. That is what
  # actually broke this title, and `steam.emu.interfaces` below is the fix. Read that block before treating
  # any export-table diff as an all-clear for an old-SDK game.
  steam.emu.libPaths = [ "steam_api64.dll" ];

  # ── THE SHIM MUST HAND OUT THE 2015 VTABLES, NOT TODAY'S ──────────────────────────────────────────────
  # Every line here is read out of the payload's OWN `steam_api64.dll` (`strings`), which is what upstream's
  # `generate_interfaces_file` tool does and what makes this list a FACT about the binary rather than a
  # guess: this build links Steamworks SDK 1.34.
  #
  # WHY IT IS REQUIRED, MEASURED. Without it the shim keeps the revisions it was compiled against, and
  # `SteamClient()` hands ColossalNative a modern `ISteamClient`. Modern `ISteamClient` DROPPED
  # `GetISteamUnifiedMessages`, which `SteamClient017` still has at slot 25 — so the game's slot-25 call
  # lands on the shim's `GetISteamController`, which does not recognise the version string it is handed and
  # calls gbe_fork's `report_missing_impl_and_exit()`: a MODAL MessageBox followed by
  # `std::exit(0x4155149)`. OBSERVED on x86_64-linux 2026-09-03 and screenshotted out of the compositor —
  # a window titled "Missing interface" reading, verbatim:
  #
  #   INTERFACE=STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001
  #   CALLER FN=Steam_Client::GetISteamController()
  #   APPID=255710
  #
  # That is the whole "stops at the splash" symptom: with no visible desktop the modal is never dismissed,
  # so the process sits at 0% CPU with a full DXVK/Unity thread set and an unpainted window, forever.
  #
  # This also RETIRES the note that used to live on `steam.emu.libPaths`, which reasoned from the export
  # table that the 12 entry points gbe_fork lacks — the five `SteamAPI_ISteamUnifiedMessages_*` among them —
  # would be "unused, not broken" because a GetProcAddress miss returns NULL. That reasoning was sound about
  # the FLAT API and wrong about this title, which reaches ISteamUnifiedMessages through the C++ vtable,
  # where a missing method is not a NULL but a SHIFT of every slot after it.
  steam.emu.interfaces = [
    "SteamClient017"
    "SteamUser018"
    "SteamFriends015"
    "SteamUtils007"
    "SteamMatchMaking009"
    "SteamMatchMakingServers002"
    "SteamGameServer012"
    "SteamGameServerStats001"
    "SteamNetworking005"
    "SteamController003"
    "STEAMAPPS_INTERFACE_VERSION007"
    "STEAMUSERSTATS_INTERFACE_VERSION011"
    "STEAMREMOTESTORAGE_INTERFACE_VERSION013"
    "STEAMSCREENSHOTS_INTERFACE_VERSION002"
    "STEAMHTTP_INTERFACE_VERSION002"
    "STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001"
    "STEAMUGC_INTERFACE_VERSION007"
    "STEAMAPPLIST_INTERFACE_VERSION001"
    "STEAMMUSIC_INTERFACE_VERSION001"
    "STEAMMUSICREMOTE_INTERFACE_VERSION001"
    "STEAMHTMLSURFACE_INTERFACE_VERSION_003"
    "STEAMINVENTORY_INTERFACE_V001"
    "STEAMVIDEO_INTERFACE_V001"
  ];

  # ── DLC ── Four RADIO-STATION packs, each shipped as its own depot of the BASE app (255710) rather than
  # under the DLC's own appid. Each tree is a PURE ADDITIVE directory union into the game's content root —
  # `Files/Radio/{Music,Talk,Blurb}/<Station>/*.ogg` and nothing else (verified: 39/15/30/36 files, no
  # file outside `Files/Radio/`, and every station directory is NEW — the base depot ships only
  # Cities/GoldFM/Mars/Classical + a JadiaRadio commercial set). So no DLC ever shadows a base file, and
  # enabling one costs no second copy of the ~16 GiB base payload: they union read-only above it at mount
  # time.
  #
  # THE depotId IS NOT THE DLC's STORE APPID HERE — this is the case `fetchSteamDepot`'s `dlcAppId` exists
  # for, and getting it wrong would silently project a bogus entitlement. Paradox's Stellaris convention
  # (depotId == DLC appid) does NOT hold for Cities: Skylines: `store.steampowered.com/api/appdetails` for
  # 255714/255717/255720/255726 returns `success: false` — they are depot ids in app 255710's number space,
  # not apps. Steam's own appinfo for 255710 states the mapping, and each depot is one of a
  # windows/macos/linux TRIPLE that shares it:
  #
  #   depot 255714 (win) / 255715 (mac) / 255716 (linux)  dlcappid 547501  Relaxation Station
  #   depot 255717 / 255718 / 255719                      dlcappid 614582  Rock City Radio
  #   depot 255720 / 255721 / 255722                      dlcappid 614581  Concerts
  #   depot 255723 / 255724 / 255725                      dlcappid 715192  Carols, Candles and Candy  (not owned — unpinned)
  #   depot 255726 / 255727 / 255728                      dlcappid 715193  All That Jazz
  #
  # The names came back from the Steam store API for those four appids, and the payloads agree: the
  # `Relaxation`/`Rock`/`Concerts`/`Jazz` station directories match one-for-one, and the game's own UI
  # strings (Assembly-CSharp: `DLCPANEL_RELAXATIONSTATION`, `DLCPANEL_RADIOROCKCITY`, `DLCPANEL_CONCERTS`,
  # `DLCPANEL_JAZZ`) name the same four.
  #
  # STAGING THE FILES IS ONLY HALF THE JOB, exactly as for Stellaris: Assembly-CSharp gates content on
  # `SteamHelper`, so with the trees mounted and no Steam client the DLC panel would list them unowned.
  # Declaring `dlc.available` on a Steam fetch flips `steam.emu.enable` on (modules/steam-emu.nix), which
  # union-replaces steam_api64.dll with gbe_fork and PROJECTS the entitlement list off these very rows —
  # through `dlcAppId` above, never a hand-written list. Nothing here can name something unowned: a depot
  # derivation exists only because Steam issued this account its decryption key.
  #
  # NOT part of the base package: `cities-skylines` builds vanilla, so the default derivation does not
  # depend on the packager's entitlements. `.withAllDlc` / `.withDlc [ "all-that-jazz" ]` /
  # `.apply { dlc.enabled = [ … ]; }` select.
  #
  # The human check is the in-game Content Manager: the four stations appear as owned and their tracks
  # play. STILL UNVERIFIED — the vanilla build has been played to the main menu (bottom block) and its
  # Steam layer is live there (`API: Steam Type: Steam` in the game's own log, and the shim writes its
  # identity to `AppData/Roaming/GSE Saves/settings/configs.user.ini`), but nobody has yet booted
  # `.withAllDlc` and opened the Content Manager. `.withAllDlc` does BUILD.
  dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

  # Save + settings. `launcher-settings.json` states the game data root as
  # `%LOCALAPPDATA%/Colossal Order/Cities_Skylines`, and the game builds the same path itself (the
  # `Cities_Skylines` segment is a UTF-16 literal in Assembly-CSharp.dll; `Colossal Order`, `Saves` and
  # `Addons` — plus a `get_addonsPath` accessor — are literals in ColossalManaged.dll). That one directory
  # holds Saves/, Addons/ (mods, maps, assets), the userGameState config and the map/scenario editors'
  # output, so it is bound wholesale rather than split by kind. `dst` is HOME-relative; the wine builder
  # joins it onto drive_c/users/<user>/.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "AppData/Local/Colossal Order/Cities_Skylines";
    }
  ];

  # ── deliberately NOT set, so the next reader does not re-derive it ──
  #
  # * `presets.unity.framePacing` — INERT on this title. It writes Unity's `VidVSync_h382800143` /
  #   `VidTFR_h3151569246` PlayerPrefs, and neither name occurs anywhere in Cities.exe (grepped in every
  #   encoding `strings -e` offers, not just ASCII). Unity 5.6 predates the pref pair those hashes belong
  #   to; the only Screenmanager keys this player knows are `Screenmanager Is Fullscreen mode`,
  #   `Screenmanager Resolution {Width,Height}` and `Screenmanager Stereo 3D`.
  # * `presets.unity.fullscreen` — WRONG KEY for this title. The preset sets
  #   `Screenmanager Fullscreen mode_h3630240806`; Unity 5.6's pref is the differently-named (and therefore
  #   differently-hashed) `Screenmanager Is Fullscreen mode`. Writing the preset's value here would create
  #   a registry entry the game never reads. If the winewayland fractional-scale cursor confinement that
  #   motivates the preset does show up on this title, the fix is a hand-written `wine.userReg` row using
  #   the Unity-5 name, not this preset.
  # * a d3d/graphics override — none needed, and now measured rather than assumed. The tree defaults
  #   (DXVK + winewayland) bring the game up on the real GPU: the player's own log reports
  #   `Direct3D: Version: Direct3D 11.0 [level 11.1] / Renderer: AMD Radeon RX 7900 XTX (RADV NAVI31)`,
  #   and DXVK reports a 1920x1080 `VK_FORMAT_R8G8B8A8_UNORM` FIFO swapchain with 4 images.
  #
  # ── WHAT A LAUNCH ACTUALLY DOES ────────────────────────────────────────────────────────────────────────
  # VERIFIED RENDER, x86_64-linux, 2026-09-03: the MAIN MENU comes up and animates — the 3D city flyover
  # behind the logo, the "What's New" panel, the radio player showing "Downtown Radio", "0 / 5 mods enabled"
  # and the build string "1.21.1-f9" in the corner. Screenshotted out of the compositor across successive
  # captures (each frame differs, so it is a live render and not a stuck first frame), with the process
  # still alive when the harness killed it. The game's own log reaches `Game Version: 1.21.1-f9-steam-win`
  # and `API: Steam Type: Steam`, i.e. the Steam layer initialised through the shim.
  #
  # TWO BUGS STOOD BETWEEN THE STATIC BASELINE ABOVE AND THAT, and the first one is why the second stayed
  # hidden. Recorded because both produce the same useless symptom — "stops at the propnix splash":
  #
  #   1. A SHARED-DEFAULTS BUG, NOT THIS TITLE'S: `dosdevices` was mounted read-only, so mountmgr.sys's
  #      `add_drive()` spun forever retrying a symlink it could never make while holding `device_section`,
  #      and every other thread in the prefix blocked in any mountmgr IOCTL. Unity's first act after Mono
  #      init is such an IOCTL, which is exactly why the log used to stop one line after
  #      `Mono config path = …`. Fixed in lib/backends/wine/defaults.nix (ephemeral overlay); the fix
  #      unblocked several titles at once.
  #   2. THIS TITLE'S: the gbe_fork interface-revision mismatch — see `steam.emu.interfaces` above.
  #
  # CORRECTING THE RECORD, because the earlier reading of the empty run was recorded here as fact and it
  # was wrong. It said the title "stops BEFORE ColossalNative's LoadLibrary + SteamAPI_Init", inferred from
  # `AppData/Roaming/GSE Saves/settings/configs.user.ini` being absent. The inference was sound and the
  # premise was an artefact of bug 1: with `dosdevices` writable, that file IS written, the game DOES reach
  # SteamAPI_Init, and the real stall was one modal MessageBox later. An absent side-effect file proves
  # nothing about intent when the process is wedged in the kernel before it gets there.
  #
  # `steam.emu.offline` is still left at its default, but now for a checked reason rather than that wrong
  # one: the title initialises Steam and reaches the menu with `offline=1`, so there is nothing to trade.
  #
  # HARNESS NOTE for whoever repeats this. Headless **weston** is NOT a valid environment for these wine
  # titles — a known-good control (`iron-lung`) fails in it with the same "two Mono lines and die" signature
  # this title used to show, so a weston run cannot distinguish a real bug from the compositor. Headless
  # **sway** (`WLR_BACKENDS=headless`) passes that control on the real GPU and is what produced the render
  # above. Always boot the control first.
  #
  # RULED OUT by inspection, so nobody re-derives them: every DLL in Cities.exe's STATIC import closure
  # resolves (17 modules — ADVAPI32/DNSAPI/GDI32/HID/IMM32/IPHLPAPI/KERNEL32/OLEAUT32/OPENGL32/SHELL32/
  # SHLWAPI/USER32/VERSION/WINHTTP/WINMM/WS2_32/ole32, all present in the prefix lower's system32), and
  # `Cities_Data/` + `Files/` both sit beside the exe at the payload root, so the default cwd (the game dir)
  # is right and `workingDir` stays null — CONFIRMED by the run, which loads `Files/` content and every
  # `Cities_Data/Managed` assembly from `C:\game`.
}
