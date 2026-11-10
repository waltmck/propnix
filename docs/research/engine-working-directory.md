# Engines that resolve assets from the working directory

propnix launches a game with the game root (`C:\game`) as its working directory unless `workingDir`
names a directory relative to it. Many engines instead assume the directory their vendor launches
them from, usually the exe's own, and build asset paths relative to the cwd with leading `..`
components. From the game root those paths climb out of `C:\game` to the drive root, and the failure
is rarely a clear error: archives silently fail to open, script lookups issue no reads, or the
engine logs one line and exits. The fix is one `workingDir` row. This document lists the evidence
that identifies the right value, and the measured behaviour of each title that needs one.

## Finding the right value

- GOG's `goggame-<productId>.info` play tasks carry a `workingDir` when the vendor launches from
  somewhere other than the install root. A task with none (Cyberpunk 2077) runs from the root; a
  task with one (The Witcher 3, Shadow of Mordor, Homeworld Remastered, Don't Starve) states the
  requirement.
- Steam's install script names the process path (Space Engineers:
  `%INSTALLDIR%\Bin64\SpaceEngineers.exe -coldstart`).
- The exe's or engine DLL's string table: asset path literals with a uniform `..\` or `../../../`
  prefix, or a path search list in an engine manifest, show which directory they are relative to.
- Setting the cwd to the exe's own directory is correct whether the engine anchors on the cwd or on
  its module path: with that setting the two agree.

## Baldur's Gate 3: `bin`

The engine derives its khonsu path roots as `<cwd>/../Data/...`. Dumped live out of its own
base-path global while running, per `workingDir`:

    <game root>  ->  "C:/game/../Data/Scripts"      == C:\Data\Scripts        (drive root, wrong)
    "bin"        ->  "C:/game/bin/../Data/Scripts"  == C:\game\Data\Scripts   (correct)

From the game root every root collapses to `C:\`, so the VFS key built from it never matches a pak
entry. The engine reads the pak's whole file list and then issues zero reads for any `Scripts/**`
entry (measured by instrumenting `ReadFile` to log byte ranges). The Lua definitions are then
missing, script code fails at runtime (khonsu error `0x10D`), and the game dies at the end of the
loading screen in engine state `LoadModule` at ~95 % of the progress bar, exit code 3 (the MSVC
CRT's `abort()`). `workingDir = "bin"` repairs every root at once (`Data`, `Public`, `Mods`,
`Projects`, `Localization`, `Scripts`), which is what a normal install gets by running from `bin`.

Materialising the script trees as loose files on disk appears to work, because it puts files where
the mis-computed root points, but it only moves the failure (`LoadModule` → `LoadLevel` → savegame
load) as each newly reachable subsystem hits the same root. Ruled out as causes: the position of
entries inside the archive (script entries span 10 % to 99 % of `Shared.pak`), memory mapping (the
engine never maps paks; plain `ReadFile` only), file-list truncation (the full list is read),
uncompressed entries, and `crc32`/AES hash divergence (the binary contains none of those
instructions).

## Middle-earth: Shadow of Mordor: `x64`

`goggame-1213504814.info` lists one play task of category `game`, `x64/ShadowOfMordor.exe` with
`workingDir="x64"`, and the engine's own manifest shows the value is required.
`x64/default.archcfg`, the archive search list the Firebird engine reads at startup, names every
asset pack relative, one directory up:

    ..\Game      ..\global.arch05      ..\udun.arch05      ..\Layer71_DLC_BrightLord.Arch05   …

From the game root those `..\` paths resolve to the parent of `C:\game`, the drive root, and every
archive, including the whole base game, silently fails to open. With cwd = `x64` they resolve to the
payload root.

Two more facts read off the same archcfg:

- The list is a static superset. It names `Layer40_DLC_ForgottenRunes.Arch05`, `DLC2_0.arch05` and
  `hotchunk_patch_0.arch05`, none of which exist in the GOG GOTY tree (the complete edition). The
  engine tolerates an absent archive, which is why the Steam DLC depots can be a pure additive union
  and why an unowned layer costs nothing.
- It spells several entries in a case the files do not use (`..\ui_gfx.arch05` for `UI_GFX.arch05`,
  `..\patch_1.arch05` for `Patch_1.arch05`). That is harmless on wine, whose NT path layer resolves
  names case-insensitively by directory scan, and would break on a case-sensitive native path.

## Civilization VI: `Base/Binaries/Win64Steam`

`CivilizationVI.exe`'s UTF-16 string table holds its asset path table with a uniform `../../../`
prefix: `../../../Base/Assets/Text/Localization.sqlite`, `../../../Base/ArtDefs`, `../../../DLC/`,
and one `../../../Base/Assets/Civ6_<hash>.xml` entry per shipped asset bundle. Three levels up lands
on the game root from exactly one place, `Base/Binaries/Win64Steam`; from the game root the same
strings resolve three levels above it, outside the mount namespace's game dir. With the setting, a
run on x86_64 (2026-09-03) reaches the front end and the Lua loader resolves the paths onto real
files:

    UserInterface.log  LOADING ../../../Base/Assets/UI/FrontEnd/IntroScreen.lua

and `Cache/Debug{Configuration,Gameplay,Localization}.sqlite` is built on first run.

## Space Engineers: `Bin64`

The engine's asset literals in `SpaceEngineers.Game.dll` are written relative to `Bin64`, e.g.
`..\Content\Textures\Logo\splashscreen.png`, and `Content/` sits at the game root, one level above
`Bin64/`. Steam starts the game the same way (the install script's `%INSTALLDIR%\Bin64\` process
path). The running game logs `Environment.CurrentDirectory: C:\game\Bin64` and then loads all of
`C:\game\Content\…` through it. `.apply { workingDir = null; }` reverts to the game root.

## Victoria 3: `binaries`

The Clausewitz VFS bootstrap in `victoria3.exe` resolves its data roots from an ordered candidate
set of relative paths, stored beside its failure message
`No subdirs mounted for game dir from candidates: {}`:

    ../../../game   ../game   ../../game
    ../../platform_specific_game_data   ../../../platform_specific_game_data
    ../platform_specific_game_data                        (and ../clausewitz ../jomini alongside)

The set contains no bare `game`, so the resolution base is never the install root: one `..` is the
minimum, which lands on `binaries/`, the exe's own directory, and the deeper variants serve editor
and tool layouts further down. With `workingDir = "binaries"`, `debug.log` opens with four
`virtualfilesystem_physfs.cpp:460: Mounted Data:` lines for `C:/game/clausewitz`, `C:/game/jomini`,
`C:/game/platform_specific_game_data` and `C:/game/game`. `.apply { workingDir = null; }` reverts.

## Homeworld Remastered Collection: `HomeworldRM/Bin/Release`

From cwd = `C:\game` the engine writes `HwRM.log` with ` Error starting up Data path. ` and exits
without a window; from cwd = `HomeworldRM\Bin\Release` it maps its "Homeworld Remastered" window
within ~12 s and stays up (measured 2026-09-03 on x86_64-linux). GOG's `goggame-2114871440.info`
agrees: the hidden "Homeworld Remastered" play task carries
`"workingDir": "HomeworldRM/Bin/Release"`. The engine reports its `.big` misses as
`..\..\DATAUPDATES\…`, cwd-relative from `Bin\Release`.

The cwd also places the engine's options file: `HomeworldRM.exe` opens the literal relative path
`../commandLine.txt`, which from `Bin\Release` is `HomeworldRM/Bin/commandLine.txt`. Moving
`workingDir` moves that file.

## Don't Starve: `bin`

Klei's engine resolves its data root from the cwd and expects the exe's own directory, finding
assets at `..\data` (the goggame `workingDir` is `"bin"`). From the game root it looks for `C:\data`
and dies at startup with `Missing Shader 'shaders/font.ksh'`.

## The Witcher 3: the exe's directory

Both game play tasks in `goggame-1495134320.info` declare a `workingDir` equal to the exe's
directory (`bin/x64_dx12`, `bin/x64`), so the package sets it to match the chosen exe, and switching
renderers changes both fields together:

    witcher-3.apply { exe = "bin/x64/witcher3.exe"; workingDir = "bin/x64"; }

## Titles that run from the game root

- Cyberpunk 2077: its GOG play task declares no `workingDir` (the play tasks of The Witcher 3 in the
  same `.info` format do), and REDengine 4 resolves `archive/pc/`, `r6/` and `engine/` from the game
  root.
- Cities: Skylines and R.E.P.O.: Unity resolves `<exe>_Data/` from the exe's own directory (Cities'
  `Files/` content root sits beside `Cities_Data/`).
- Skyrim Special Edition: `SkyrimSE.exe` resolves `Data/`, `*.ini` and the game root relative to its
  own location.
- Outlast: UE3 resolves content relative to the exe location.
- Stellaris (native Linux): the `stellaris` binary sits at the payload root, and Clausewitz resolves
  its game root from the cwd, the payload tree.
