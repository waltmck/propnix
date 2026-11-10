# Steam DLC ids: depot id, store appid, engine id

Three different numbers can name one Steam DLC: the depot id its content ships in, the store appid
Steam's appinfo assigns it (`dlcappid`), and whatever id the engine itself asks `ISteamApps` about.
propnix's offline entitlement (gbe_fork, see [steam-entitlement.md](steam-entitlement.md)) claims,
for each enabled pack, its pin row's `dlcAppId` when versions.json states one and its `depotId`
otherwise; `steam.emu.extraDlc` adds ids the engine asks about that neither field carries. Getting
any of the three wrong is silent: the pack is mounted, nothing logs an error, and the content stays
locked. This page records, per title, which convention holds and how it was established.

## Conventions

| title | depot id = store appid? | engine asks about | pin rows carry |
|---|---|---|---|
| Stellaris | yes (Paradox's depot-per-DLC allocation) | store appid | `depotId` only |
| Civilization VI | yes, all seven packs | store appid (mapping not located) | `depotId` only |
| Cities: Skylines | no: depots of base app 255710 | store appid | `dlcAppId` |
| Factorio | no: Space Age is app 645390 | store appid | `dlcAppId` |
| Civilization V (Linux) | no | the `<SteamApp>` in each `.civ5pkg` | `dlcAppId` + `extraDlc` |

## How to establish the mapping

- **Store API.** `store.steampowered.com/api/appdetails` returns `success: false` for an id that is
  a depot rather than an app. A real DLC appid returns the store product, whose name is the title to
  record.
- **Appinfo.** The base app's appinfo lists a `dlcappid` per DLC depot; that is the store appid a
  user owns.
- **Name cross-checks.** Store titles against the payload's directory names and the game's own UI
  strings; each title below agrees on all three.
- **Engine ids.** Grep the DLC trees for whatever the engine reads (Civ V:
  `grep -rhoE "<SteamApp>[0-9]+" <dlc trees>`), and search the binaries for each appid as text and
  as a little-endian u32.
- **Objective signal.** A game that builds a database from its active content shows whether a pack
  is active without clicking through the UI (Civ V: the gameplay cache, below).

## Cities: Skylines: depot ids in the base app's number space

The four radio-station packs are depots of the base app (255710), not of the DLC's own appid.
`store.steampowered.com/api/appdetails` for 255714/255717/255720/255726 returns `success: false`:
they are depot ids in app 255710's number space, not apps. Steam's appinfo for 255710 states the
mapping, and each depot is one of a windows/macos/linux triple that shares it:

| depots (win / mac / linux) | dlcappid | pack |
|---|---|---|
| 255714 / 255715 / 255716 | 547501 | Relaxation Station |
| 255717 / 255718 / 255719 | 614582 | Rock City Radio |
| 255720 / 255721 / 255722 | 614581 | Concerts |
| 255723 / 255724 / 255725 | 715192 | Carols, Candles and Candy (not owned, unpinned) |
| 255726 / 255727 / 255728 | 715193 | All That Jazz |

The names come from the Steam store API for those appids, and the payloads agree: the `Relaxation`,
`Rock`, `Concerts` and `Jazz` station directories match one for one, and the game's UI strings
(Assembly-CSharp: `DLCPANEL_RELAXATIONSTATION`, `DLCPANEL_RADIOROCKCITY`, `DLCPANEL_CONCERTS`,
`DLCPANEL_JAZZ`) name the same four. Assembly-CSharp gates the content on `SteamHelper`, so the
entitlement must carry the dlcappid; the depot id would project a bogus entitlement.

Each pack is a pure additive union under `Files/Radio/{Music,Talk,Blurb}/<Station>/*.ogg` (39, 15,
30 and 36 files; no file outside `Files/Radio/`; every station directory is new, the base depot
shipping only Cities/GoldFM/Mars/Classical and a JadiaRadio commercial set). `.withAllDlc` builds;
the packs are not verified as owned in the in-game Content Manager.

## Civilization V: the engine asks about the descriptor's `<SteamApp>`

On the Linux side the depot id is never the store appid (the Windows depots double as appids; Linux
depots 282303-282326 do not), so every row states `dlcAppId`, taken from app 8930's appinfo
`dlcappid` per depot (282303 → 16865, the Mongols pack).

That id is still not what the engine asks about. Civ V's ContentManager walks every
`steamassets/assets/dlc/*/*.civ5pkg` descriptor it finds and asks `ISteamApps` about the
`<SteamApp>` written inside that file:

    assets/dlc/dlc_01/mongol.civ5pkg   <SteamApp>34495</SteamApp>     depot 282303, dlcappid 16865

With only the store ids claimed, `withAllDlc` mounts all 18 packs and the game shows none of them,
with no log line and no error. Every pack's descriptor id differs from its store id. The descriptor
ids are claimed in addition to the store ids (which the account does own):

| pack | depot | store dlcappid | descriptor `<SteamApp>` |
|---|---|---|---|
| mongols | 282303 | 16865 | 34495 |
| spain-and-inca | 282304 | 16867 | 34497 |
| polynesia | 282305 | 99610 | 102000 |
| denmark | 282306 | 99611 | 102001 |
| korea | 282307 | 99612 | 102002 |
| wonders-of-the-ancient-world | 282308 | 99613 | 102003 |
| digital-deluxe | 282309 | 16864 | 34494, 34498 (Babylon's descriptor) |
| babylon | 282310 | 16868 | 34494, 34498 |
| explorers-map-pack | 282311 | 16866 | 34496 |
| scrambled-continents | 282312 | 235584 | 235587 |
| scrambled-nations | 282313 | 235585 | 235588 |
| cradle-mediterranean | 282314 | 16860 | none (no descriptor) |
| cradle-asia | 282315 | 16861 | none |
| cradle-americas | 282316 | 16862 | none |
| cradle-mesopotamia | 282317 | 16863 | none |
| gods-and-kings | 282318 | 16870 | 210450, 210451 |
| brave-new-world | 282320 | 235580 | 235582, 235583 |
| conquest-of-the-new-world | 282326 | 266720 | 266721 |

- The four `cradle-*` packs ship a single `.civ5map` and no descriptor, so nothing gates them and
  the map simply appears in the map list.
- `digital-deluxe` ships Babylon's descriptor (Babylon is the deluxe bonus civ), so it claims
  Babylon's pair. The two expansions each carry two ids: the expansion and its scenario set.
- Rows are keyed by appid, not by pack: gbe_fork keys its own DLC map by appid, so two packs naming
  34494/34498 would otherwise emit each id twice with different titles and one would silently win.
- Rows are gated on `dlc.enabled`: claiming a pack that is not mounted invites the engine to load
  content that is not there.
- The base payload's own `dlc/shared` (decals, buildings, strategic-view and UI art the packs draw
  from) carries `upgrade1.civ5pkg` with the sentinel `<SteamApp>99999`. That is not a real Steam
  app, so claiming it claims nothing purchasable, and answering "no" would deny the base game its
  own content. It is claimed ungated.

The descriptor ids live in a ~4 GB payload, so they cannot be read at eval time without
import-from-derivation; the game module states them, each grepped out of the pack's own descriptor.

The objective check is the gameplay database the engine builds from its active content:
`<save>/Sid Meier's Civilization 5/cache/Civ5CoreDatabase.db`. Measured 2026-09-17 with the packs
inactive, `sqlite3 … "select Type from Civilizations"` returns 20 rows and no `CIVILIZATION_MONGOL`.

## Civilization VI: depot id is the store appid; the engine's mapping is not visible

All seven owned packs ship as their own depot of the base app (289070), and each depot id is the
DLC's store appid, checked against each Steam store page:

| pack | depot = store appid | files | tree |
|---|---|---|---|
| aztec | 512030 | 6 | `DLC/Aztec_Montezuma/Data/*.xml` |
| vikings | 512032 | 283 | `DLC/VikingsScenario/` |
| poland | 512033 | 59 | `DLC/PolandScenario/` |
| australia | 512034 | 62 | `DLC/AustraliaScenario/` |
| persia-macedon | 512035 | 46 | `DLC/AlexanderScenario/` |
| nubia | 645400 | 122 | `DLC/NubiaScenario/` |
| khmer-indonesia | 645401 | 163 | `DLC/Indonesia_KhmerScenario/` |

The store titles are `Civilization VI: Aztec Civilization Pack`,
`Civilization VI: Vikings Scenario Pack`, and `Civilization VI: <name> Civilization & Scenario Pack`
for Poland, Australia, Persia and Macedon, Nubia, and Khmer and Indonesia.

Each tree is game-root-relative and holds exactly one `DLC/<PackName>/` directory. Measured against
all four base depots, six of the seven overlap in zero files, and no DLC modifies a base file.

### Civilization half and scenario half

The base depot 289071 ships 27 pack directories, most of them paid products, because a multiplayer
client has to render a civ another player owns: `DLC/Australia`, `DLC/Poland_Jadwiga`,
`DLC/Nubia_Amanitore`, `DLC/Indonesia_Khmer`, `DLC/Macedonia_Persia`, `DLC/VikingsLandmarks`,
`DLC/Babylon`, `DLC/RulersOf*`, … Those are the civilization half of each pack; the owner-only depot
ships the scenario half. Playability is gated at runtime, not by file presence: the UI layer calls
`Modding.ActivateAllowedDLC` and the engine decides "allowed" from the Steam entitlement it sees.
The entitlement, not the mounted tree, is what unlocks a civ.

`aztec` is the exception: its six files are byte-identical to files 289071 already provides (checked
with `cmp`), and the base depot also carries the pack's `.modinfo`, which the DLC depot does not.
The Aztec Civilization Pack is free for all Civ VI owners; the depot survives for the entitlement it
attests, not for content. Enabling it costs 74 KB and adds its row to the owned list; leaving it out
changes no file in the game dir.

### Where the engine maps an entitlement to a pack

The engine resolves `ISteamApps` at `STEAMAPPS_INTERFACE_VERSION008`, the only Steamworks interface
string in the exe and the revision carrying `BIsDlcInstalled`, `GetDLCCount` and
`BGetDLCDataByIndex`.

How it turns an entitlement answer into an unlocked pack is not visible statically. None of the
seven DLC appids appears in `CivilizationVI.exe`, `GameCore_Base`, `DatabaseDLL` or `Localization`,
searched both as text and as little-endian u32; the only Steam id present anywhere is 289070, once,
in the exe. The mapping is either a table not located or a name match over what `BGetDLCDataByIndex`
enumerates, which is the shim's `<appid>=<title>` list. Both inputs are therefore exact: real store
appids and real store titles. The titles in versions.json are the Steam store product names, with
the ` (Steam)` provenance suffix stripped when the list is generated.

Verified by building `withAllDlc`'s entitlement tree: `steam_settings/configs.app.ini` holds
`unlock_all=0` plus exactly seven `<store appid>=<store title>` rows, and the gbe_fork dll is
mirrored at the declared path with the settings beside it. Whether the game's UI shows the packs as
owned is not verified.

### Expansions without a depot of their own

Rise and Fall and Gathering Storm ride in base depot 289085 (`DLC/Expansion1` and `DLC/Expansion2`,
both in one depot, so it cannot be a per-DLC entitlement depot). Their content is always mounted,
but no depot derivation attests them, so the projection does not claim them and they read as
unowned, which leaves the expansion rulesets unselectable (inferred; not checked in the game UI).
Claiming them needs their own depots pinned as ordinary DLC rows with `dlcAppId` set (Rise and Fall
is store app 645402, Gathering Storm 947510). Hand-added ids with no depot behind them are exactly
the over-claim the entitlement builder refuses.

## Factorio: the contrast

Space Age is store app 645390 with depots 645391 (Linux) and 645393 (Windows), both of base app
427520. The depot id is not the DLC appid, so the rows carry `dlcAppId = 645390`.
