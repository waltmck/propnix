# Publisher launchers and why propnix bypasses them

Every packaged title starts its game binary directly, never the publisher's launcher, even where the
store marks the launcher as the primary play task. The launchers fall into two shapes: bootstrappers
whose job is to install a launcher application (an MSI or self-extractor carrying an Electron, CEF
or QtWebEngine stack) and then run it, and small stubs that spawn the game and exit. Neither
survives propnix's lifecycle, and neither contributes anything the vendor's own configuration files
do not already state: each launcher's config names the exe (and sometimes its arguments), and a
renderer option in a launcher is only an exe pick. Where a launcher writes game settings before
handing off, propnix does that in a `setupScript` instead. This document records, per title, what
the play-task files say and what the launcher actually is.

## Why a spawn-and-exit parent cannot be the launched process

propnix-launcher spawns wine on the configured `exe`, waits on that process, and tears the prefix
down (`wineserver -k`) when it exits. A launcher that spawns the game and exits therefore takes the
game with it: the primary child is gone, so the prefix is torn down. Starting the binary the
launcher would have spawned avoids the problem and loses nothing, because the hand-off is fully
described by the vendor's own files:

- GOG: `goggame-<productId>.info` lists the play tasks with their flags and fields (`isPrimary`,
  `isHidden`, `category`, `workingDir`, `additionalPaths`).
- Paradox (dowser): `launcher-settings.json` gives `exePath`, `exeArgs` and `gameDataPath`.
- CD Projekt Red (REDlauncher): `launcher-configuration.json` gives the executable(s).
- Larian (LariLauncher): `Launcher/launcher.cfg` maps renderer names to exes.
- 2K (LaunchPad): `LaunchPad/config.json` lists play entries per title id.
- Steam: the appinfo launch options, and the depot's install script.

## Paradox: dowser and the Paradox Launcher

### Cities: Skylines

The Steam Windows depot ships four items of launch surface:

| file | size | what it is |
|------|------|------------|
| `Cities.exe` | 22.8 MB | the Unity player (the game) |
| `dowser.exe` | 7.9 MB | Paradox Launcher bootstrapper |
| `launcher-installer-windows_2024.10.msi` | 126.6 MB | the launcher, as an MSI to install |
| `LauncherAssets/` | | the launcher's theme |

Steam's appinfo names `dowser.exe` as the default Windows launch option, plus a second, explicit
option `"description": "baseline launch", "executable": "Cities.exe"` on the `baseline` betakey.
propnix takes the latter. `dowser.exe` is a Go binary (its string table carries `--pdxlGameDir`,
`--gameDir=` and an `%s_.*\.msi` pattern) whose whole job is to install and run the Electron-based
Paradox Launcher out of that 126 MB MSI, i.e. a Chromium stack under wine plus an installer step.
The launcher's own `launcher-settings.json` states everything it would contribute:

    { "exePath": "Cities.exe", "gameDataPath": "%LOCALAPPDATA%/Colossal Order/Cities_Skylines",
      "version": "1.21.1-f9", "distPlatform": "steam",
      "steamWorkshopDisabled": true, "steamModsMigrationDisabled": true }

`Cities.exe` is what the launcher execs. `steamWorkshopDisabled` means this build is already cut
over from Steam Workshop to Paradox Mods upstream, so bypassing the launcher removes no mod source
the build had.

### Victoria 3

Here bypassing is the only option the payload offers. Depot 529345 (`launcher/`) ships
`launcher/dowser.exe` and `launcher/launcher-installer-windows_2026.10.exe`, an InstallShield
self-extractor (per `file`); the launcher proper is installed by Steam after download and is not in
the content. `launcher/launcher-settings.json` records what it would exec:

    "exePath": "../binaries/victoria3.exe", "exeArgs": [ "-gdpr-compliant" ]

Its one `alternativeExecutables` entry is the same exe plus `-debug_mode`. The sibling
`binaries/victoria3_win_console.exe` is not a second game build: it is a 166 KB CUI-subsystem shim
whose whole import table is SHLWAPI + KERNEL32, the "give me a console window" wrapper. The same
file states the data root, `"gameDataPath": "%USER_DOCUMENTS%/Paradox Interactive/Victoria 3"`, with
`"ingameSettingsPath": "pdx_settings.json"` inside it.

### Stellaris (native Linux)

The Linux build's chain is `start.sh` → dowser → the Electron Paradox launcher.
`launcher-settings.json` records `"exePath": "./stellaris", "exeArgs": [ "-gdpr-compliant" ]`, and
that is what propnix runs.

### dlc_load.json

`dlc_load.json` belongs to the Paradox launcher (and to every third-party mod manager). Nothing in
propnix writes it, and with it absent the game disables nothing.

## CD Projekt Red: REDprelauncher and REDlauncher

### Cyberpunk 2077

`goggame-1423049311.info` lists exactly two play tasks:

    isPrimary=true              REDprelauncher.exe        category=launcher   1.6 MB
    isPrimary=false isHidden    bin\x64\Cyberpunk2077.exe category=game      60   MB

and `launcher-configuration.json` at the payload root says the same in one line:

    { "platform": "gog", "executablePath": "bin\\x64\\Cyberpunk2077.exe",
      "gameId": "cyberpunk2077" }

`REDprelauncher.exe` is the launcher's bootstrapper, not the launcher: a 1.6 MB Qt5/Poco/sqlite stub
(PE imports Qt5Core, Qt5Network, PocoData, PocoDataSQLite, sqlite3) whose job is to install
`REDlauncher-4.2.0.4.msi` (687 MB, beside it at the payload root) into
`%LOCALAPPDATA%\Programs\CD Projekt Red\REDlauncher` (the path the play task declares as an
`additionalPaths` filesystemPath) and then run that, which spawns `Cyberpunk2077.exe` and exits.
Going through it would mean an MSI install inside every prefix, a 687 MB Electron-class launcher,
and a parent that spawns the game and exits. Its only hand-off to the engine is the exe path already
spelled out in `launcher-configuration.json`.

REDmod is normally activated by REDlauncher passing the engine a modded flag; without the launcher
that flag would go in `exeArgs` (its exact spelling is not established).

### The Witcher 3

`goggame-1495134320.info` lists four launchable tasks:

    isPrimary=true   REDprelauncher.exe                                   category=launcher
                     REDprelauncher.exe --launcher-fallback="DirectX 11"  category=launcher
    isHidden         bin/x64_dx12/witcher3.exe  workingDir=bin/x64_dx12   category=game   91 MB
    isHidden         bin/x64/witcher3.exe       workingDir=bin/x64        category=game   86 MB

`launcher-configuration.json` shows what the launcher's renderer setting is:

    executables: [ { "DirectX 12": bin\x64_dx12\witcher3.exe },
                   { "DirectX 11": bin\x64\witcher3.exe } ],
    "fallback": "DirectX 12"

an exe pick and nothing more, so choosing `exe` (and the matching `workingDir`) is the launcher's
renderer setting. `REDprelauncher.exe` here is a 1.8 MB Qt5/Poco/sqlite bootstrapper that installs
`setup_redlauncher.exe` (642 MB, beside it at the payload root) into
`%LOCALAPPDATA%\Programs\CD Projekt Red\REDlauncher` (the `additionalPaths` filesystemPath the play
tasks declare) and runs that, which spawns `witcher3.exe` and exits: an installer run per prefix, a
642 MB launcher app, and a spawn-and-exit parent.

## Larian: LariLauncher (Baldur's Gate 3)

`goggame-1456460669.info` lists three play tasks:

    isPrimary=true   Launcher/LariLauncher.exe   category=launcher   121 KB
    isPrimary=false  bin/bg3.exe                 category=game        35 MB   (native Vulkan)
    isPrimary=false  bin/bg3_dx11.exe            category=game        34 MB   (D3D11)

LariLauncher is a .NET WPF app embedding CefSharp, so running it means Chromium under wine. Its own
`Launcher/launcher.cfg` shows its "DirectX 11 vs Vulkan" option is only an exe pick:

    { "vulkan": "..\bin\bg3.exe", "dx11": "..\bin\bg3_dx11.exe" }

Choosing `exe` is the launcher's renderer setting. On Steam the launcher is depot 1419653
(`Launcher/`, ~190 MB: `LariLauncher.exe` + CefSharp + its own `steam_api64.dll`).

## 2K: LaunchPad (Civilization VI)

`LaunchPad/config.json` lists, under the title's id (60193), exactly two play entries:

    { "steamappid": 289070, "exe": "Base/Binaries/Win64Steam/CivilizationVI.exe",
      "name": "DirectX 11" }
    { "steamappid": 289070, "exe": "Base/Binaries/Win64Steam/CivilizationVI_DX12.exe",
      "name": "DirectX 12" }

so LaunchPad's whole contribution is an exe pick. It is a Qt5 shell embedding QtWebEngine (Chromium)
plus the Xsolla store/login SDK (XsollaAuth, XsollaCore, XsollaDownloader, `aws-cpp-sdk-*`). It
ships as its own depot, 289089 (`LaunchPad/`, 142 MB), which stays pinned; nothing runs it. Its
`LaunchPad/vc_redist.x64.exe` is an installer propnix never runs (the VC++ imports resolve against
wine's UCRT builtins).

## Bethesda: SkyrimSELauncher (Skyrim Special Edition)

`SkyrimSELauncher.exe` is the `isPrimary` task: a 32-bit settings stub that spawns `SkyrimSE.exe`
and exits. On Steam it sits in depot 489832 (the install root). It is also the only thing that
normally writes `SkyrimPrefs.ini`'s display settings (the resolution) and a quality preset, so
bypassing it moves that job into the title's `setupScript`, which runs in the OUTER phase before
wine on every launch:

- Display, asserted every launch so it follows a resolution or monitor change: `iSize W` / `iSize H`
  from `PROPNIX_WIDTH` / `PROPNIX_HEIGHT` (the compositor's primary-output mode in physical pixels;
  left as-is when the launcher cannot read the display), `bFull Screen=1`, `bBorderless=0`,
  `bAlwaysActive=1`. The Creation Engine renders its backbuffer at `iSize` even in fullscreen (a
  100x100 `iSize` yields a 100x100 render), so `iSize` must equal the real display.
- Quality: `PROPNIX_QUALITY` = `low|medium|high|ultra` merges the shipped `Low.ini` / `Medium.ini` /
  `High.ini` / `Ultra.ini` (the presets the launcher's auto-detect would apply; Windows CRLF files)
  into `SkyrimPrefs.ini`; `default` or unset leaves the engine baseline. The presets set quality
  keys only (shadows, AA, water, grass, LOD), never `iSize`. There is no in-game quality menu.
- vsync: `iPresentInterval=0` when `PROPNIX_FPS` requests a cap (DXVK's cap forces IMMEDIATE
  present), `1` otherwise.

The file is written into the host save dir, which the store-specific save bind places under
`Documents\My Games\`.

## Other titles

- Homeworld Remastered Collection: `HWRStart.exe` (`isPrimary`) is the collection chooser; it lets
  the user pick HW1/HW2 Remastered or the Classics, spawns the picked game and exits. propnix starts
  `HomeworldRM/Bin/Release/HomeworldRM.exe`.
- Outlast: `OutlastLauncher.exe` (`isPrimary`, 32-bit) spawns the game and exits. propnix starts
  `Binaries/Win64/OLGame.exe`, the DRM-free build (`OLGame_R.exe` is the Mono/.NET DRM wrapper).
- Kerbal Space Program: `Launcher.exe` is the separate Private Division launcher; `KSP_x64.exe` is
  the `isPrimary` FileTask and what propnix starts.
- Space Engineers: no launcher. `Bin64/SpaceEngineers.exe` is the only exe in `Bin64` (`Tools/`
  holds two unrelated audio-converter exes), the same path Steam's install script uses for its
  cold-start task (`%INSTALLDIR%\Bin64\SpaceEngineers.exe -coldstart`).
- Middle-earth: Shadow of Mordor: no launcher. The one play task of category `game` is
  `x64/ShadowOfMordor.exe` (the other task is a `URLTask` to GOG's support page).
