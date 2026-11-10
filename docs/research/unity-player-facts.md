# Unity player facts

Facts about Unity players that recur across propnix's Unity titles: how to read a player's version,
where its log goes and how to make it visible, which PlayerPrefs a given player actually reads (and
therefore which `presets.unity.*` fragments do anything), the fractional-scale cursor rule, and when
the Mono assemblies in `<Product>_Data/Managed` need a writable directory. The Mono runtime side
(the ARM64EC runtime, Unity's per-stream Mono branches, the export-coverage check) is in
docs/research/unity-mono-arm64ec.md.

| title | player | Mono runtime | player binary |
|---|---|---|---|
| Cities: Skylines | 5.6.7f1 | `Mono/EmbedRuntime/mono.dll` | `Cities.exe` |
| Kerbal Space Program | 2019.4.18f1 | MonoBleedingEdge | `UnityPlayer.dll` |
| Iron Lung | 2021.1.15f1 | MonoBleedingEdge | `UnityPlayer.dll` |
| R.E.P.O. | 2022.3.67f2 | MonoBleedingEdge | `UnityPlayer.dll` |
| Hollow Knight | 6000.0.61f1 | MonoBleedingEdge | `UnityPlayer.dll` |
| Hollow Knight: Silksong | 6000.0.50f1 | MonoBleedingEdge | `UnityPlayer.dll` |

Cities: Skylines predates the `UnityPlayer.dll` split: the player is the exe. Baby Steps, Papers,
Please, Rust and Iron Nest are IL2CPP builds (`GameAssembly.dll`, no `Managed/`).

## Reading the player version

The version lives in `UnityPlayer.dll`, or in the exe itself for a player that predates the split
(Cities: Skylines). It appears in several spellings, and which encoding carries the
`<version> (<12-hex hash>)` form depends on the player line. Measured on the pinned payloads, each
list in file order:

- 5.6.7f1 (`Cities.exe`). UTF-16: `5.6.7.15207619`, `5.6.7f1_e80cc3114ac1`. ASCII: `5.6.7f1`,
  `5.0.0a1`, `5.6.7f1 (e80cc3114ac1)`.
- 2019.4.18f1 (Kerbal Space Program). UTF-16: `2019.4.18.3346596`, `2019.4.18f1_3310a4d4f880`.
  ASCII: `2019.4.18f1`, `2019.4.18f1_3310a4d4f880`, `5.0.0a1`, `2018.3.0a1`,
  `2019.4.18f1 (3310a4d4f880)`.
- 2021.1.15f1 (Iron Lung). UTF-16: `2021.1.15.8790875`, `2021.1.15f1_86235bd3171b`. ASCII:
  `2021.1.15f1`, `2021.1.15f1 (86235bd3171b)`, `2021.1.15f1_86235bd3171b`, `2018.3.0a1`, `5.0.0a1`.
- 2022.3.67f2 (R.E.P.O.). UTF-16: `2022.3.67.7073210`, `2022.3.67f2 (6bedba8691df)`. ASCII:
  `2018.3.0a1`, `2022.3.67f2`, `2022.3.67f2 (6bedba8691df)`, `2022.3.67f2_6bedba8691df`, `5.0.0a1`.
- 6000.0.61f1 (Hollow Knight). UTF-16: `6000.0.61.7643309`, `6000.0.61f1 (74a0adb02c31)`. ASCII:
  `2018.3.0a1`, `6000.0.61f1`, `6000.0.61f1_74a0adb02c31`, `6000.0.61f1 (74a0adb02c31)`, `5.0.0a1`.

So:

- In 2022.3 and Unity 6 players the hash form is UTF-16 (and also ASCII). In 2021.1 and older it is
  ASCII only; the UTF-16 copy is the underscore form `<version>_<hash>`. Every player also carries a
  UTF-16 file-version string `<major>.<minor>.<patch>.<build>` with no release type.
- The ASCII strings include version-shaped values that are not the player's version (`5.0.0a1`,
  `2018.3.0a1`); in every measured player but Iron Lung's one of them precedes the hash form. Match
  the hash form first and fall back to a bare `<major>.<minor>.<patch><type><n>` only after it.
- Player.log prints the hash form at startup:
  `Initialize engine version: 2022.3.67f2 (6bedba8691df)`.

lib/builders/unity-mono-tree.nix reads the version this way (UTF-16 first, then ASCII; the hash form
before the bare form) to check a title's declared `unity.mono.stream`.

## The player log

### Unity 5.6: `<Data>/output_log.txt`, redirected with `-logfile`

A 5.6 player writes its log to `<gamedir>/Cities_Data/output_log.txt` by default (the literal is in
`Cities.exe`). `C:\game` is a read-only bind of the store payload, so by default such a title
produces no log at all.

`-logfile <path>` is supported, read off the binary: `Cities.exe` carries Unity's argv-name table
verbatim, with `logfile` and `nolog` adjacent at file offsets 0x10c5430 and 0x10c5438, in the same
block as `screen-fullscreen`, `screen-width`, `popupwindow`, `single-instance` and
`show-screen-selector`. The names are stored lowercase, so the flag is spelled as the table spells
it, `-logfile` (not the documentation's `-logFile`); an exact-compare parser then still matches.
With the flag set the player never opens the read-only default path.

Cities: Skylines points it into its save bind, a directory that is already writable and
host-visible:

    exeArgs = [
      "-logfile"
      "C:\\users\\propnix\\AppData\\Local\\Colossal Order\\Cities_Skylines\\output_log.txt"
    ];

The log lands at `$PROPNIX_SAVE_DIR/cities-skylines/output_log.txt` (default
`~/.local/share/propnix-saves/cities-skylines/output_log.txt`). The DOS path is literal because
`exeArgs` reaches the child verbatim (the launcher does no `$VAR` expansion on it), and `propnix` is
the fixed wine profile user.

### 2019.4 and later: Player.log under persistentDataPath

Later players write `Player.log` to `Application.persistentDataPath` =
`%USERPROFILE%\AppData\LocalLow\<companyName>\<productName>`, the same directory the engine uses for
save files, so a title's save bind catches it. The pair is the two lines Unity generates into
`<Product>_Data/app.info` from PlayerSettings (also present as literals in `globalgamemanagers`),
and it is used verbatim when neither name needs path-sanitising. Examples: `semiwork` / `REPO`,
`David Szymanski` / `Iron Lung`, `Iron Nest` / `Iron Nest Heavy Turret Simulator`.

`app.info` beats third-party guides: guides write R.E.P.O.'s path as `…\LocalLow\semiwork\Repo`,
while `app.info` says `REPO`, and a run through a `semiwork/REPO` bind leaves `MetaSave.es3`,
`SettingsData.es3`, `DefaultKeyBindings.es3`, `CurrentKeyBindings.es3`, `Cache/` and `Player.log` in
the save dir with no `Repo` sibling anywhere under the wine profile.

### Neither sink is an exact death point

- `-logfile -` sends the log to stdout, which the launcher forwards only with `PROPNIX_DEBUG=1`.
  Through that pipe stdout is block-buffered, so on Rust the visible tail lags the process by
  kilobytes.
- A short Player.log only says "killed or hung", not where: on Hollow Knight: Silksong's hang the
  file held 113 bytes while the process was alive.
- A log that ends one line after `Mono config path = …` is the host-level mountmgr stall on a
  read-only `dosdevices`, not a property of the title (docs/research/wine-mountmgr-dosdevices.md).
  While that stall is present, any A/B of the title's own mount shape compares two hanging runs.

## PlayerPrefs

### Key and value names

PlayerPrefs live under `HKCU\Software\<companyName>\<productName>` (the same `app.info` pair as the
save path). Each value name is `<pref name>_h<hash>`, where the hash is djb2 in its xor form over
the pref name's bytes: `h = 5381`, then `h = (h * 33) ^ byte` per byte, truncated to 32 bits. It
depends only on the name, so the same pref has the same suffix in every game. Checked against the
three names propnix writes:

| pref name | value name |
|---|---|
| `Screenmanager Fullscreen mode` | `Screenmanager Fullscreen mode_h3630240806` |
| `VidVSync` | `VidVSync_h382800143` |
| `VidTFR` | `VidTFR_h3151569246` |
| `Screenmanager Is Fullscreen mode` (Unity 5) | `Screenmanager Is Fullscreen mode_h3981298716` |

### Screenmanager prefs per player line

The `Screenmanager …` pref names each player binary carries (the prefix is omitted below):

- 5.6 (`Cities.exe`): `Is Fullscreen mode`, `Resolution Width`, `Resolution Height`, `Stereo 3D`.
- 2019.4 (KSP) and 2021.1 (Iron Lung): `Fullscreen mode`, `Resolution Width`, `Resolution Height`,
  `Resolution Use Native`, each also with a ` Default` twin, plus `Stereo 3D`.
- 2022.3 (R.E.P.O.) and 6000.0 (Hollow Knight): the 2019.4 set plus `RefreshRate Numerator`,
  `RefreshRate Denominator`, `Native RefreshRate Numerator`, `Native RefreshRate Denominator`,
  `Resolution Window Width`, `Resolution Window Height`, `Window Position X` and
  `Window Position Y`.

### `presets.unity.fullscreen`

The preset writes `Screenmanager Fullscreen mode_h3630240806` = REG_DWORD 1, the `FullScreenMode`
enum's FullScreenWindow (borderless fullscreen), with no resolution keys, so Unity uses the native
desktop resolution. It exists for the fractional-scale cursor confinement below.

- 2019.4 and later: the pref name is live in the player, so the row is read. R.E.P.O.
  (`Software\semiwork\REPO`), Baby Steps (`Software\DefaultCompany\BabySteps`), Iron Nest
  (`Software\Iron Nest\Iron Nest Heavy Turret Simulator`) and Papers, Please
  (`Software\3909\PapersPlease`) declare it. R.E.P.O. sets it by default because mouse-look with a
  confined cursor is unplayable; the confinement itself is unconfirmed on that title.
- Unity 5.6: the wrong key. The player reads `Screenmanager Is Fullscreen mode`, so the preset's
  value is a registry entry the game never reads. A 5.6 title that needs fullscreen takes a
  hand-written `wine.userReg` row under `Screenmanager Is Fullscreen mode_h3981298716`.
- A game that owns its screen mode in its own settings file overrides the pref at startup whatever
  the player knows: Kerbal Space Program's `settings.cfg` does, so its setup script maintains the
  display keys there instead.
- The pref, not `-screen-fullscreen`: the player applies the argument at startup and then the game's
  persisted setting reverts it (a fullscreen window flashes and drops back to windowed).

### `presets.unity.framePacing`

The preset writes `VidVSync_h382800143` and `VidTFR_h3151569246` to agree with the launcher's
`PROPNIX_FPS` modes. These two are not engine prefs. They are names from a title's own scripts:
Hollow Knight's `Assembly-CSharp.dll` carries them (UTF-16) among its `Vid*` settings
(`VidBrightSet`, `VidBrightValue`, `VidDisplay`, `VidDithering`, `VidFullscreen`, `VidNoise`,
`VidOSSet`, `VidOSValue`, `VidParticles`, `VidResRefresh`, `VidResX`, `VidResY`, `VidTFR`,
`VidVSync`), and none of the measured `UnityPlayer.dll`s (2019.4, 2021.1, 2022.3, 6000.0) contains
either name. Whether the preset does anything is therefore a property of the title's scripts, not of
its Unity version. Before declaring it, grep the player, the exe,
`<Data>/Managed/Assembly-CSharp.dll` and `<Data>/globalgamemanagers` in both encodings (`strings`
and `strings -el`).

- Declared by Hollow Knight, Hollow Knight: Silksong and Casualties Unknown Demo.
- Inert on Cities: Skylines: neither name occurs anywhere in the payload, in any encoding.
- Inert on R.E.P.O.: neither name occurs in `UnityPlayer.dll`, `REPO.exe`, `Assembly-CSharp.dll` or
  `globalgamemanagers`.

## Fractional-scale cursor confinement under winewayland

A windowed Unity game on a fractionally scaled output under winewayland confines its engine-drawn
cursor to the upper-left ~1/scale of the window (0.625 at scale 1.60) while wine's hardware cursor
roams freely: winewayland reports the client area at the logical size, so Unity's backbuffer and
`Screen` are logical. Fullscreen fixes it, which is what `presets.unity.fullscreen` is for. Some
titles then misplace the fullscreen window under winewayland and also need `graphics = "x11"`
(Papers, Please). The geometry measurements are in docs/research/winewayland-fractional-scaling.md.

## `<Data>/Managed`: when the assemblies need a writable directory

Two titles serve `<Product>_Data/Managed` from a per-launch, writable tmpfs seeded from the payload:
a source-less `wine.mounts` row (an ns-private tmpfs) plus `seed`, which copies the real assemblies
in at each launch.

    mounts."drive_c/game/Iron Lung_Data/Managed".seed = "${payload}/Iron Lung_Data/Managed";

Per title, where `Managed` is served from and what happens:

- Kerbal Space Program (2019.4.18f1): the seeded tmpfs loads. Serving `Managed` through the
  data-only `drive_c/game` overlay, a read-only bind or a plain overlay fails.
- Iron Lung (2021.1.15f1): the seeded tmpfs loads. The read-only `drive_c/game` bind fails.
- R.E.P.O. (2022.3.67f2): a two-lower read-only overlay (steam.emu's entitlement tree above depot
  3241661) loads all 143 assemblies.
- Hollow Knight: Silksong (6000.0.50f1): a multi-lower game dir loads.
- Hollow Knight (6000.0.61f1): the default game-dir mount loads.
- Cities: Skylines (5.6.7f1, the pre-MonoBleedingEdge runtime): the read-only `C:\game` bind loads
  every `Cities_Data/Managed` assembly.

### The signature that calls for the tmpfs

Player.log names mscorlib and the process aborts before any graphics init, with
`UnityCrashHandler64.exe` spawning:

    The assembly mscorlib.dll was not found or could not be loaded.
    It should have been installed in C:\game\Iron Lung_Data\Managed\mono\4.5\mscorlib.dll

Kerbal Space Program fails the same way ("mscorlib.dll could not be loaded"). Only the real
assemblies in a writable directory load for these two players.

### What does not call for it

- A Player.log that ends at `Mono config path = …` (the host stall above). That log never reaches
  assembly loading.
- Unity Mono behind a multi-lower overlay as such. R.E.P.O. reaches its menu with no such row:
  `Begin MonoManager ReloadAssembly` / `- Loaded All Assemblies, in 0.220 seconds`, then Odin
  Serializer, then the scene. Seeding its Managed would cost 21 MB of RAM and a 143-file copy on
  every launch. A userns replay of Silksong's mount table sees all 152 `Managed/` entries and reads
  `mscorlib.dll` over the overlay lower with both MAP_SHARED and MAP_PRIVATE.

The kernel-level cause of the KSP and Iron Lung failures is not established. The explanation that
`mono_image_open` MAP_SHARED-maps each assembly and overlayfs cannot serve that from a lower layer
is contradicted by the Silksong replay. What is measured is the per-player outcome listed above: the
two players that fail are the 2019.4 and 2021.1 lines, and the finding does not carry over to 2022.3
or Unity 6. KSP's player also waits on the 2019.4 stream of the ARM64EC Unity Mono runtime
(docs/research/unity-mono-arm64ec.md).
