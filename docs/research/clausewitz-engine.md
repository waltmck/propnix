# The Clausewitz engine (Victoria 3, Stellaris)

Paradox's grand-strategy titles run on the Clausewitz engine with the Jomini layer above it. propnix
packages two of them on different routes: Victoria 3 as the Steam Windows build under wine (FEX +
ARM64EC DXVK on aarch64, native wine on x86_64) and Stellaris as the Steam Linux build under box64
(native on x86_64). This doc collects what the engine does that a package has to match: where it
looks for its data, where it writes, what it derives, and what its logs say on a working launch.
Each section notes where Stellaris agrees or differs.

## Provenance and versions

Victoria 3's binaries depot (529342) ships the engine's own provenance files:
`clausewitz_branch.txt` = `caligula/release/1.13.x` and `caligula_branch.txt` = `release/1.13.11`
("caligula" is the title's internal codename), plus `clausewitz_rev.txt` and `caligula_rev.txt`. The
paths baked into `victoria3.exe` carry the same codename
(`C:\mnt\gsg\caligula\caligula\cw\clausewitz\…`). `launcher/launcher-settings.json` gives
`"version": "1.13.11 (Matcha)"`, and the frontend stamps
`Game Version: Matcha (1.13.11) / MP Checksum: a47f`.

Stellaris is the same engine family as a Linux ELF: `stellaris` with a statically linked SDL2, the
PhysFS asset VFS, no Mono, and two `$ORIGIN`-linked libraries, `libPDXSDK` and `libnakama-cpp`.

## What to launch

Both titles bypass the Paradox launcher and run what `launcher-settings.json` names, with
`-gdpr-compliant`: `../binaries/victoria3.exe` for Victoria 3 and `./stellaris` for Stellaris
(docs/research/publisher-launcher-bypass.md has the launcher chains).

## The data root: the VFS candidate set

### Victoria 3

`victoria3.exe`'s VFS bootstrap
(`C:\mnt\gsg\caligula\caligula\cw\clausewitz\pdx_core\vfs\virtualfilesystem_physfs.cpp`, PhysicsFS)
carries an ordered candidate set of relative paths, stored immediately beside its failure message
and its success message. File offsets in the 1.13.11 exe:

    0x4850a40  ../clausewitz
    0x4850a50  ../jomini
    0x4853110  ../../../game
    0x48533d0  ../../platform_specific_game_data
    0x48533f8  ../../../platform_specific_game_data
    0x4853420  ../game
    0x4853428  ../../game
    0x4853438  Mounted Data: {}
    0x4853450  No subdirs mounted for game dir from candidates: {}
    0x4853488  ../platform_specific_game_data

The set contains no bare `game`. The resolution base is therefore never the install root: one `..`
is the minimum, which lands on `binaries/`, the exe's own directory; the deeper variants exist for
editor and tool layouts further down. propnix's default cwd is the game root, one level too high for
every candidate, so the title sets `workingDir = "binaries"`. That is correct whether the engine
anchors on the cwd or on its own module path, since with this setting the two agree.

The install root is three disjoint depots unioned read-only: 529341 → `game/` (`common/`, `events/`,
`gfx/`, `localization/`, `map_data/` and an empty `dlc/`), 529342 → `binaries/`, `clausewitz/`,
`jomini/`, `platform_specific_game_data/` and the provenance files, 529345 → `launcher/`.

On a correct launch `debug.log` opens with four mount lines, one per data tree:

    virtualfilesystem_physfs.cpp:460: Mounted Data: C:/game/clausewitz
    virtualfilesystem_physfs.cpp:460: Mounted Data: C:/game/jomini
    virtualfilesystem_physfs.cpp:460: Mounted Data: C:/game/platform_specific_game_data
    virtualfilesystem_physfs.cpp:460: Mounted Data: C:/game/game

A wrong cwd shows as `No subdirs mounted for game dir from candidates: {}`.

### Stellaris

The Linux depot places the `stellaris` ELF at the payload root beside the data (there is no `game/`
subdirectory), and Clausewitz resolves its game root from the cwd, so the payload root is right and
`workingDir` stays null. The Linux ELF's own candidate table is not read out here.

## The data and settings root: `gameDataPath`

Both titles take their user-data root from `launcher-settings.json` and bind it whole.

- Victoria 3: `"gameDataPath": "%USER_DOCUMENTS%/Paradox Interactive/Victoria 3"`, with
  `"ingameSettingsPath": "pdx_settings.json"` inside it (`pdx_settings.json` is also a literal in
  `victoria3.exe`). Under wine that is `Documents/Paradox Interactive/Victoria 3` in the profile
  home (`drive_c/users/propnix/`). After a launch to the menu the bound directory holds
  `pdx_settings.json`, `logs/` (the 21 Clausewitz logs), `shadercache/dx11/`, `crashes/`, `dumps/`
  and `exceptions/`, and no sibling directory is created. The diagnostics stay beside the saves on
  purpose: host-visible logs are what makes a regression debuggable.
- Stellaris: `"$LINUX_DATA_HOME/Paradox Interactive/Stellaris"` (= `XDG_DATA_HOME`), bound at
  `.local/share/Paradox Interactive/Stellaris`; it holds saves, settings, mods, `dlc_load.json`,
  `dlc_signature` and `logs/`.

`dlc_load.json` belongs to the bypassed Paradox launcher (and to third-party mod managers); with it
absent the engine disables nothing. propnix writes it for neither title.

## Derived data: the shader cache goes to `$PROPNIX_CACHE`

Victoria 3 compiles its `ps_5_0` HLSL at runtime and caches the result under `shadercache/dx11/`
inside the data root: 6840 files on a first run, all derived. Deleting the directory makes the next
launch rebuild it from the payload, and a driver or DXVK bump invalidates it anyway, so a restored
backup of it is worth nothing. It is routed to `$PROPNIX_CACHE/shadercache`
(`$XDG_CACHE_HOME/propnix/victoria-3/shadercache`), the directory that also holds the launcher's
DXVK/vkd3d caches:

    { src = "$PROPNIX_CACHE/shadercache";
      dst = "Documents/Paradox Interactive/Victoria 3/shadercache"; }

- One directory row, not per-file rows: Clausewitz keeps its cache in a subtree of its own rather
  than interleaved with the saves, so one bind routes all of it, and a future backend sibling of
  `dx11/` lands in the cache too.
- It nests under the data-root row deliberately. propnix-mount sorts parents first and stubs a
  missing child mountpoint into the parent's child skeleton, so `shadercache` exists inside the view
  without an empty stub directory appearing in the host save dir.
- The runtime compile goes through the shipped `d3dcompiler_47.dll`, which needs
  `wine.dllOverrides.d3dcompiler_47 = "n"` (docs/research/wine-builtin-gaps.md).

Stellaris (the Linux GL build) carries no such row.

## DLC

Both follow the Paradox convention: each DLC is its own depot of the base app, and the depot id is
the DLC's store appid (docs/research/steam-dlc-appids.md). Each DLC tree is a pure directory union
into an empty base `dlc/` directory, and the `.dlc` descriptor is the ownership marker the engine
gates on.

- Victoria 3: `game/dlc/<dlcNNN_slug>/{<name>.dlc, <name>.dlc.json, thumbnail.png}` (plus `gfx/` for
  the two content packs). Each descriptor's `steam_id` equals its depot id: dlc002 "American
  Buildings Pack" = 2071471, dlc006 "Voice of the People Preorder" = 2366580, dlc008 = 2591240 (the
  `.dlc` calls it "Region Pack 1", the `.dlc.json` displayName is the store name "Colossus of the
  South"), dlc013 "Charters of Commerce" = 3450170. `game/dlc_metadata/00_dlc_metadata.txt` in the
  base depot lists the whole catalogue by `steam_id`.
- Stellaris: `dlc/dlcNNN_<slug>/{dlcNNN.dlc, dlcNNN.zip, thumbnail.png}`. The gameplay script for a
  paid DLC already ships in the base build; the `.zip` carries only the DLC-exclusive assets.
  Entitlement goes through the Steam client: with the trees mounted and no shim, `SteamAPI_Init`
  fails ("did not locate a running instance of Steam"), the engine logs
  `dlc.cpp: Could not find item in store backend.`, and Additional Content lists every DLC as
  unowned. With the shim, three observables in the order they fail: `dlc_signature` exists in the
  data root (the engine saw the trees), `logs/error.log` has no "store backend" line (entitlement
  resolved), and the signature differs from the one a run with the same trees but no shim produces.

## The Paradox account SDK at boot

Victoria 3's exe statically imports `nakama-sdk.dll` (Paradox's multiplayer transport), `PDXSDK.dll`
(the Paradox account SDK) and WS2_32, and the game has cross-platform multiplayer, so `online` stays
true. `PDXSDK.dll` waits on a Steam logon state at boot (`pdx_account.cpp:600: Starting up PDX SDK`
in `debug.log` marks the point), and gbe_fork's offline mode answers "not logged on", which
deadlocks the engine before any log: the title sets `steam.emu.offline = false`
(docs/research/steam-entitlement.md has the hung-process analysis). Stellaris carries the Linux
`libPDXSDK` and leaves `steam.emu.offline` at its default.

## How a working Victoria 3 launch looks

Measured on x86_64-linux, 2026-09-03 (no aarch64 run is recorded for this title).

- About 90 s of first-run shader compilation behind the engine's own loading screen, which draws a
  live "N shaders compiled so far" counter; later launches reuse the cache.
- Then the frontend: Single player (Continue / New Game / Load Game), Multiplayer (Host / Join),
  Exit to Desktop, the DLC strip, and the version stamp
  `Game Version: Matcha (1.13.11) / MP Checksum: a47f`.
- DXVK 2.7.1 takes the device at `D3D_FEATURE_LEVEL_11_0` on the real adapter with a 1920x1080,
  4-image swapchain, and the engine's `contextowner.cpp:868: GPU Name:` line names the same card.
  The exe imports `d3d11.dll` and `dxgi.dll` (plus `dxcompiler` and `D3DCOMPILER_47`), so the
  default `d3d = dxvk` and winewayland apply.

### Reading the logs

The logs are host-visible at `$PROPNIX_SAVE_DIR/victoria-3/logs/{system,error,debug,game,…}.log`.
`system.log` alone confirms CPU, RAM and GPU detection. `debug.log` traces the boot in order, so the
failing stage names itself:

    VFS mount     virtualfilesystem_physfs.cpp:460: Mounted Data: …   (four lines)
    worker spawn  (the job-system threads: victoria3.exe:disk$0, :cs0, :sh0, :sh_opt0,
                  :traceq0, :gdrv0, :gl0)
    PDX SDK       pdx_account.cpp:600: Starting up PDX SDK
    adapter       contextowner.cpp:868: GPU Name: …
    FMOD          pdx_audio2.cpp:614: Creating FMOD sound engine
    shaders       the loading-screen counter; cache files under shadercache/dx11/

Two failure signatures and where they are explained:

- No window, no engine log, and the profile overlay's upper holding only gbe_fork's
  `AppData/Roaming/GSE Saves/settings/configs.user.ini`: the PDXSDK logon deadlock above. The crash
  reporter (`binaries/crash_reporter/CrashReporter.exe`, endpoint
  `submit.backtrace.io/paradoxinteractive/…/minidump`) never fires for it: it is a block, not a
  fault.
- `gfx_dx11_shaderstate.cpp:161: Failed getting shader for PixelTexture` /
  `gfx_dx11_master_context.cpp:521: Failed creating shader state`, with `error.log` full of
  `E5002: Can't implicitly convert from float2 to float3` and
  `E5000: Failed to evaluate constant expression`: wine's builtin `d3dcompiler_47` is compiling the
  HLSL (docs/research/wine-builtin-gaps.md).

### Cosmetic, not blockers

Two DXVK complaints remain in a working run and need nothing:

    readMonitorEdidFromKey: Failed to get EDID reg key size     (no EDID in the wine registry)
    DXGI: MakeWindowAssociation: Ignoring flags

### Cleared

`nakama-sdk.dll`, `fmod.dll`/`fmodstudio.dll` (`pdx_audio2.cpp:614: Creating FMOD sound engine`) and
the D3D11 path all initialise fine.

## Windows build or Linux build

Stellaris's Windows build hangs under FEX/ARM64EC: a worker thread overflows its stack during early
init and wine cannot dispatch the overflow. It is a genuine guest overflow that the ARM64EC
transition overhead inflates, and enlarging the stack reserve does not help (the extra space is
consumed). Stellaris therefore runs its Linux ELF under box64 with the native aarch64 SDL/GL/Vulkan
stack bridged in, which sidesteps ARM64EC.

Only Windows depots are pinned for Victoria 3 (app 529340), whether Paradox ships a Linux build of
it is not checked, and no aarch64 run of its Windows build is recorded. If a Linux build is pinned
it becomes a second platform for `platformPreference`, and the Stellaris finding is the reason to
rank it first on aarch64.
