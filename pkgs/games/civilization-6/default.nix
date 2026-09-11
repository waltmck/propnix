# Sid Meier's Civilization VI (Steam, x86_64 WINDOWS build) via wine — on aarch64 through FEX + ARM64EC,
# on x86_64 natively. Firaxis's in-house Civ6 engine (Havok Script/Lua gameplay layer, SQLite-backed
# gameplay+configuration databases, Bink video, SDL2 windowing — all shipped beside the exe as
# `*_FinalRelease.dll`). ARCH-AGNOSTIC: one spec for both hosts; mkApp + the scope pick the
# arch-appropriate emulator set and the SAME Windows payload (content-addressed FODs) is shared.
#
# Steam-only, Windows-only: the fetch matrix has exactly that pair, so both axes resolve with no ranking
# to declare, and any other selection is a legible mkApp error. Steam (not GOG) because Civ VI is not sold
# on GOG at all; Windows (not the Aspyr Linux build) because the Linux build is a separate, later-patched
# port whose depots are not pinned here.
#
#   nix run .#civilization-6 --extra-sandbox-paths /propnix=/var/lib/propnix
#
# NOT VERIFIED BY PLAYING IT. Everything below is read off the payload tree, the PE import tables, the PE
# string tables and the launcher's own config.json — the file paths, the renderer split, the save location
# and the entitlement wiring are all evidence-backed, but nobody has launched this build. Treat the
# "OPEN" notes as the list to check on first run.
#
# ── THE FOUR PAYLOAD DEPOTS, AND WHY THEY UNION CLEANLY ────────────────────────────────────────────────
# Civ VI's Windows content is split across four depots of app 289070, and MEASURED they are pairwise
# DISJOINT at file level (all six pairs: zero shared paths) — so the game dir is a pure directory union
# and no depot's overlay rank can shadow another's file:
#   289072   55 MB  Base/Binaries/Win64Steam/     the exes + engine DLLs + the shipped steam_api64.dll
#   289071   11 GB  Base/{Assets,ArtDefs,Platforms} + Debug/ + CTP/ + DLC/<27 civ & mode packs>
#   289085  4.2 GB  DLC/Expansion1 (Rise and Fall) + DLC/Expansion2 (Gathering Storm)
#   289089  142 MB  LaunchPad/                    the 2K launcher (Qt5 + QtWebEngine + Xsolla)
# BINARIES FIRST is not cosmetic: the wine builder takes `head payloads` as the PRIMARY tree — the one the
# PE icon is extracted from at BUILD time (lib/builders/wine.nix) — so the depot holding `exe` has to lead
# the list. (At RUN time the exe resolves through the union either way.)
#
# 289089 (the 2K LaunchPad) is carried even though we never run it — see the exe section, where its own
# config.json is the primary evidence for the renderer pick. It is 142 MB of Chromium-shaped launcher in
# the closure for a tree nothing opens; dropping the row is a one-line change if that trade reads wrong.
#
# ── WHICH EXECUTABLE, AND WHY THE DX11 ONE ────────────────────────────────────────────────────────────
# Three exes ship under Base/Binaries/Win64Steam (plus 7za/QtWebEngineProcess/vc_redist under LaunchPad):
#   CivilizationVI.exe        21 MB   imports d3d11.dll + dxgi.dll   PE product name "…VI (DX11) (Steam)"
#   CivilizationVI_DX12.exe   21 MB   imports d3d12.dll + dxgi.dll   PE product name "…VI (DX12) (Steam)"
#   FiraxisBugReporter.exe    2.5 MB  crash-report uploader, not a play task
# We launch a game binary DIRECTLY rather than LaunchPad.exe, and the LAUNCHER'S OWN CONFIG says that
# costs nothing: `LaunchPad/config.json` lists, under this title's id (60193), exactly two play entries —
#   { "steamappid": 289070, "exe": "Base/Binaries/Win64Steam/CivilizationVI.exe",      "name": "DirectX 11" }
#   { "steamappid": 289070, "exe": "Base/Binaries/Win64Steam/CivilizationVI_DX12.exe", "name": "DirectX 12" }
# — so the launcher's whole contribution for Civ VI is an exe pick, exactly like BG3's LariLauncher. And
# LaunchPad is the same kind of thing we avoid there: a Qt5 shell embedding QtWebEngine (Chromium) plus
# the Xsolla store/login SDK (XsollaAuth/XsollaCore/XsollaDownloader/aws-cpp-sdk-*), i.e. a whole browser
# under wine for a menu that picks between two paths we can name here.
#
# DX11 over DX12 is a deliberate default, not a coin flip:
#   * DXVK (d3d11 → Vulkan) is the tree's default d3d backend on x86_64 and the path every other wine
#     title here runs on (baldurs-gate-3, skyrim-se); the DX12 exe would instead land on vkd3d-proton,
#     which is wired but far less travelled in this repo.
#   * The payload itself treats DX11 as primary: `Civ6ToolHost_Win64_DX11_FinalRelease.dll` exists with no
#     DX12 counterpart, and config.json lists DirectX 11 first.
# `.apply { exe = "Base/Binaries/Win64Steam/CivilizationVI_DX12.exe"; }` is the one-line switch — the
# shader blobs for both renderers (ShaderAutoGen_Windows_DX11/DX12_FinalRelease.bs) already ship.
#
# ── BOTH GAME EXES ARE STEAM-DRM WRAPPED (SteamStub v3.1) — AND THAT IS WHAT `steam.emu.steamStub` IS FOR ─
# This is a fact about the payload that the rest of the file has to be read against, so it is stated up
# front. CivilizationVI.exe (and _DX12.exe identically) is not a plain PE: it carries a 10th section named
# `.bind` (206104 bytes, high entropy) and ITS ENTRY POINT IS INSIDE IT — 0x036d1310, while the real code
# starts at 0x00e950dc. Decoding the wrapper's own header (it sits at EntryPoint-0xF0, dword-XOR chained
# from its first dword) yields Valve's signature and the wrapper's parameters:
#
#     signature 0xC0DEC0DF   imagebase 0x140000000   OEP 0x00e950dc   appid 289070   flags 0x6
#     embedded payload: a 191336-byte AES-encrypted SteamDRMP.dll at .bind+0x39b0
#
# THE DECRYPTION IS NOT THE PROBLEM, which is the first thing a launch settles and the opposite of what was
# guessed here before anyone ran it. MEASURED (x86_64-linux, 2026-09-03, `PROPNIX_WINEDEBUG=+loaddll`): the
# wrapper unpacks and the engine loads — DatabaseDLL/Localization/HavokScript/bink2w64/EOSSDK, then dxgi +
# d3d11, then DXVK reads its own env. The process dies AFTER all that, at an OWNERSHIP CHECK, with exit 53.
#
# WHAT IT ASKS, AND WHY REPLACING `steam_api64.dll` CANNOT ANSWER IT. The wrapper manually maps its embedded
# SteamDRMP — Valve's own Steam API — and asks THAT. A wine `+relay` narrowed to OutputDebugString/
# ShellExecute names the caller directly:
#
#     Call KERNEL32.OutputDebugStringA("[S_API] SteamAPI_Init(): SteamAPI_IsSteamRunning() …")  ret=01054a4e
#     Call KERNEL32.OutputDebugStringA("[S_API] SteamAPI_Init(): Could not determine Steam …")  ret=01054c77
#     Call shell32.ShellExecuteA(0,"open","steam://run/289070//",0,0,1)                         ret=01053ec2
#
# — three return addresses in an anonymous ~0x0105xxxx mapping that is in NO loaded module (the exe is at
# 0x140000000, every DLL at 0x6FFF…/0x7FFF…), and `steam://run/%u//` is a format string that exists in the
# payload's shipped Valve `steam_api64.dll` and in no Firaxis binary. Two controls pin it down: binding
# gbe_fork's shim directly over the shipped dll (PROPNIX_EXTRA_BINDS) changed those three lines not at all,
# while binding a non-PE over the same path produced `err:module:import_dll … failed (c000012f)` — so the
# bind was live and the wrapper simply never consults that file. `steam.emu`'s union-replacement is INERT
# for this title's boot (it still matters afterwards, for DLC).
#
# WHAT DOES WORK — `steam.emu.steamStub = true` below. gbe_fork ships `steamclient_extra_x64.dll`, which
# patches SteamStub v3.1 in the process's own memory; propnix loads it from the DllMain of a proxy staged at
# the `steam_api64.dll` path, which runs before the exe's entry point. VERIFIED by running: the game boots
# through its Bink intro to a fully rendered front end. Two alternatives were tried and MEASURED not to work
# — gbe_fork's own `steam_settings/load_dlls/` hook (loads inside SteamAPI_Init, far too late: exit 53 and
# Valve's "Application load error 3:0000065432" dialog), and SATISFYING the wrapper instead of patching it
# (`HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64` → gbe_fork's steamclient, which the wrapper
# genuinely loads — "[S_API] SteamAPI_Init(): Loaded '…\steamclient64.dll' OK." — and then still refuses).
# The mechanism and its measurements live in emulators/gbe-fork/steamstub-proxy.nix.
#
# THE OTHER SteamStub'd PAYLOAD IN THE TREE is skyrim-se's STEAM face (SkyrimSE.exe — same signature, same
# flags 0x6, appid 489830), which pkgs/games/skyrim-se says has never been launched; everything verified
# there was measured on the GOG build, whose exe is a different, unwrapped binary. If that face is ever
# tried, this is the knob it will want.
{
  lib,
  mkApp,
  fetchSteamDepot,
}:
let
  versions = lib.importJSON ./versions.json;
in
mkApp {
  pname = "civilization-6";
  maintainers = [ "waltmck" ];
  appid = "civilization-6";
  name = "Sid Meier's Civilization VI";

  fetchInfo = versions.fetchInfo;

  exe = "Base/Binaries/Win64Steam/CivilizationVI.exe";

  # THE fix this engine needs, and the same shape as BG3's: run with the working directory set to the
  # executable's own directory. CivilizationVI.exe's UTF-16 string table holds its asset path table with a
  # uniform `../../../` prefix — `../../../Base/Assets/Text/Localization.sqlite`, `../../../Base/ArtDefs`,
  # `../../../DLC/`, and one `../../../Base/Assets/Civ6_<hash>.xml` entry per shipped asset bundle. Three
  # levels up lands on the game root from exactly one place: `Base/Binaries/Win64Steam`. With propnix's
  # default cwd (the game root) the same strings resolve three levels ABOVE it, i.e. outside the mount
  # namespace's game dir entirely.
  #
  # This is correct whether the engine anchors those paths on the cwd or on its own module path: if it
  # anchors on the module path, setting the cwd to that same directory changes nothing.
  workingDir = "Base/Binaries/Win64Steam";

  # Full-colour icon from CivilizationVI.exe's own PE resources — VERIFIED by building the extractor
  # against this payload: nine sizes come out, 16px through 256px. Extraction runs at BUILD time against
  # `head payloads` = the binaries depot, which is the reason that depot leads the fetchInfo list.
  icon.auto = true;
  # Symbolic vendored (CC BY-SA 4.0): the series' roman-numeral "VI" in a rounded frame.
  icon.symbolic = ./civilization-6-symbolic.svg;

  # ── ONLINE: left at the schema default (true), deliberately ──────────────────────────────────────────
  # Stated rather than defaulted silently, because for a Steam title with an entitlement shim the reflex
  # is `online = false` and that would be wrong here on the option's own terms ("silently cutting a game
  # off would break anything with legitimate online features"). Civ VI has real ones, and the exe says so:
  # `Attempting to MatchMake a multiplayer game.`, `Attempting to Join-by-SteamID multiplayer game. Steam
  # LobbyID: %llu.`, `AttemptConnectionToCrossPlayLobbyService`, `CROSSPLAY`, `AreCloudSavesEnabled`
  # (Play By Cloud), plus WS2_32/WINHTTP/IPHLPAPI imports and a bundled EOSSDK-Win64-Shipping.dll.
  #
  # There IS a real case for flipping it, and it is worth someone's evening: the same string table shows a
  # 2K/Firaxis Live logon on every startup (`AppFiraxisLiveClient starting logon due to app init
  # complete`) feeding a telemetry pipeline (`App::FiraxisLive::Telemetry::*`,
  # `App/FiraxisLive/OnlineTelemetryConfiguration.xml`, `App/FiraxisLive/MarketingMessage`), and the shim
  # below already answers `[main::connectivity] offline=1`, so Steam lobbies cannot work regardless of the
  # netns. The client also tracks its own connectivity (`OnBegin2KLoginProcess: my2kConnected=%s,
  # my2kLoggedIn=%s, myLinked=%s, flConnected=%s`) and logs `deferring logon`, which reads like a
  # non-blocking offline path — but reads is all it is.
  #
  # OPEN: does the main menu come up with no network? If yes, `.apply { online = false; }` buys a
  # kernel-enforced offline single-player/hotseat run at the cost of cross-play and Play By Cloud.
  online = true;

  # ── OFFLINE STEAM ENTITLEMENT ────────────────────────────────────────────────────────────────────────
  # THIS IS THE LOAD-BEARING PIECE FOR THIS TITLE, more than for any other game in the tree. Civ VI ships
  # every civ/leader pack's data in the BASE depots — 289071 alone carries DLC/Australia,
  # DLC/Poland_Jadwiga, DLC/Nubia_Amanitore, DLC/Indonesia_Khmer, DLC/Macedonia_Persia, DLC/Byzantium_Gaul,
  # DLC/Babylon, DLC/RulersOf*, … 27 pack directories, most of them paid products — because a multiplayer
  # client has to be able to RENDER a civ another player owns. Playability is therefore gated at RUNTIME,
  # not by file presence: the UI layer calls `Modding.ActivateAllowedDLC` and the engine decides "allowed"
  # from the Steam entitlement it can see. With no Steam client (and there is none for 16K-page aarch64),
  # the owner's own decrypted content reads as unowned. `steam.emu` (modules/steam-emu.nix) is what closes
  # that, and it is on by default for every Steam fetch.
  #
  # The declared path is the game's OWN shipped copy, which CivilizationVI.exe imports STATICALLY (verified
  # in the PE import table: SteamAPI_Init, SteamAPI_RestartAppIfNecessary,
  # SteamInternal_FindOrCreateUserInterface, … from steam_api64.dll). On wine the mechanism is
  # union-replacement: the entitlement tree mirrors gbe_fork's steam_api64.dll AT this path with
  # `steam_settings/` + `steam_interfaces.txt` beside it, and `extraLowers` outrank the payload — so the
  # PE loader file-maps the shim and its beside-the-library probe finds the settings. (That is also why
  # this is a `.dll` and not a `maskFiles` entry: a static import cannot be erased, and mk-app.nix refuses
  # steam.emu on wine with no `.dll` path declared rather than shipping a silently-inert shim.)
  #
  # NOT declared: `LaunchPad/steam_api64.dll`. The launcher ships its own copy, but we never run it, so a
  # second mirror + settings tree would be built for a file nothing opens.
  #
  # The engine resolves ISteamApps at `STEAMAPPS_INTERFACE_VERSION008` (the only Steamworks interface
  # string in the exe) — the revision carrying BIsDlcInstalled / GetDLCCount / BGetDLCDataByIndex, and the
  # exact revision builders/steam-offline-entitlement.nix already seeds into steam_interfaces.txt.
  #
  # UNRESOLVED, and the reason the DLC titles below are the exact store strings: HOW the engine turns an
  # entitlement answer into an unlocked pack is not visible statically. None of the seven DLC appids
  # appears in CivilizationVI.exe, GameCore_Base, DatabaseDLL or Localization — searched both as text and
  # as little-endian u32 — and the only Steam id present anywhere is 289070 (once, in the exe). So the
  # mapping is either a table we did not locate or a NAME match over what BGetDLCDataByIndex enumerates,
  # which is the shim's `<appid>=<title>` list. Both inputs are therefore set as accurately as they can
  # be: real store appids AND real store titles.
  steam.emu.libPaths = [ "Base/Binaries/Win64Steam/steam_api64.dll" ];

  # THE SteamStub SWITCH — what actually makes this title boot; see the header block for the wrapper and
  # the launch-observation block at the bottom for the measurements. With `steam.emu` alone (i.e. the shim
  # mirrored at the path above and nothing else) the process exits 53 having written nothing, because the
  # wrapper never asks that dll anything. This stages a proxy in front of it whose DllMain loads gbe_fork's
  # in-memory `.bind` patcher during LdrInitializeThunk — before the wrapper runs.
  steam.emu.steamStub = true;

  # ── DLC ──────────────────────────────────────────────────────────────────────────────────────────────
  # Seven owned packs, each shipped as its OWN Steam depot of the base app (289070). Each tree is
  # game-root-relative and holds exactly one `DLC/<PackName>/` directory — so the packs cannot collide with
  # each other, and MEASURED against all four base depots six of the seven overlap in ZERO files (the
  # seventh is `aztec`, below). No DLC modifies a base file:
  #
  #   aztec            512030      6 files   DLC/Aztec_Montezuma/Data/*.xml
  #   vikings          512032    283 files   DLC/VikingsScenario/
  #   poland           512033     59 files   DLC/PolandScenario/
  #   australia        512034     62 files   DLC/AustraliaScenario/
  #   persia-macedon   512035     46 files   DLC/AlexanderScenario/
  #   nubia            645400    122 files   DLC/NubiaScenario/
  #   khmer-indonesia  645401    163 files   DLC/Indonesia_KhmerScenario/
  #
  # The split is legible once you line the names up against the base depot: 289071 ships the CIVILIZATION
  # half of each pack (DLC/Australia, DLC/Poland_Jadwiga, DLC/Nubia_Amanitore, DLC/Indonesia_Khmer,
  # DLC/Macedonia_Persia, DLC/VikingsLandmarks) so any client can render it, and the owner-only depot ships
  # the SCENARIO half. Which makes the entitlement projection, not the trees, what actually unlocks the
  # civ.
  #
  # `aztec` is the exception and worth knowing about: its six files are BYTE-IDENTICAL to files 289071
  # already provides (verified with cmp), and the base depot even carries the pack's `.modinfo`, which the
  # DLC depot does not. That is the Aztec Civilization Pack having been made free for all Civ VI owners —
  # the depot survives for the entitlement it attests, not for content. Enabling it costs 74 KB and adds
  # its row to the owned list; leaving it out changes no file in the game dir.
  #
  # depotId IS the DLC's store appid for all seven — the same convention Stellaris documents, which is
  # really just Steam's default depot-per-app allocation — so no row needs a `dlcAppId` override. Not
  # assumed: each was checked against its Steam store page (512030 Aztec Civilization Pack, 512032 Vikings
  # Scenario Pack, 512033 Poland, 512034 Australia, 512035 Persia and Macedon, 645400 Nubia, 645401 Khmer
  # and Indonesia). Contrast factorio/versions.json, where Space Age is app 645390 with depots 645391/3 and
  # the override IS needed.
  #
  # NOT part of the base package: `civilization-6` builds vanilla, so the default derivation never depends
  # on the packager's own entitlements. `civilization-6.withAllDlc` / `.withDlc [ "vikings" … ]` /
  # `.apply { dlc.enabled = [ … ]; }` union the selected trees ABOVE the base at mount time, so an enabled
  # pack costs no second copy of the ~15 GiB base payload — and projects one `<appid>=<title>` entitlement
  # row apiece into the shim's `configs.app.ini` (`unlock_all=0` + the owned list). The titles in
  # versions.json are the exact Steam store product names because that list is ALSO what
  # GetDLCCount()/BGetDLCDataByIndex() enumerate, i.e. potentially a display string the game shows.
  # VERIFIED by building `withAllDlc`'s entitlement tree: `steam_settings/configs.app.ini` comes out as
  # `unlock_all=0` plus exactly seven `<store appid>=<store title>` rows (the " (Steam)" provenance suffix
  # stripped as intended), and the gbe_fork dll is mirrored at the declared path with the settings beside it.
  #
  # This is the set Steam issued this account decryption keys for; the rest of the catalogue is refused
  # (eresult 15) and so cannot appear here — the framework's ownership property, not a curated list.
  #
  # OPEN — the honest gap: RISE AND FALL and GATHERING STORM ride in base depot 289085
  # (DLC/Expansion1 + DLC/Expansion2, both in ONE depot, so it cannot be a per-DLC entitlement depot).
  # Their content is therefore always mounted, but they have no depot derivation of their own, so the
  # projection cannot attest them and they will read as UNOWNED — the expansion rulesets would be
  # unselectable. The fix, if this account owns them, is to pin THEIR depots as ordinary `dlc` rows with
  # `dlcAppId` set (Rise and Fall is store app 645402, Gathering Storm 947510) and let the framework
  # project them; hand-adding ids with no depot behind them is exactly the over-claiming
  # builders/steam-offline-entitlement.nix is built to refuse, so it is deliberately not done here.
  dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc;

  # ── SAVE / STATE ─────────────────────────────────────────────────────────────────────────────────────
  # The exe's UTF-16 string table has `/My Games/Sid Meier's Civilization VI` sitting next to
  # `AppOptions.txt`, `GraphicsOptions.txt`, `Logs`, `Saves`, `/ModUserData/`, `FiraxisLive.log` and
  # `Localization.log`, which reads as one Documents folder holding everything. A first boot says the
  # engine actually uses TWO directories, and the split is not the one those adjacent strings suggest —
  # MEASURED on the launch that reached the front end (x86_64-linux, 2026-09-03), by listing what each
  # location held afterwards:
  #
  #   Documents\My Games\Sid Meier's Civilization VI   HallofFame.sqlite, Mods\, ModUserData\   ← bound here
  #   %LOCALAPPDATA%\Firaxis Games\Sid Meier's …       AppOptions.txt, GraphicsOptions.txt,
  #                                                    UserOptions.txt, SoundOpts.txt, EOSOptions.txt,
  #                                                    InputSettings.json, Mods.sqlite, Logs\, Cache\,
  #                                                    Challenges\, dumps\, packagedDumps\
  #
  # So the Documents row below is the SAVE row and is correctly scoped: cross-game user content (the hall
  # of fame, installed mods and their user data — and `Saves\`, which only appears once a game is saved)
  # travels with `$PROPNIX_SAVE_DIR`. The second directory is the one the header's OPEN note asked about;
  # it is machine-shaped state (renderer settings, input bindings, the derived
  # `Debug{Configuration,Gameplay,Localization}.sqlite` cache, crash dumps) and it is NOT lost: nothing
  # binds it, so it lands in the PERSISTENT profile overlay upper (`$PROPNIX_STATE/wine/users`) and
  # survives across launches on its own.
  #
  # OPEN, now that both are known: whether the options half deserves a `$PROPNIX_SAVE_DIR` row of its own.
  # The argument for is that a user who moves their save folder to a new machine expects their graphics and
  # key bindings to follow; the argument against is that GraphicsOptions.txt is a statement about THIS GPU
  # and this display, and the same folder carries a derived SQLite cache and crash dumps that have no
  # business in a save dir. Left unbound rather than guessed — this needs the owner's taste, not a measurement.
  saveBinds = [
    {
      src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
      dst = "Documents/My Games/Sid Meier's Civilization VI";
    }
  ];

  # NO wine tuning. The tree defaults are what this title wants on their face and nothing here has been
  # measured, so overriding would be invention: d3d = dxvk (the x86_64-windows default, and the renderer
  # the chosen exe imports), graphics = wayland (BG3 A/B'd this and found no reason to force x11; the
  # fullscreen-Vulkan swapchain fault that pins Skyrim SE to x11 is title-specific). The VC++ runtime
  # imports (MSVCP140/VCRUNTIME140 + the api-ms-win-crt-* set) resolve against wine's UCRT builtins, as
  # they do for skyrim-se, so no `extraSystem32` staging — the depot's own LaunchPad/vc_redist.x64.exe is
  # an installer we never run. `bink2w64.dll`, `dbghelp.dll`, `SETUPAPI.dll`, `WINHTTP.dll` are likewise
  # untried rather than known-good.

  # ── WHAT LAUNCHING IT ACTUALLY DOES ───────────────────────────────────────────────────────────────────
  # RUNS (x86_64-linux, 2026-09-03, `nix run .#civilization-6` under a headless sway on an RX 7900 XTX):
  # window, Bink logo movies, the ~2.5-minute intro cinematic, then the front end — the CIVILIZATION VI
  # title card with its legal text and a live `Continue` button, screenshotted. The engine's own logs agree
  # and are the durable evidence:
  #
  #   Renderer.log     Renderer::CreateD3DDevice() → CreateDefaultSwapChain 1920x1080 @60, Fullscreen,
  #                    "Selected GPU device: AMD Radeon RX 7900 XTX (RADV NAVI31)"
  #   UserInterface.log  ForgeUI started up! … ContextBase::Initialize 'StartupScreen' / 'IntroScreen',
  #                    LOADING ../../../Base/Assets/UI/FrontEnd/IntroScreen.lua
  #   Modding.log / ArtDef.log / Lua.log / Database.log / Localization.log  all populated
  #
  # …which also settles three things this file used to only reason about: `workingDir` is right (the Lua
  # loader resolves `../../../Base/Assets/…` onto real files), the Havok Script + SQLite layers come up, and
  # `Cache/Debug{Configuration,Gameplay,Localization}.sqlite` really is built on first run.
  #
  # THE ONE THING THAT HAD TO CHANGE was `steam.emu.steamStub` — the header block has the wrapper's
  # anatomy and the relay trace. Before it, the launch looked like this, and the shape is worth keeping
  # because it is a TRAP: exits immediately (status 53), no window, and NOTHING written anywhere — save dir
  # empty, and the persistent profile overlay's upper (`$PROPNIX_STATE/wine/users`, which holds exactly what
  # a run wrote) empty as well, including gbe_fork's `AppData/Roaming/GSE Saves/settings/configs.user.ini`.
  # That last absence was read at the time as "died before the first Steam API call, therefore before the
  # engine". It is the opposite: `+loaddll` shows the engine fully loaded and DXVK initialising first. The
  # wrapper's ownership check runs inside the process's own startup, and losing it exits before the engine
  # opens a single file — so "not one byte written" bounds nothing about how far execution got. Reach for a
  # loader/relay trace before reading anything into an empty directory.
  #
  # A FIVE-WESTON DETOUR, recorded so the next person skips it: none of the above reproduces under
  # `weston --backend=headless` (with or without `--renderer=gl`). A known-good control (pkgs/games/iron-lung,
  # which the owner plays) fails there too — the game process never loads `winewayland.drv` and dies on
  # `err:winediag:nodrv_CreateWindow … The explorer process failed to start`. Headless SWAY
  # (`WLR_BACKENDS=headless`) passes the same control and is what these runs used. Weston writes almost
  # nothing, which is indistinguishable from this title's pre-fix symptom; always run a control first.
  #
  # STILL RULED OUT by inspection and NOT the story here, so nobody re-derives them: the STATIC import
  # closure resolves completely (44 modules — the engine's own `*_FinalRelease.dll` + EOSSDK + bink2w64 ship
  # beside the exe, the rest are prefix-lower system32 or apiset forwarders), and all 17 steam_api64.dll
  # entry points the exe imports STATICALLY are exported by the pinned gbe_fork PE shim. Note what that
  # second check is NOT worth: it is about the FLAT api, while a vtable-revision mismatch (the
  # pkgs/games/cities-skylines failure, and what `steam.emu.interfaces` exists for) shifts slots and would
  # pass an export-table diff untouched. It simply did not arise here — this title's front end comes up on
  # the default interface list.
  #
  # NOT the `steam.emu.offline` wall either, and it was tried: that option only changes what gbe_fork
  # ANSWERS (BLoggedOn/BConnected/GetLogonState), so it cannot matter to a wrapper carrying its own copy of
  # Valve's API — flipping it changed nothing. Left at its default.
  #
  # OPEN, for whoever plays past the front end (this was verified to RENDER, not to play):
  #   * Does the main menu's Single Player path start a game, and do the DLC/expansion rulesets show as
  #     owned? The entitlement projection is wired but has never been read back from the game's own UI, and
  #     Rise and Fall / Gathering Storm are known-unattested (see the DLC block).
  #   * `online = true` is still the default here and the FiraxisLive logon does run (`FiraxisLive.log` and
  #     `AppData/Roaming/FiraxisLive/<id>/` both appear). Whether the front end also comes up with the netns
  #     cut (`.apply { online = false; }`) is now a cheap experiment rather than a guess.
}
