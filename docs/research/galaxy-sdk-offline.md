# The GOG Galaxy SDK under propnix

GOG builds bundle the Galaxy SDK (`Galaxy64.dll`, `Galaxy.dll`) and, in older titles, the POPS
client (`pops_api.dll`), usually as static imports resolved from the exe's own directory, where
`WINEDLLOVERRIDES` cannot shadow them. A packaged game runs fully offline, so propnix neutralizes
that surface in two complementary ways: `wine.galaxyStubDlls` binds the no-op stub from
emulators/galaxy-stub over each declared DLL, and `online = false` unshares a loopback-only network
namespace. This document holds the evidence behind both: why the stub is policy rather than a crash
fix, why it is valid only for 64-bit callers, how to confirm it is the DLL that actually loaded, and
which titles import what.

## Policy, not a crash fix

The real SDK's RPC init faults wine's builtin rpcrt4 with
`page fault on write access to 0000000000000010` when the toolchain carries the ARM64EC variadic
exit-thunk defect (an `[out]` context handle receives the varargs size). That is a compiler bug,
llvm/llvm-project#190933, and the toolchain in emulators/llvm-mingw carries the backported fix
(preliminaries/RESEARCH.md §23; llvm-mingw-toolchain.md).

Verified 2026-08-21: Prison Architect, with the real `Galaxy64.dll` and `pops_api.dll` loaded,
reaches a window with no fault. Nothing in the stub is load-bearing for stability. It exists for the
offline guarantee, and a crash with the real SDK loaded is a defect to find where it lives, not a
reason to bind a stub.

## The stub is valid only for 64-bit callers

The stub hands the game one uniform vtable whose every slot is a zero-argument C function. Under the
Microsoft x64 convention that is safe for a slot of any arity: arguments arrive in registers and the
caller cleans the stack, so a callee that ignores them leaves nothing behind. On i386 the SDK's
interfaces are `__thiscall`, where the callee pops its arguments. A zero-argument slot standing in
for an N-argument method leaves N bytes on the caller's stack, and the caller's own `ret` then pops
an argument as its return address.

### Homeworld Remastered Collection (i386)

Measured 2026-09-03 on x86_64-linux (native WoW64). `HomeworldRM.exe` statically imports
`Galaxy.dll`, the 32-bit SDK bundled beside it in `HomeworldRM/Bin/Release`, pulling in exactly the
four `GalaxyFactory` statics `CreateInstance`, `GetInstance`, `ResetInstance` and `GetErrorManager`
(from the PE import table). Its Galaxy init wrapper is:

    004bd9e5  ff 15 2c 80 87 00  call [GalaxyFactory::CreateInstance]  ; a Galaxy.dll import
    004bd9eb  8b 10              mov  edx,[eax]                       ; IGalaxy vtable
    004bd9ed  6a 00              push 0
    004bd9ef  68 c8 60 8e 00     push 0x8e60c8                        ; clientSecret
    004bd9f4  68 60 60 8e 00     push 0x8e6060                 ; clientID "48201844549712537"
    004bd9f9  8b c8              mov  ecx,eax                         ; this
    004bd9fb  ff 52 04           call [edx+4]          ; IGalaxy::Init — __thiscall, `ret 12`
    004bd9fe  c3                 ret                   ; pops 0x8e6060 when nobody popped

With the stub bound, `IGalaxy::Init(clientID, clientSecret, 0)` returns without popping its 12 bytes
and the game's own crash log reads:

    HomeworldRM.exe caused an Access Violation in module HomeworldRM.exe at 0023:008e6060
    … Bytes at CS:EIP: 34 38 32 30 31 38 34 34 …

The game is executing the client-ID string literal: 0x8e6060 is that string in `.rdata`, and it
matches the `clientId` in `goggame-2114871440.info` exactly. The crash log's module list confirms
the 29,075-byte stub as the loaded `Galaxy.dll`. Dropping the row makes the fault go away and the
game maps its window; nothing else does.

A generic 32-bit no-op stub cannot be written: it would need the true arity of every slot of every
interface. So `lib/backends/wine/defaults.nix` refuses `wine.galaxyStubDlls` on an `i386-windows`
title with an evaluation error, and a 32-bit GOG title declares `online = false` instead. With the
real 32-bit SDK loaded and no route out, the SDK takes its offline path: it throws and swallows its
own `galaxy::api::IError` C++ exceptions during init, and Homeworld proceeds to render.

`Galaxy.dll` is built anyway, because prison-architect (a 64-bit exe) ships a 32-bit copy it never
loads and binds the stub over it. The 32-bit build is not a claim that a 32-bit game can use it.

## Confirming the stub actually loaded

The stub is a pair of x86_64/i386 PEs matching the game, not the host, so both hosts build it:
aarch64 with the ARM64EC llvm-mingw it already carries, x86_64 with nixpkgs' cross-mingw GCC
(`pkgsCross.mingwW64` / `pkgsCross.mingw32`, plus their mcfgthreads import libs). The wine defaults
derive one bind row per `galaxyStubDlls` entry only when the scope provides `galaxyStub`; with
`galaxyStub == null` the rows are omitted without an error and the real SDK loads.

A row that does not bind looks identical to a working one from outside, so a de-Galaxy claim is
checked against the mapped module, not inferred from the config:

- Read the DLL the running game mapped through `/proc/<pid>/root` (that enters the launch's mount
  namespace) and compare its md5 against `${galaxy-stub}/Galaxy64.dll`.
- Or read the module list of a minidump. Measured 2026-09-03 on x86_64-linux, Cyberpunk 2077 with no
  stub bound: `C:\game\bin\x64\Galaxy64.dll` loads at SizeOfImage 14,299,136, the real SDK (payload
  file 14,208,648 bytes). The x86_64 `Galaxy64.dll` stub is 33,869 bytes; the i386 `Galaxy.dll` stub
  in the Homeworld run above is 29,075 bytes.

What the stub has to do beyond returning benign values (complete the async sign-in by delivering
`IAuthListener::OnAuthFailure` from `ProcessData`; typed `IApps` string slots), the instrumentation
method that found it, and the startup-latency caveat for judging a run are documented in the header
of `emulators/galaxy-stub/src/galaxy_stub.c`.

## `online = false` as the enforcing layer

Inside a loopback-only network namespace `connect(2)` fails immediately with ENETUNREACH. A
reachable-but-dead server is what produces a boot hang; an absent route does not. Measured under the
pinned wine inside `unshare -rn` with `lo` up (the Cyberpunk 2077 investigation):
`InternetGetConnectedState`, `IcmpCreateFile` + `IcmpSendEcho`, `getaddrinfo` and `connect(2)` all
return in under 5 ms, with `connect` failing.

DNS still resolves: glibc reaches the host resolver over a unix socket, which the namespace does not
cut. The guarantee is enforced at connect, not at name lookup; `+winsock` traces show name lookups
such as `galaxy-log.gog.com` succeeding inside the namespace.

## Per-title coverage

| title | DLL | reached via | symbols | stub |
|-------|-----|-------------|---------|------|
| Prison Architect | `Galaxy64.dll`, `pops_api.dll` | static import | GalaxyFactory, POPS | yes |
| Homeworld RM | `Galaxy.dll` (i386) | static import | 4 GalaxyFactory | refused |
| Shadow of Mordor (GOG) | `x64/Galaxy64.dll` | GOG's `steam_api64.dll` | 11 `galaxy::api` | yes |
| The Witcher 3 | `REDGalaxy64.dll` | static import | 28 `redgalaxy` | no |
| The Witcher 3 | `Galaxy64.dll` (x2) | no static importer | — | policy |
| Cyberpunk 2077 | `REDGalaxy64.dll` | static import | 28 `redgalaxy` | no |
| Cyberpunk 2077 | `bin/x64/Galaxy64.dll` | `GameServicesGOG.dll` | 10 `galaxy::api` | verified |

Prison Architect also binds the stub over a 32-bit `Galaxy.dll` it never loads. Homeworld RM's
offline guarantee is `online = false`. "Policy" means no importer was found and the row is bound in
case something loads the DLL by name; "verified" means the stub was confirmed as the mapped module
in a running game. Cyberpunk's `GameServicesGOG.dll` is itself loaded by name at runtime.

The stub's 64-bit export list is `emulators/galaxy-stub/src/symbols64.txt`: 34 symbols, all in the
`galaxy` namespace, zero `redgalaxy`.

### Shadow of Mordor

The exe links a socket library: 32 static `WS2_32.dll` imports (the Winsock 1.1 set by ordinal, plus
`getaddrinfo`/`freeaddrinfo` by name). Its store SDK surface is a static import of `steam_api64.dll`
covering 22 entry points, among them `SteamMatchmaking`, `SteamMatchmakingServers`,
`SteamGameServer` and `SteamGameServer_Init`: the online surface behind the leaderboards and the
asynchronous friend-Vendetta feature.

`maskFiles` cannot be used: the import is static (22 named thunks in the PE import table), so
erasing the file makes wine's loader refuse to start the process. The file exists on both store
arms; what differs is what sits behind it.

GOG did not patch the engine. The exe imports `steam_api64.dll` unchanged, and GOG ships its own
`steam_api64.dll` that re-implements exactly those 22 symbols on top of Galaxy:

- GOG's `steam_api64.dll`: 427 008 B. It exports precisely the 22 names the exe imports, no more,
  and its own import table names `Galaxy64.dll` for 11 `galaxy::api::` free functions.
- Valve's genuine `steam_api64.dll` in the Steam depot: a different binary, 121 256 B, 62 exports.

The 11 bridge imports are `Init`, `Shutdown`, `ProcessData`, `User`, `Friends`, `Apps`, `Stats`,
`Networking`, `Matchmaking`, `ListenerRegistrar` and `GameServerListenerRegistrar`. The chain on GOG
is exe → GOG's `steam_api64.dll` → `Galaxy64.dll`, and the stub goes at the bottom of it:
`wine.galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [ "x64/Galaxy64.dll" ]`.

All 11 symbols are in `symbols64.txt`, checked one by one. The stub's accessors return non-null
interface objects whose scalar slots return 0, so the bridge's `User()->…` / `Apps()->…` chains
answer "offline / not signed in / 0" instead of null-dereferencing.

On the Steam arm gbe_fork union-replaces `steam_api64.dll` and reports offline; its PE shim exports
all 22 symbols the exe imports (export table diffed against the exe's import list), so the shim is a
drop-in for this title.

`online = false` is a second, independent guarantee behind an SDK that already reaches nothing on
either arm; if a launch stalls before the menu with the SDK retrying a connect,
`.apply { online = true; }` is the revert. The GOG arm with the stub bound plays on aarch64
(in-game, 2026-11-09). The title waits for window focus before it leaves its loading spinner: an
unfocused window stays black and the process exits 0 after about ten minutes, so an unattended run
says nothing about it.

Residual risk on the GOG arm: if the bridge gates DLC content on a Galaxy ownership query, the
stub's 0 answer means "unowned". The GOTY layer archives are listed unconditionally in
`default.archcfg` and are physically present, and the engine's manifest tolerates absent layers, so
content loading is not obviously entitlement-gated. That is inference, not a playthrough. The
observable if it is wrong: the GOTY skins, runes and warbands and the two story campaigns missing
from an otherwise working game.

### The Witcher 3

`witcher3.exe` (both binaries, `bin/x64` and `bin/x64_dx12`) statically imports `REDGalaxy64.dll`,
CD Projekt Red's own rebuild of the Galaxy SDK. It is self-contained: it imports `WS2_32`,
`WININET`, `CRYPT32` and `bcrypt` directly and does not import `Galaxy64.dll`. The stub cannot stand
in for it: its 28 exports are in the `redgalaxy` namespace
(`?Init@api@redgalaxy@@YAXAEBUInitOptions@12@@Z`, …), so a bound stub would leave 28 imports
unresolved and the exe would not load. It cannot be bound either: the wine defaults source each row
from `${galaxyStub}/${baseNameOf rel}`, and the stub package emits only `Galaxy64.dll`, `Galaxy.dll`
and `pops_api.dll`. A `redgalaxy` variant in `symbols64.txt` plus a `REDGalaxy64.dll` output is what
it would take.

The real `Galaxy64.dll` is present in both bin dirs and no DLL in either dir imports it statically
(checked one by one). It is stubbed anyway, as policy: a static-import scan cannot prove that
nothing loads it, because a GOG store plugin is loaded by name at runtime (Cyberpunk's
`GameServicesGOG.dll` reaches `Galaxy64.dll` that way), and this payload ships
`bin/config/platform/pc/GalaxyPeer.json` beside `REDGalaxyPeer.json`. If nothing loads it the rows
are inert. `online = false` covers `REDGalaxy64.dll`.

### Cyberpunk 2077

`Cyberpunk2077.exe` statically imports `REDGalaxy64.dll` (14 MB, beside it in `bin/x64`), with the
same 28 `redgalaxy` exports, so the stub cannot replace it. `bin/x64/Galaxy64.dll`, the real GOG
SDK, has exactly one importer in the payload: `GameServicesGOG.dll`, the store plugin the exe loads
by name at runtime (the exe carries the sibling strings `GameServicesGOG.dll`,
`GameServicesEpic.dll`, `GameServicesSteam.dll`). The plugin imports 10 symbols, all `galaxy::api::`
and all in `symbols64.txt`: `Init`, `Shutdown`, `ProcessData`, `User`, `Friends`, `Apps`, `Stats`,
`Utils`, `ListenerRegistrar`, `GetError`. The GOG plugin path is neutralized by the stub; CD Projekt
Red's own copy is held by `online = false`.

Verified end to end with the stub loaded (x86_64-linux, 2026-09-03). The `Galaxy64.dll` mapped in
the running game, read through `/proc/<pid>/root`, is md5-identical to `${galaxy-stub}/Galaxy64.dll`
(33,869 bytes, against the payload's 14,208,648-byte SDK). With it bound the game creates its
swapchain at 3840x2160, raises no unhandled exception, keeps GameThread out of its parked `read()`,
stops retrying `User()->SignInGalaxy` once `OnAuthFailure` is delivered, and boots through the title
screen's "PRESS ␣ TO CONTINUE" gate to the CD Projekt Red user agreement and the main menu. This
title's `GameServicesGOG.dll` is the strictest stub consumer in the repo.

Masking `bin/x64/GameServicesGOG.dll` removes a DLL, not the GOG stack. With
`.apply { maskFiles = [ "bin/x64/GameServicesGOG.dll" ]; }` the minidump shows neither
`GameServicesGOG.dll` nor `Galaxy64.dll` loaded (Galaxy64 has exactly one importer), yet `+winsock`
shows GameThread resolving `galaxy-log.gog.com`: the statically imported `REDGalaxy64.dll` carries
that path itself.

Not the cause of the boot hang the mountmgr/dosdevices starvation produces in this title
(wine-mountmgr-dosdevices.md):

- GOG sign-in. The theory (`BaseEngine/Initialization/GameServicesAsync`,
  `GameServicesUserSignInComplete`, `NotSignedInGalaxy`/`NotSignedInLauncher`, and the three
  `[GameServicesGalaxy::SignInGalaxy]` modes) rests only on an absent log line. The `maskFiles`
  ablation above disproves it: with neither GOG DLL mapped the game hung identically, same watchdog,
  same `ZwDeviceIoControlFile+0x14`.
- The exe's SSD probe: `IOCTL_STORAGE_GET_DEVICE_NUMBER` (0x2D1080) and
  `IOCTL_STORAGE_QUERY_PROPERTY` (0x2D1400) over `\\.\PhysicalDrive%d`, about 1 ms each.
- hidraw: root-only 0600 on the host, and wine never opens it.

## Steam shim coverage (gbe_fork)

The Steam counterpart of the import check: gbe_fork's PE shim replaces the shipped
`steam_api64.dll`, so it has to export every symbol the game imports. A missing export is worse than
an absent library: the library loads and init throws `EntryPointNotFoundException` (the failure that
black-screened Hollow Knight under the predecessor emulator). The mechanism is in
steam-entitlement.md.

| title | shipped | shim | missing | confirmed at runtime |
|-------|---------|------|---------|----------------------|
| R.E.P.O. | 1086 exports | 1257 exports | none | yes |
| Shadow of Mordor (Steam) | 22 imported | all 22 | none | not run |

R.E.P.O.: the shipped library does not export `SteamAPI_Init` (inline since SDK 1.59) and routes
through `SteamInternal_SteamAPI_Init` + `SteamInternal_ContextInit`, both exported by the shim.
Every interface version the shipped dll advertises occurs in the shim's string table:
`SteamClient021`, `SteamUser023`, `SteamUtils010`, `SteamFriends017`, `SteamInput006`,
`SteamMatchMaking009`, `SteamNetworkingSockets012`, `SteamNetworkingUtils004`,
`STEAMAPPS_INTERFACE_VERSION008`. At runtime the boot log prints `Steam - App ID: 3241660` and
`Steam - User ID: 765611…` (Facepunch.Steamworks initialised over the shim and read back an id),
`AppData/Roaming/GSE Saves/settings/configs.user.ini` appears in the users overlay (gbe_fork writes
it only once the game calls into it), and the game goes straight to its menu with no
`EntryPointNotFoundException`.
