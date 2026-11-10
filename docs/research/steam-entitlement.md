# Offline Steam entitlement with gbe_fork

propnix answers a Steam engine's runtime ownership questions without a Steam client: the LGPL
gbe_fork Steam API reimplementation (emulators/gbe-fork) is copied beside a generated settings tree
(lib/builders/steam-offline-entitlement.nix) and wired in by lib/modules/steam-emu.nix, on by
default for every Steam fetch. This page holds the measured facts behind that configuration: what
each settings key actually reaches in the pinned gbe_fork source, why the interface list is a vtable
layout rather than a hint, what the build-time and CI gates enforce, how the shim is placed per
backend, and the per-title findings (Victoria 3, Rust, Cities: Skylines, Civilization VI) that
established them. SteamStub and CEG, which sit in front of the Steam API, are covered in
[steam-drm.md](steam-drm.md); DLC appid mapping in [steam-dlc-appids.md](steam-dlc-appids.md).

## DLC unlock semantics (`[app::dlcs] unlock_all`)

Upstream gbe_fork defaults `[app::dlcs] unlock_all` to 1: every DLC reads as owned. In goldberg-emu,
gbe_fork's ancestor, the same inversion hangs on file presence: a missing DLC list file unlocks
everything. propnix therefore always emits `configs.app.ini` with an explicit `unlock_all=0`
followed by the owned list, one `<appid>=<title>` line per enabled pack. An empty selection yields
an empty list, which means "own nothing", never "own everything".

A `steam_settings/` directory the shim cannot find fails the same inverted way: the shim falls back
to its defaults and unlocks everything. That is why the placement is all-or-nothing (preload copy
and the game-dir union together, see [Placement per backend](#placement-per-backend)).

## Identity

The generated tree writes no local identity (`account_name.txt`, `user_steam_id.txt`) and leaves
`[user::general]` unset. Entitlement does not key on identity, and a shipped package must not carry
a baked-in account name or SteamID64, which would be one identity shared by every install.

gbe_fork generates its own identity on the first Steamworks call and saves it in its global
settings, `AppData/Roaming/GSE Saves/settings/configs.user.ini` under the guest's data home (a
generated file holds, for example, `account_name=gse orca`):

| backend | where the global settings land | lifetime |
|---|---|---|
| wine | `drive_c/users/<user>/…`, the persistent users overlay | stable across launches |
| thin (native, box64, FEX) | the ephemeral per-launch `$HOME` view | minted afresh each launch |

The launcher does not read the credential store to seed a SteamID: reading the launching human's
credentials is not permitted by the group-ownership contract on declarative and shared hosts.

Because the file appears on the first Steamworks call, its presence in the profile upper is a
progress marker (the shim answered at least once). Its absence bounds nothing: a SteamStub-wrapped
exe exits before it ever calls the on-disk Steam API (see
[steam-drm.md](steam-drm.md#the-exit-53-trap)).

## `[main::connectivity] offline` is a statement about logon state

The key is read once (`dll/settings_parser.cpp`, `steam_offline_mode`) into `Settings::offline`, and
`Settings::is_offline()` has exactly three call sites in the pinned tree, all in
`dll/steam_user.cpp`:

    BLoggedOn()      → return !settings->is_offline();             → false
    BConnected()     → return !settings->is_offline();             → false
    GetLogonState()  → k_ELogonStateNotLoggedOn instead of k_ELogonStateLoggedOn

Nothing else consults it. The shim's network behaviour is governed by the separate
`disable_networking` / `disable_lan_only` keys, which propnix leaves at their upstream defaults
either way. Upstream's own documentation of the key
(`post_build/steam_settings.EXAMPLE/configs.main.EXAMPLE.ini`) says the same and cuts both ways:

> 1=pretend steam is running in offline mode, mainly affects the function `ISteamUser::BLoggedOn()`
> / Some games that connect to online servers might only work if the steam emu behaves like steam is
> in offline mode

`steam.emu.offline` (default `true`, i.e. `offline=1`) is the honest answer for the offline case:
there is no Steam session, so a game asking "am I logged on?" is told no. A title whose boot links
Steam to a second account system can read that "no" as "wait for the client to come back" and wait
forever; Victoria 3 is the measured case. Whether a title has a single-player mode does not predict
this: Victoria 3 has a first-class single-player mode and still needs `offline=0`. Flipping the key
gives the game no real Steam session and no ticket that validates with Valve; it only stops the shim
from volunteering a "no".

### Victoria 3: the PDXSDK logon deadlock

Measured with the tree default (`offline = true`): the launch stops at the propnix splash with no
window and no engine log. The profile overlay's upper,
`$XDG_STATE_HOME/propnix/victoria-3/wine/users` (exactly what the run wrote), contains one file:
`propnix/AppData/Roaming/GSE Saves/settings/configs.user.ini` (`account_name=gse orca`). So the exe
mapped, its static `steam_api64.dll` import resolved to the union-replaced shim, the shim answered,
and then the process stopped.

Where it stopped, read off the hung process:

- All 13 threads idle. The engine's job system is up (thread names `victoria3.exe:disk$0`, `:cs0`,
  `:sh0`, `:sh_opt0`, `:traceq0`, `:gdrv0`, `:gl0`); every one is parked in futex.
- The main thread sits in `read(fd, buf, 16)` on a pipe whose write end the process holds itself.
  `strace -k -e trace=pipe2` names the pipe: wine's own `server_pipe`/`init_thread_pipe`, the
  per-thread wineserver wait pipe. A 16-byte read from it is `server_select()` collecting a
  `struct wake_up_reply`: a wineserver-mediated Win32 wait that is never signalled. A block, not a
  fault, consistent with `binaries/crash_reporter/CrashReporter.exe` and the
  `submit.backtrace.io/paradoxinteractive/…/minidump` endpoint never firing.
- `PROPNIX_WINEDEBUG=+sync` ends with ~5900 `RtlWakeAddressAll` calls from the main thread, then
  silence. Their addresses land at +0x9FA390 and +0xA847E8 from the load base of
  `C:\game\binaries\steam_api64.dll`, inside the 11,429,288-byte gbe_fork PE shim (the next module's
  base bounds its image to 11.06 MB). The spin that precedes the deadlock is in the shim.

Why the offline key reaches it: `PDXSDK.dll` is the Paradox account SDK, statically imported, and
debug.log's `pdx_account.cpp:600: Starting up PDX SDK` sits at exactly this point in a working run.
The Steam-to-Paradox link at boot is a handshake that waits on a logon state, and the key's three
consumers (`BLoggedOn()` → false, `BConnected()` → false, `GetLogonState()` →
`k_ELogonStateNotLoggedOn`) are what answer it.

The evidence that it is this key: flipping it alone (`steam.emu.offline = false`) turns "no log at
all" into the engine's full 21-file log set plus a D3D11 device.

### Triage: a logon-state block versus a stall inside `SteamAPI_Init`

From the syscall side the two look identical: wine's `server_select` waiting on a 16-byte
`wake_up_reply` that never comes. Only a PE-level backtrace separates them. winedbg attached to the
frozen process gives it:

    nsenter -t <pid> -m -U --preserve-credentials -- wine winedbg
    attach <win-pid>
    bt all

- **Victoria 3** raises the wait from a `RtlWakeAddressAll` spin inside the shim after init, and
  `offline=0` cures it.
- **Rust** stops inside `steam_api64!SteamAPI_InitFlat`, with the main thread in
  `ntdll!NtQueryVolumeInformationFile` under `kernelbase!GetFileInformationByHandle` (the shim's
  `common_helpers::file_exist` on its own global settings file, reached from `Steam_Client()` →
  `create_localstorage_settings()`). All three `is_offline()` call sites are reachable only after
  `SteamAPI_Init` returns, so no value of the key can move a stall inside it; every recorded Rust
  freeze happened with `offline=0` in effect, and flipping the key changes nothing.

## `steam_interfaces.txt` is the vtable layout the game gets

`dll/dll.cpp` holds one `old_<itf>[128]` string per interface, each initialised to the revision the
shim was compiled against (`static char old_client[128] = STEAMCLIENT_INTERFACE_VERSION;`).
`dll/settings_parser.cpp`'s `try_parse_old_steam_interfaces_file()` overwrites them from
`steam_interfaces.txt`, matching a line to a slot by substring (`SteamClient` → CLIENT, …), so a
slot with no line keeps the modern revision. The legacy accessor `SteamClient()` then returns
`SteamInternal_CreateInterface(old_client)`, and `dll/dll.cpp` casts that to the requested
revision's class (`ISteamClient001` … `ISteamClient017` …, each a real, differently-shaped vtable).

So the file is not "harmless when unused": the revision named there is the vtable layout the game
walks with its own SDK header's layout, and the two must agree slot for slot.

gbe_fork reads `<module dir>/steam_settings/steam_interfaces.txt` first and the file beside the
library only when that is absent (`dll/settings_parser.cpp` `parse_old_steam_interfaces`), and
offers no environment override (local_storage's only `getenv` calls are `XDG_DATA_HOME`/`HOME`, for
saves). One directory therefore carries one list.

The revisions are scanned out of the game's own shipped libraries at build time. A Linux and a
Windows build of one game's Steam library can differ: Civilization V's Linux `libsteam_api.so` names
nine of its sixteen revisions differently from the Windows dll (`SteamUser017` vs `016`,
`STEAMREMOTESTORAGE` 012 vs 006, …), so each flavour is scanned on its own.

### Cities: Skylines (SDK 1.34, `SteamClient017`)

Cities: Skylines ships a 2015-era Steam library (`SteamClient017`, `SteamUser018`) and does not
survive a revision disagreement. Modern `ISteamClient` dropped `GetISteamUnifiedMessages`, so slot
25 of what the engine believes is `SteamClient017` lands on the shim's `GetISteamController`, which
does not recognise `STEAMUNIFIEDMESSAGES_INTERFACE_VERSION001` and calls
`report_missing_impl_and_exit()`: a modal "Missing interface" MessageBox, then
`std::exit(0x4155149)`. Observed and screenshotted on x86_64-linux, 2026-09-03.

An export-table diff of the same library finds 12 flat-API entry points the shipped dll has and
gbe_fork lacks, all unused (a `GetProcAddress` miss returns NULL). That diff cannot see the failure:
`ISteamUnifiedMessages` also occupies a vtable slot, and a method the shim's class does not declare
shifts every method after it. Serving the revisions the shipped dll advertises, scanned at build
time, is what makes the title run.

The library is `steam_api64.dll` at the payload root, loaded only by
`Cities_Data/Plugins/ColossalNative.dll` via `LoadLibrary` + `GetProcAddress` by name (no static
import), using `SteamAPI_InitSafe`, `SteamAPI_GetHSteamPipe`, `SteamAPI_GetHSteamUser`,
`SteamAPI_RegisterCallback`, `SteamAPI_RunCallbacks`, `SteamAPI_RestartAppIfNecessary`,
`SteamAPI_Shutdown` and `SteamClient`, all exported by the gbe_fork PE shim.

## What the gates enforce

An interface revision the pinned shim does not serve is fatal at runtime and silent: the shim either
calls `report_missing_impl_and_exit` (`std::exit(0x4155149)`, exit status 73 = `0x4155149 & 0xFF`)
or returns a NULL vtable, the moment the game asks for it. Factorio's 2.1.2x Steamworks SDK bump,
run against an older shim, is a silent exit 73 at "Initializing Steam API"; Factorio 2.1.2x needs
gbe_fork >= 2026_09_27.

The hand check for this is `nm -D <game's libsteam_api.so>`, comparing its newest entry points and
interface strings against gbe_fork's `.so`. Two automated gates replace it, and both ask the shim
itself rather than grepping its source.

### The interface oracle

`gbeFork.interfaceOracle` (emulators/gbe-fork/interface-oracle.c) runs the host's build of the
pinned shim. Each revision is probed in a forked child: `dlopen` the shim, `SteamAPI_Init` (the
emulator's offline login; the generic getter refuses a user pipe without a user), then
`SteamInternal_FindOrCreateUserInterface`; on NULL, `SteamInternal_FindOrCreateGameServerInterface`
after a server init (the `GameServer*` families live on the server pipe); on NULL again,
`SteamInternal_CreateInterface` (the `SteamClient` family lives there). The child gets a private
`HOME`/`XDG_DATA_HOME` with gbe_fork's networking switched off. Verdicts: `served`, `null`,
`exit73`, `error:N`.

Executing is the only reliable answer because the shim's dispatcher
(`dll/steam_client_interface_getter.cpp`, `dll/dll.cpp` `create_client_interface`) routes by prefix,
then by exact ladders per family, with `report_missing_impl_and_exit` in some families and a NULL
fallthrough in others, and spells the current revision as an SDK macro rather than a literal. A
literal can appear in `dll/` where nothing dispatches on it (`dll/client_known_interfaces.cpp` is a
dump of the real Steam client's table), and a revision can be served without its literal appearing
at all.

### Build-time gate (every Steam build)

The entitlement builder scans every declared `steam.emu.libPaths` entry and fails the build, naming
the remedy, when:

- a library of the flavour the backend loads is missing from the payloads, or names no Steamworks
  revision at all (`generate_interfaces` exits 1, "No interfaces were found": a stub, a packed
  image, an empty placeholder);
- two libraries of that flavour that must share one list disagree as sets: two in one directory, or,
  on the guest-loader thin backends (FEX's guest ld.so resolves the preloaded root copy, box64 the
  CWD), any two, since one root list then serves every guest process;
- any scanned revision is not `served` by the oracle and is not declared in
  `steam.emu.neverRequested`.

Libraries in different directories may differ: Baldur's Gate 3 ships `bin/steam_api64.dll` and
`Launcher/steam_api64.dll` from different SDK releases, and each directory carries its own list.

`steam.emu.neverRequested` exists because a shipped library is a superset of the game's requests: it
carries an accessor for every family of its SDK, and the shim skips revisions no game needed. Baba
Is You's `libsteam_api.so` names `STEAMVIDEO_INTERFACE_V003`, which gbe_fork does not serve (its
`ISteamVideo` ladder is V001, V002 and the current V007, per the oracle). Baba is a Chowdren title
with no video feature, nothing in it opens `ISteamVideo`, and it runs in play with the shim, so the
revision is declared never requested.

### CI gate (`ci/gbe-interface-check.sh`)

Each Steam row of a `versions.json` carries `steamApiInterfaces`: every interface-revision string
the depot's shipped steam_api libraries name, recorded by `propnix pin` at pin time (when the bytes
are fetched anyway, with the pinner's credential). The CI script needs no credential, no payload and
no network beyond substituting the oracle, so it runs on every push and every pull request, fork PRs
included. It makes one oracle run over the union of all recorded revisions and, per row:

- fails on any revision the shim does not serve, unless the game lists it in
  `steam.emu.neverRequested` (then reported as tolerated; a listed revision the shim now serves is
  reported as removable);
- reports a row exempt when `steam.emu.enable = false` on every platform the row serves;
- reports a row without the field as unverified, with the fix (`propnix pin <game> --fingerprint`);
- fails when `pkgs/propnix-cli/steam-api-interface-patterns.txt`, the pin scanner's copy of the
  generator's pattern list, drifts from the pinned gbe_fork's `tools/generate_interfaces`, since
  every fingerprint is then silently incomplete.

If the eval of the games' `steam.emu` settings fails, every row is held to the gate with no
exemptions, which can only add failures. `PROPNIX_GBE_ORACLE=<dir>` points the script at a candidate
release's oracle to see whether it satisfies every pin before bumping. The commit that moves a pin
past the shim is the one that goes red, naming the game, the row and the revisions.

### What neither gate covers

The flat `SteamAPI_*` export surface is not fingerprinted. A game binary importing an export the
shim lacks fails at load (a missing entry point under wine, a symbol lookup error under a Linux
loader), and a managed P/Invoke layer fails at init instead: goldberg-emu 0.2.5, gbe_fork's
predecessor, loads under hollow-knight (Steamworks.NET 2024.8.0, SDK 1.60), init throws
`EntryPointNotFoundException`, and the screen stays black, which is worse than no shim at all.
Either is caught only by running the game. Measured by symbol diff, gbe_fork's SDK 1.64 surface
covers every interface hollow-knight's SDK 1.60 library carries; measured 2026-09-03, all 17
`steam_api64.dll` entry points Civilization VI's exe imports statically are exported by the gbe_fork
PE shim.

### Rust: the interface census

All 19 interface-version strings in Rust's shipped `RustClient_Data/Plugins/x86_64/steam_api64.dll`
(`SteamClient021`, `SteamUser023`, `SteamUtils010`, `STEAMUGC_INTERFACE_VERSION020`,
`SteamNetworkingSockets012`, `STEAMREMOTESTORAGE_INTERFACE_VERSION016`, …) are served by the
gbe_fork pin, and the gates hold that on every build and every pin. An unserved revision ends in
exit 73 or a NULL vtable; it never blocks, so a missing interface cannot explain a hang.

## Placement per backend

### Native: no `LD_PRELOAD`

Plain `LD_PRELOAD` is inherited by every child a game spawns, and games shell out to host binaries:
Factorio execs `sh -c lsb_release` to stamp its log. On a non-NixOS host the shim's nix-store
RUNPATH then drags a second glibc into a foreign-distro process, which dies with SIGBUS. Observed:
every Factorio launch on Fedora coredumps its `lsb_release` child with the shim preloaded. The
native backend therefore uses only bind-over rows (the shim bound onto the declared `.so` path,
settings beside it): the real ld.so resolves both `DT_NEEDED` and an explicit-path `dlopen` (Unity
native plugins) through the path. Under box64 and FEX the guest loader's own preload variable
(`BOX64_LD_PRELOAD`, the guest `LD_PRELOAD`) confines the preload to emulated code.

### Thin and wine

The thin placements (the beside-the-library probe through `/proc/self/map_files`, box64's fallback
to the CWD because it never file-maps guest libraries) and wine's union replacement are design,
documented in the header of lib/builders/steam-offline-entitlement.nix and in
lib/modules/steam-emu.nix.

## SteamStub-wrapped exes (`steam.emu.steamStub`)

A SteamStub v3.1 exe never asks the on-disk Steam library anything: the wrapper manually maps its
own embedded copy of Valve's Steam API and asks that for ownership. Replacing `steam_api64.dll`
cannot reach it, so a wrapped title fails with Valve's "Application load error 3:…" or an immediate
exit no matter how correct the shim is. Which kind a payload is, is a fact about its bytes: a
section named `.bind` whose range contains `AddressOfEntryPoint`. The anatomy and run evidence are
in [steam-drm.md](steam-drm.md#steamstub-v31).

`steam.emu.steamStub = true` changes what the wine mirror stages at each declared `.dll` path: a
small propnix-built proxy takes the shipped name, the shim moves one name over
(`steam_api64_gbe.dll`, or `steam_api_gbe.dll` for the 32-bit dll) behind the proxy's forwarders,
and gbe_fork's `steamclient_extra_x64.dll` (`_x86` for 32-bit; the in-memory SteamStub v3.1 patcher)
joins them. The proxy's DllMain loads the patcher during `LdrInitializeThunk`, before the exe's
entry point and so before the wrapper runs. Verified on Civilization VI (x86_64-linux, 2026-09-03):
without the knob the process exits 53 having written nothing; with it the game reaches its rendered
front end.

The mechanism, the relay trace behind it and the two alternatives measured not to work (gbe_fork's
own `steam_settings/load_dlls/` hook, which loads the patcher inside `SteamAPI_Init`, too late; and
pointing `HKCU\Software\Valve\Steam\ActiveProcess\SteamClientDll64` at gbe_fork's steamclient, which
the wrapper loads and still refuses) are in emulators/gbe-fork/steamstub-proxy.nix.

The patcher serves only `.bind`. gbe_fork's `stubdrm.cpp` looks up the section literally named
`.bind` and gives up when it is absent, and its `dllmain.cpp` then returns FALSE, so Windows unloads
the dll immediately: adjacent `PROCESS_ATTACH`/`PROCESS_DETACH` lines under `+module`. Setting the
knob on an unwrapped exe is therefore inert, not harmful.

gbe_fork does not implement the older `STEAM_DRM_IPC` startup handshake, and propnix ships
upstream's prebuilt PE shims, which do not answer it. On Civilization V's CEG template exe,
answering the handshake with a patched shim shortens the refusal from ~33 s to ~13 s and reaches no
game code (see [steam-drm.md](steam-drm.md#ceg)).

## Rust: the shim is required

Rust has no working no-Steam path. With `.apply { steam.emu.enable = false; }` the genuine Valve
`steam_api64.dll` fails init with `Could not determine Steam client install directory`,
Facepunch.Steamworks turns that into `System.Exception: SteamApi_Init failed with FailedGeneric`,
and the exception escapes `Bootstrap+<Start>d__26.MoveNext`, so the bootstrap coroutine dies and the
loading screen freezes at 99%. The shim answers ownership only: Rust's server authentication is a
Steam ticket the server validates against Valve, which the shim does not provide.
