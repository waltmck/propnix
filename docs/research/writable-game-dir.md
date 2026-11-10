# Games that write into their own install directory

`C:\game` is a read-only bind of the store payload, or a read-only multi-lower overlay when DLC,
`extraLowers` or co-base depots are present. A title that writes beside its own exe therefore fails,
and the failure often does not look like a file error: a managed exception repeated forever, a
SQLite "cannot open", a message box, a wild jump to an unmapped address, or no log at all. propnix
answers with a mount row scoped to what the title writes: a persistent copy-on-write overlay over
the whole game dir, an ephemeral tmpfs for a scratch subdirectory, a tmpfs seeded from the payload,
a single-file row, or a launch argument that moves the write elsewhere. This document covers how to
diagnose the case, the row shapes and their mechanics and costs, and what each affected title
writes.

## Diagnosing

The decisive check is a `+file` trace and the last file operation before the symptom:

    PROPNIX_WINEDEBUG=+file nix run .#<app> …
    PROPNIX_WINEDEBUG="err+all,+seh,+file" …     # when the symptom is a crash

A refused write shows as
`warn:file:CreateFileW Unable to create file L"C:\game\…" (status c0000022)`, `c0000022` being
`STATUS_ACCESS_DENIED`. `+file` also shows `RtlGetFullPathName_U` turning a relative name into
`C:\game\…`, which identifies a cwd-relative write. The trace is needed when a title encrypts its
string literals (Rust's file names appear nowhere in `global-metadata.dat`).

The failure through MSVC's `std::filesystem` is the misleading one: the C++ exception path under
wine/ARM64EC can derail into a jump to a completely unmapped address (`c0000005` with
`ExceptionInformation[0]=8`, execute), which trips the game's own crash reporter. Its signature: the
fault is deterministic, the faulting address is in no loaded module and not mapped at all
(`/proc/<pid>/maps`), shifts by one page when the wine build changes (it comes out of wine's EH
machinery, not game data), and the nearby string constants in the frames name `create_directories`,
`invalid string position`, `bad array new length` or `unknown exception`.

## Row shapes

### Persistent copy-on-write overlay over the whole game dir

    wine.mounts."drive_c/game" = {
      type = "overlay";
      lower = "${payload}";                 # or the whole stack, see below
      upper = "$PROPNIX_STATE/gamedir";
      createIfNotExist = true;
    };

Reads fall through to the store inode (no copy, shared page cache) and only written files copy up
into the app's state dir. The wine builder gives every store-backed overlay row a data-only skeleton
built from its own `lower` by default: sized sparse stubs of every file in the tree, onto which
propnix-mount stamps the metacopy/redirect xattrs at mount time. The skeleton is per FILE, so its
cost scales with the payload's file count, not its size: No Man's Sky is 155 files, Cyberpunk 2077
160, Rust's three lowers produce a 2.5 MB sparse tar of 3510 stubs, and The Witcher 3 is 2546 files
(52 GB).

The skeleton is required for writes below the root. Without it (`skeleton = null`) the store lowers
stay `dr-xr-xr-x nobody nogroup` inside the launch's user namespace, so only the merged root is
writable and `touch cfg/client.cfg` fails with EACCES (measured with
`unshare --user --map-root-user --mount` and a bare overlay).

A multi-tree `lower` is a colon-joined union, and the default skeleton spans the whole stack:
`mkStoreSkeleton` takes the lowers as a list, first tree winning per path (overlayfs' own
leftmost-wins order). propnix-mount then composes `lowerdir=<skel>::<l1>::<l2>::<l3>`: one normal
metadata layer over N data-only layers. In an overlayfs `lowerdir=`, `::` introduces ONE data-only
layer and must be repeated per layer. `<skel>::<l1>:<l2>:<l3>` makes the kernel read `l2` and `l3`
as regular lowers after a data lower and reject the mount: `mount(2)` returns EINVAL, dmesg says
`overlayfs: regular lower layers cannot follow data lower layers`, and the launcher's only visible
symptom is `propnix-launcher: launch failed: Invalid argument (os error 22)`. The single-tree case
is unaffected. `mount(8)` normalises the option string and the per-layer form does not survive it,
so this reproduces only through the syscall, which is why propnix-mount calls `mount(2)` directly.

A `drive_c/game` row in the title's tuning replaces the derived game row wholesale (`finalMounts`
merges tuning rows over it with `//`, not per field). A title with more than one tree must therefore
rebuild `lower` itself, in the order the builder uses: `extraLowers` first (steam.emu's entitlement
settings tree must outrank the depots), then the payloads in declared order:

    lower = lib.concatStringsSep ":" (map (d: "${d}") (config.extraLowers ++ config.payloads));

Enabled DLC trees go ahead of both; a title with DLC needs its overriding row to carry them too.

The cost of a persistent upper: after a depot bump, anything that was copied up keeps shadowing the
new payload. A title that only creates files copies nothing up in normal play, but clearing
`$PROPNIX_STATE/gamedir` is the first thing to try if a title misbehaves after a `versions.json`
bump.

### Nested rows under a read-only parent

propnix-mount gives every mount a child skeleton of the mountpoints its own content lacks, so a
nested row lands on a read-only parent and its mountpoint does not have to exist in the payload. For
an overlay it stubs every declared child, merged into the overlay's normal skeleton layer (a stub
after the data-only store lower would be invisible, and a stub in a second normal lowerdir breaks
the metacopy redirect), so the stubs never reach the `$PROPNIX_STATE` upper.

### Ephemeral tmpfs

    wine.mounts."drive_c/game/<dir>" = { type = "mount"; source = null; };

`source = null` makes a `mount` row a fresh private tmpfs: a scratch directory for re-creatable data
that needs no skeleton and no state. Nested under a writable game-dir overlay it still shadows the
overlay, so the scratch never accretes in the upper.

### Seeded tmpfs

    wine.mounts."drive_c/game/<dir>" = { seed = "${payload}/<dir>"; };

A source-less `mount` plus `seed`: on every launch, every file the target lacks is copied from
`seed` (existing files untouched, copies made writable), giving real files in a writable directory,
RAM-backed and always current, with no persistent state.

### Single-file rows

`type = "file"` binds one file; `createIfNotExist` touches the source rather than mkdir'ing it (a
directory there would make the game's `open()` fail obscurely). It is enough for a file the game
opens by itself, and not for one with sibling files (see Rust's SQLite journal).

## Rust

Rust needs both a scratch tmpfs and a whole-game-dir overlay. With both, it reaches the main menu on
x86_64 (2026-09-03, headless sway on an RX 7900 XTX): `[Bootstrap] Done` /
`[Bootstrap] completed in 16.17s` in its `Player.log` (the save bind lands it at
`$PROPNIX_SAVE_DIR/rust/Player.log`) and a compositor screenshot of the live frontend (the store
hero panel "BREACH AND CLEAR", the top nav bar, the bottom bar, and the first-run "TUTORIAL /
Crashed Pilot" dialog). Engine init, D3D11 over DXVK, all twelve asset bundles, the menu prefabs,
the menu UI and the menu scene complete.

### `C:\game\temp`: the hero-video downloader

With the bootstrap finished (`[Bootstrap] Done`, the menu scene live, `Rust.UI.MainMenu.*` running)
the loading overlay never clears when `temp/` is unwritable: 200 s of screenshots are
pixel-identical, and `Player.log` grows to 831,367 lines of one repeating managed exception:

    UnauthorizedAccessException: Access to the path 'C:\game\temp' is denied.
      … Rust.UI.MainMenu.<PlayVideoAsync>d__22:MoveNext()
         Rust.UI.MainMenu.UI_Hero_Store:…(Hero)

The menu's hero/store panel downloads its background video into `temp/` beside the exe, retries
forever when the write fails, and the overlay is gated on it. `temp/` is in neither depot, so the
game creates it.

`temp/` gets an ephemeral tmpfs row
(`mounts."drive_c/game/temp" = { type = "mount"; source = null; }`), because it holds a
re-downloadable video. The row stays even though the game dir is a writable overlay: without it
every launch accretes video files in `$PROPNIX_STATE/gamedir`. With both rows in place the menu
comes up and the `gamedir/` upper contains no `temp/` at all (the tmpfs shadows it).

### `client.serverlist.1.db` and `cfg/*.cfg`: the whole directory

With a read-only game dir, opening or refreshing the server browser throws:

    System.TypeInitializationException: The type initializer for '<obfuscated>' threw an exception.
     ---> Facepunch.Sqlite.SqliteException: Could not open database file:
          client.serverlist.1.db (error 14)

SQLite error 14 is `SQLITE_CANTOPEN`, a create that failed. `+file` gives the chain:

    RtlGetFullPathName_U (L"client.serverlist.1.db" …)     ← relative → resolved vs the cwd
    CreateFileW L"C:\game\client.serverlist.1.db" GENERIC_READ GENERIC_WRITE … creation 4
    warn:file:CreateFileW Unable to create file L"C:\game\client.serverlist.1.db" (status c0000022)

The DB is a file at the root of `C:\game`, the launch cwd. It is not a click-only failure: the
managed stack in `Player.log` ends at `Rust.UI.MainMenu.UI_MainMenuManager.Awake()`, via
`UI_ServerBrowserPage` → `ServerBrowserList` → `<RunQueryAsync>d__19` → the `ServerCacheDatabase`
cctor, so it fires at menu load, four times per launch, with no input, which makes it verifiable
headlessly.

A `type = "file"` row for the DB alone is not enough. With `drive_c/game/client.serverlist.1.db`
bound out to the state dir, the DB opens and then:

    CreateFileW L"C:\game\client.serverlist.1.db-journal" … creation 4
    warn:file:CreateFileW Unable to create file L"C:\game\client.serverlist.1.db-journal" (c0000022)
    → SqliteException: Could not reset SQL statement: unable to open database file (14)

SQLite's rollback journal is a sibling of the DB, created and deleted per transaction. Facepunch
reaches `journal_mode=wal` (`pragma journal_mode` on the resulting file says `wal`) only by first
running the pragma inside an ordinary journalled transaction, so the directory itself has to be
writable.

The same directory holds `cfg/client.cfg` and `cfg/keys.cfg` (settings and keybinds) and
`cfg/favorites.cfg`, which must survive a restart, so the row is a persistent overlay with its upper
in `$PROPNIX_STATE/gamedir`, its `lower` rebuilt from `config.extraLowers ++ config.payloads`, and
`skeleton` unset so the builder derives the default skeleton over the whole three-tree stack (the
entitlement tree, 252495, 252494).

Measured on that row (x86_64, headless sway on an RX 7900 XTX, four consecutive launches):
`Player.log` holds zero `SqliteException`/`TypeInitializationException` lines (against four per
launch without it); `[Bootstrap] Done` / `completed in 15.44s`; all twelve bundles still load
through the metacopy redirects out of the 39 GB content depot; and `$PROPNIX_STATE/gamedir` ends up
holding `client.serverlist.1.db` (plus `-wal`), `cfg/client.cfg`, `cfg/keys.cfg` and
`cfg/favorites.cfg`, all written by the game. Persistence holds both ways: editing `graphics.fov` to
a marker value in the persisted `client.cfg` and relaunching leaves the marker in place, so the game
reads it back rather than starting from defaults.

`screenshots/` and `demos/` are creatable in the merged tree and land in `$PROPNIX_STATE/gamedir`,
not anywhere a user would look; rows pointing them at `$PROPNIX_SAVE_DIR` or `$XDG_PICTURES_DIR`
would be a presentation choice.

## No Man's Sky

At the end of graphics init, `cGcGraphicsManager::Prepare` calls
`std::filesystem::create_directories` on `GAMEDATA/SHADERCACHE` inside the install dir. The trace
shows

    CreateDirectoryW L"C:/GAME/GAMEDATA/SHADERCACHE"

as the last file operation before the crash, and the crash presents as the `std::filesystem` wild
jump described above (No Man's Sky 6.45.1). A persistent overlay over `drive_c/game` (lower = the
payload, upper = `$PROPNIX_STATE/gamedir`) fixes it: the 28 GB of `.pak` files stay shared from the
store, the shader cache persists to app state, and with the overlay the game reaches the title
screen and plays. The whole payload is 155 files, so the skeleton is tiny.

## Kerbal Space Program

KSP writes `settings.cfg`, `PartDatabase`, the ModuleManager cache and its saves throughout its own
game directory. Three rows:

- `drive_c/game`: a persistent overlay, lower = the payload, upper = `$PROPNIX_STATE/gamedir`. KSP's
  setup script edits `settings.cfg` in that upper directly (`$PROPNIX_STATE/gamedir/settings.cfg` is
  the host path the game's own writes to `C:\game\settings.cfg` land in).
- `drive_c/game/saves`: a nested persistent overlay, lower = `${payload}/saves` (which ships the
  training and scenario saves), upper = `$PROPNIX_SAVE_DIR/$PROPNIX_APPID`. Shipped scenarios read
  from the store, the user's own saves persist in the save dir, only deltas are on disk, and nothing
  is copied at startup. An overlay upper over a store lower is not expressible as a `saveBinds`
  bind, so this stays a `wine.mounts` row.
- `drive_c/game/KSP_x64_Data/Managed`: a seeded tmpfs (`seed = "${payload}/KSP_x64_Data/Managed"`,
  about 28 MB). Served from the game-dir overlay, a read-only bind or a plain overlay, Mono fails
  with "mscorlib.dll could not be loaded"; only the real assemblies in a writable directory load.

The Managed failure is attributed to Mono's `mono_image_open` MAP_SHARED-mapping each assembly,
which overlayfs does not handle for a lower-layer file ("Non-standard behavior" #2), together with
Mono needing the containing directory writable. That attribution is not settled: a user-namespace
replay over Hollow Knight: Silksong's tree reads `mscorlib.dll` over an overlay lower under both
MAP_SHARED and MAP_PRIVATE. The outcome is what is measured, and the seeded tmpfs is load-bearing
for KSP.

## Iron Lung and R.E.P.O.: when a Managed tmpfs is needed

Iron Lung (Unity 2021.1, Mono: MonoBleedingEdge + `mono-2.0-bdwgc.dll`) serves
`Iron Lung_Data/Managed` from a seeded tmpfs. Its signature without one, in `Player.log`:

    The assembly mscorlib.dll was not found or could not be loaded.
    It should have been installed in C:\game\Iron Lung_Data\Managed\mono\4.5\mscorlib.dll

and the process aborts before any graphics init (UnityCrashHandler64 spawns).

R.E.P.O. (Unity 2022.3, also Mono: `MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` and a
143-assembly `Managed` tree) needs no such row. Behind a two-lower read-only overlay (steam.emu's
entitlement tree above depot 3241661) it loads all 143 assemblies and reaches its menu:
`Begin MonoManager ReloadAssembly` / `- Loaded All Assemblies, in 0.220 seconds` in `Player.log`,
then Odin Serializer, then the scene. Seeding would cost 21 MB of RAM and a 143-file copy every
launch for nothing. Iron Lung's finding does not generalise from Unity 2021.1 to 2022.3; the
mscorlib message above is the signature that calls for the row.

## Homeworld Remastered Collection

With a read-only game bind the engine aborts at startup with a message box: "Unable to run
Homeworld2, Administrative access to this folder is required." (GOG's `goggame-2114871440.info`
flags `HWRStart.exe` `RUNASADMIN`.) The fix is a persistent overlay over `drive_c/game` (lower = the
payload, upper = `$PROPNIX_STATE/gamedir`); every write the engine makes to its dir persists to app
state.

The engine's options file sits under that overlay. `HomeworldRM.exe` opens the literal relative path
`../commandLine.txt` with `fopen(…, "rt")` (VA 0x7a9822, reached from the option-map bootstrap at
0x7a9b6f, which seeds `params = ../commandLine.txt` before argv is parsed). A relative `fopen`
resolves against the cwd, which is `HomeworldRM/Bin/Release`, so the file is
`HomeworldRM/Bin/commandLine.txt`; it moves if `workingDir` moves. It is a `type = "file"` row with
source `$PROPNIX_STATE/commandLine.txt`, `mode = "ro"` (generated state the game only reads),
created during mount-table resolution, which the launcher runs before the setup script, so the setup
script always writes into an existing file. The file is not in the payload; the game-dir overlay
stubs every declared child as a mountpoint.

## Cyberpunk 2077: REDmod only

The read-only game dir costs this engine nothing in vanilla play. `r6/logs/` is unused (the `.log`
literals in the exe are a GPU-crash name and a font-shaper name, no engine log path), and the
engine's crash and hang reports go to `%LOCALAPPDATA%\REDEngine\ReportQueue\`, on the writable
profile overlay.

`r6/cache/modded/` is the exception: `redMod deploy` writes `r6/cache/modded/mods.json` (both
`modded` and `modded/mods.json` are tokens in the exe), inside the game dir. The redmod GOG DLC
(dlcId 1597316373) is the toolkit (79 MB of `tools/redmod/bin/{redMod.exe,scc.exe}` and its libs,
plus an empty `mods/.stub`), so staging it is necessary but not sufficient. Modding needs a
persistent overlay on `drive_c/game` with a `$PROPNIX_STATE` upper (cheap here, the payload is 160
files) plus the modded flag REDlauncher normally passes, in `exeArgs`. Enabled DLC already turn
`drive_c/game` into a multi-lower overlay, so the overriding row has to carry the DLC lowers too.

## Open cases

### The Witcher 3

REDengine 3 keeps a shader cache and crash-reporter output next to the binaries, so any in-place
write fails with `STATUS_ACCESS_DENIED`. Whether the title merely loses those files or needs a
writable game dir is not established. The fix would be the whole-game-dir overlay, but its per-file
skeleton covers 2546 files (52 GB) here, against the 155 and 160 files that make it cheap for No
Man's Sky and Cyberpunk 2077.

### Middle-earth: Shadow of Mordor

The exe carries `\USER\render.cfg` and `\USER\settings.cfg` (adjacent to `autoexec.cfg` in the
string table, the console/config subsystem, not next to the `\WB Games\` save-root block). If that
`USER\` hangs off the game directory, the two renderer/settings files fail to write and in-game
settings do not survive a restart, a silent, non-fatal degradation. A `+file` trace of one launch
settles it; the fix would be a `wine.mounts` row over `drive_c/game/USER`.

## Writes that cost only a log

- Baldur's Gate 3 writes its log as `gold.<timestamp>.log` into the game directory; `CreateFileW`
  fails with `STATUS_ACCESS_DENIED` and the engine runs with no log sink. `--logPath <dir>` (two
  separate argv entries; the parser does not accept `=`) moves it into the writable LOCALAPPDATA
  tree.
- Cities: Skylines' Unity 5.6 log defaults to `<gamedir>/Cities_Data/output_log.txt`.
  `-logfile <path>` (lowercase, as the player's argv table spells it) moves it into the save bind. A
  writable `Cities_Data` would instead put its `Managed/` Mono assemblies behind an overlay.

`exeArgs` are passed to the game verbatim, without `$VAR` expansion, so these targets are literal
DOS paths under the fixed profile user `propnix`.

## A shipped empty directory is not proof of in-dir writes (Space Engineers)

The Space Engineers depot ships `TempContent/` as empty scratch directories (`cache/`, `temp/`,
`Mods/`, `ShaderCache/`, `ShaderCachePdb/`, `WorkshopBrowser/`) plus two files of runtime output
captured into the build (`ProfileOptimization/Startup.profile` and a stray
`VRageRender-DirectX11_20260811_175209248.log`), and `VRage.Platform.Windows.dll` declares a
`tempContent` path parameter. The engine does not write there: across runs to the main menu an
overlay on `TempContent/` stays empty, while the save bind fills with the identically named scratch
(`cache/`, `temp/`, `Mods/`, `WorkshopBrowser/`, `ProfileOptimization/`, plus `ShaderCache2/`).
VRage's scratch root is `%AppData%\SpaceEngineers`. World loading and workshop subscription were not
part of those runs.
