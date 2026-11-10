# Multi-depot and multi-store payloads

A title's game tree can arrive as several fixed-output derivations: Steam splits one build across
depots, and a title owned on two stores carries one row set per fetcher
(`fetchInfo.<fetcher>.<platform>`). The wine builder composes the list it is given as an ordered
union whose first element, the head payload, has special duties: it is the primary tree of
`C:\game`, the base of the launch cwd, and the tree the PE icon is extracted from. So the order of
rows in `versions.json` is load-bearing even when the depots are disjoint. This document states the
composition rule, the naming and store-selection facts that follow from the schema, and the measured
depot contents of each multi-payload title.

## The head payload

`payloads` is the list of game trees for the selected fetcher and platform; the wine builder takes
`head payloads` as the primary tree and the tail as co-base trees.

- The head is `C:\game`'s primary tree. A one-tree build binds it read-only at `drive_c/game`.
- It is the launch cwd (and `workingDir` is relative to it).
- It is the exe and icon source: `lib/icons/from-pe.nix` runs `wrestool` on `${head payload}/${exe}`
  at build time, so a head that lacks the exe is a hard build failure rather than a resolvable one.
- It is `PROPNIX_PAYLOAD` for a setup script.

With co-base trees, enabled DLC or `extraLowers`, `drive_c/game` becomes a read-only multi-lower
overlay that unions everything at mount time: enabled DLC first (a DLC that modifies a base file
wins), then `extraLowers`, then the payloads in declared order, leftmost winning. An enabled DLC or
co-base depot costs no second copy of the base. Setup scripts also get `PROPNIX_PAYLOADS`: every
game-content tree, `:`-joined in the same priority order minus `extraLowers` (enabled DLC, then the
primary tree, then the co-base depots). `payload_require <file>` (from mkSetupScript's payload
library) searches it and fails listing every searched tree on a miss. With DLC enabled the first
entry of `PROPNIX_PAYLOADS` is a DLC tree, because a complete-tree DLC is what the game opens.

When the depots are disjoint, priority arbitrates nothing and the only constraint on order is that
the depot holding `exe` comes first.

## Store selection with two stores on one platform

- `platformPreference` derives itself when one platform is pinned: the ratchet in
  `modules/app-options.nix` counts pinned PLATFORMS, not fetchers
  (`pinned = filter (p: any (f: fetchInfo.${f}.${p} != null)) platforms`).
- `fetcher` defaults to the first entry of `preferredFetchers` that pins the selected platform, and
  `preferredFetchers` defaults to `attrNames fetchers`, name-sorted, so `gog` precedes `steam`. A
  game never sets `fetcher` itself: `lib/tests/resolution.nix` holds `fetcherExceptions = [ ]` and
  fails the flake check when a game defines it. A Steam-first user sets
  `config.preferredFetchers = [ "steam" "gog" ]`; `.apply { fetcher = "steam"; }` overrides per
  build.
- The arms differ only in store integration (`steam.emu` on Steam, `galaxyStubDlls` on GOG,
  store-specific save folders), gated on `config.fetcher`.

## FOD names are part of the store path

A fixed-output derivation's store path is `hash(name, outputHash)`, so renaming a `pname` repoints
it at a path that does not exist yet and forces a refetch of that depot. `propnix pin --new` emits
placeholder `pname`s (and GOG `version` strings) that are reasonable but not house style, e.g.
`shadow-of-mordor-steam-241931` and `shadow-of-mordor-dlc-311670-311670` where house style is
`<pname>-<depotId>`. Renaming them is free only for someone willing to re-download the content.

`propnix pin` maps every store OS other than Linux to `x86_64-windows`, so a macOS depot it pins
lands under that key and has to be removed by hand.

## Baldur's Gate 3

Pinned on GOG (one tree, the played path) and on Steam (four depots, never launched). Measured
contents of the pinned Steam trees:

- Depot 1419652 (head), `bin/`, ~189 MB: `bg3.exe`, `bg3_dx11.exe`, `steam_api64.dll`, DXVK-adjacent
  vendor DLLs.
- Depot 1419653, `Launcher/`, ~190 MB: `LariLauncher.exe` + CefSharp + its own `steam_api64.dll`.
- Depot 1086941, `Data/`, ~137 GB: every `.pak`, plus `DotNetCore/` and `InstallScript.vdf`.
- Depot 1086942, `Data/Localization/`, 573 B: `language.lsx` only.

`language.lsx` in 1086942 is byte-identical to the copy in 1086941 (`cmp` clean), so the union order
between those two arbitrates nothing, and nothing else overlaps. 1086942 is pinned at build 24532579
(its `version` field), the other three at 25605617. 1419652 leads because `exe` and the icon live
there.

What carries over to Steam without having been run: the exe paths are identical (`bin/bg3_dx11.exe`
exists in 1419652), `workingDir = "bin"` is a property of the engine rather than the store, and the
LOCALAPPDATA save location is a Larian convention with no store suffix (`bin/bg3_dx11.exe` carries
the plain "Larian Studios" string, no GOG/Steam variant). The Steam depots carry no Galaxy DLL (zero
`*alaxy*` files across all four).

Depot 2330358 of the same app is not pinned. It is not DLC content: 126,748 files, 3.3 GB, almost
all of it `Data/Editor/` (gizmos, previews, wiki help), the rest
`Data/Mods/{Gustav,GustavDev,GustavX,Shared,SharedDev}/Story/RawFiles` and
`Data/Projects/GustavDev`, and not one `.pak`. It is Larian's modding-toolkit source data, not
Digital Deluxe content. As a `dlc.available` row it would union 126k editor files over the game dir
for no runtime effect and emit a bogus `steam.emu` entitlement (the projection would take depotId
2330358 as a DLC store appid, which it is not).

## Middle-earth: Shadow of Mordor

Owned on both stores, both pinning `x86_64-windows`; GOG is the default by name order.

The arms are byte-identical where it matters: `x64/ShadowOfMordor.exe` has sha256
`f5d72578f7e5fcf05e6d15d8bd231f763078620c8545f8464bb186e842279455` in both payloads, as do
`bink2w64.dll`, `d3dcompiler_46.dll` and `x64/default.archcfg`. Only `steam_api64.dll` differs: GOG
ships its own 427,008-byte bridge exporting exactly the 22 Steam API names the exe imports,
implemented on top of `Galaxy64.dll`; Valve's genuine file in the Steam depot is a different
121,256-byte binary with 62 exports.

The GOG build is the whole Game of the Year Edition plus the free HD texture pack in one tree.
Compared file by file against the GOG payload root, all 20 owned Steam DLC depots are byte-identical
subsets of it:

- 19 depots ship exactly one `layerNN_dlc_<name>.arch05` (68 to 232 bytes): the entitlement or patch
  layer for one skin, warband, rune, challenge mode or story campaign (Lord of the Hunt, The Bright
  Lord). All 19 files are present at the GOG root with identical sha256.
- Depot 311670 ("HD Content", the free licence) ships 22 high-mip `*_0.arch05` archives, 11.8 GB.
  All 22 are present at the GOG root with identical sha256 (checked in full on the small ones, by
  size and hash on the rest).
- The Steam base depot 241931 contains none of those 41 files; on Steam they are strictly DLC, pure
  additions to the 43 GB base.

So the GOG arm reaches GOTY+HD content with one FOD and no entitlement machinery, while the Steam
arm needs 21 FODs, the gbe_fork shim and `withAllDlc` for the same bytes. DLC rows exist only on the
Steam arm.

App 241930 also publishes depots 241934 and 241935, the macOS build: 241934 is a 46 MB
`Middle Earth Shadow of Mordor.app/` bundle (plus a `.DS_Store`) and 241935 is a 56 GB
`ShadowOfMordorData/` tree. `propnix pin` titles them "(macos, Steam)" and files them under
`x86_64-windows`, as it does every non-Linux store OS. They are not pinned: `lib/strategy.nix` has
no macOS platform, and unioning a Mach-O app bundle into a wine game dir would add ~102 GB of
closure for nothing. The Steam Windows game is depot 241931 alone.

The Steam `pname`s are the `propnix pin --new` placeholders. The 21 depots (43 GB base, 11.8 GB HD
content, 19 small layers) are realised under those names, so renaming them costs a ~55 GB
re-download. The GOG row's `shadow-of-mordor-win` is already house style.

The DLC attr names and `title` strings are derived from the archive filename each depot ships
(`Layer53_DLC_BloodHunters.arch05` → `blood-hunters`), with two corrected to the engine's own
spelling in `default.archcfg` (`layer13_dlc_EndChallenge` is `Layer13_DLC_EndlessChallenge` there,
and `Layer22_DLC_BlackHand` is `Layer22_DLC_PowerOfShadow`). They are stable identifiers, not
authoritative marketing names.

## Skyrim Special Edition

Pinned on GOG (one tree, the verified path) and on Steam (three depots, never launched). Measured
contents of the pinned Steam trees:

- Depot 489833 (head), ~21 MB: `SkyrimSE.exe` and nothing else.
- Depot 489832, ~7.9 GB, the install root: `SkyrimSELauncher.exe`, `steam_api64.dll`,
  `Skyrim_Default.ini`, `Skyrim.ccc`, the `Low/Medium/High/Ultra.ini` quality presets, `Data/` (the
  textures and the four master `.esm` files), `Skyrim/SkyrimPrefs.ini`.
- Depot 489831, ~6.4 GB: `Data/` (the remaining `.bsa` archives, the Creation Club `.esl`/`.esm`,
  `Data/Video`).

489833 is head so that `exe` and the PE icon behave exactly as on the GOG tree; `SkyrimSE.exe`
carries a 256 px icon (`icotool -l`). The head is also `PROPNIX_PAYLOAD`, which on the Steam arm
does not contain the quality presets, so the setup script finds them with `payload_require` over
`PROPNIX_PAYLOADS`; the same line is correct on the GOG arm, where they sit at the root of the one
tree.

The save folder name is store-specific, and both arms bind the same host directory (the save format
is identical, so a save from one store's build opens under the other's):

- GOG: `Documents\My Games\Skyrim Special Edition GOG`, from a `+file` trace of `SkyrimSE.exe`.
- Steam: `Documents\My Games\Skyrim Special Edition`, from the Steam build's own `installscript.vdf`
  (shipped in depot 489831), whose "Copy Folders" rule is `SrcFolder %INSTALLDIR%\Skyrim` →
  `DstFolder %USER_MYDOCS%\My Games\Skyrim Special Edition`. Steam seeds the directory the engine
  then uses, so the unsuffixed name is the Steam build's folder; it is not runtime-traced.

The two exes are different binaries: the Steam build's `SkyrimSE.exe` is SteamStub v3.1-wrapped (the
wrapper header decodes to signature `0xC0DEC0DF`, flags 0x6, appid 489830), the GOG build's is
unwrapped. A Steam launch would need `steam.emu.steamStub`, which the spec does not set because the
Steam build has never been launched. The Steam payload has no `Galaxy64.dll`;
its one Steamworks copy is `steam_api64.dll` at the install root (depot 489832).

## The Witcher 3

One GOG tree. A GOG build label is provenance, not content: a build labelled after a REDkit update
(`4.04a_REDkit_Update_2` was one) is the base-game build that shipped alongside a REDkit toolkit
release and contains no REDkit binaries (REDkit is a separate GOG product); the download is
determined by `buildId` regardless, and the pinned build's label is whatever versions.json carries
("5.01" at this pin). `goggame-1495134320.info` calls itself "Game of the Year Edition" while the
store product is "Complete Edition": GOG renamed the SKU without rewriting the `.info`. The content
is the same.

The Complete Edition needs no DLC rows. `launcher-configuration.json` declares one edition,
`completeEdition`, listing 21 DLC → path pairs (EP1 → `dlc/ep1`, EP2 → `dlc/bob`, DLC 01…20 →
`dlc/dlcNN`), and all 21 directories are in the base build: `dlc/` is 13 GB of the 52 GB payload,
`content/` (content0…content12) the other 38 GB. Hearts of Stone and Blood and Wine come with the
base pin.

## Civilization VI

Steam only. The Windows content is split across four depots of app 289070, pairwise disjoint at file
level (all six pairs share zero paths), so the game dir is a pure directory union:

- Depot 289072 (head), 55 MB, `Base/Binaries/Win64Steam/`: the exes, engine DLLs and the shipped
  `steam_api64.dll`.
- Depot 289071, 11 GB: `Base/{Assets,ArtDefs,Platforms}`, `Debug/`, `CTP/`,
  `DLC/<27 civ and mode packs>`.
- Depot 289085, 4.2 GB: `DLC/Expansion1` (Rise and Fall), `DLC/Expansion2` (Gathering Storm).
- Depot 289089, 142 MB, `LaunchPad/`: the 2K launcher (Qt5 + QtWebEngine + Xsolla).

The binaries depot leads because the PE icon is extracted from the head at build time (nine sizes,
16 px to 256 px); at run time the exe resolves through the union either way. Depot 289089 stays
pinned although nothing runs it: its `config.json` is the evidence for the renderer pick, and it is
142 MB of closure.

## Rust

Two depots, both pinned:

- Depot 252495 (head), 859 MB, the Windows x64 client: `RustClient.exe`, `Rust.exe`,
  `GameAssembly.dll`, `EasyAntiCheat/`.
- Depot 252494, 39 GB, OS-agnostic content: exactly one top-level `Bundles/` (items, textures, maps,
  shared).

Sizes are measured on the realised store paths, not Steam's headline install figure. 252495 goes
first although it is the numerically higher depot and the far smaller tree, because `RustClient.exe`
lives there. The two do not overlap.

## Victoria 3

Three base depots, disjoint at the top level, unioned read-only at launch:

- Depot 529341, `game/`: the data root (`common/`, `events/`, `gfx/`, `localization/`, `map_data/`,
  and the empty `dlc/` the DLC depots fill).
- Depot 529342: `binaries/`, `clausewitz/`, `jomini/`, `platform_specific_game_data/`, and the four
  `*_branch`/`_rev` provenance files.
- Depot 529345, `launcher/`: the Paradox launcher's assets and settings (the launcher itself is not
  in the depot, only its installer).

The order is the pin order; with disjoint trees it arbitrates no content. The exe-holding depot
(529342) is not the head, so PE icon extraction, which reads `${head payload}/${exe}`, has no exe to
read. The icon is the launcher depot's own 512x512 app icon (the gold "V3" monogram), named
explicitly with `icon.png = "${lib.elemAt config.payloads 2}/launcher/assets/app-icon.png"`; an
explicit `icon.png` wins over extraction.
