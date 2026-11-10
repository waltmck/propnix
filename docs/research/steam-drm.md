# Steam DRM in depot payloads: SteamStub and CEG

A pinned Steam depot is the exact bytes Valve ships, and two of Valve's DRM schemes leave marks in
those bytes that decide whether a title can run under propnix at all. SteamStub (v3.1) wraps a
runnable exe: the wrapper checks ownership through its own embedded Steam API, and gbe_fork can
patch it in memory (`steam.emu.steamStub`). CEG (Custom Executable Generation) ships a template exe
that exits at its entry point; the runnable bytes are never depot content, so no shim or emulator
can help and the only route is another platform's depot. This page records how to recognise each,
the decoded anatomy, and the per-title run evidence. The shim side of SteamStub is in
[steam-entitlement.md](steam-entitlement.md#steamstub-wrapped-exes-steamemusteamstub).

## Recognising each

SteamStub v3.1:

- PE shape: a 10th section named `.bind`, high entropy, whose range contains `AddressOfEntryPoint`.
- With gbe_fork alone: the engine loads, then the process exits 53 at the wrapper's ownership check.
- The embedded `SteamDRMP.dll` is AES-encrypted, so its strings are not visible.
- Remedy: `steam.emu.steamStub = true`.

CEG:

- PE shape: the entry point is a three-instruction notify-and-exit stub, and the exe has an export
  table naming the original `… CEG.exe` build.
- Behaviour: exit 173 (`0x8000dead & 0xff`) at entry, nothing drawn, no asset opened.
- Strings: `This file has been stripped`, `STEAM_DRM_IPC`, `STEAM_DIPC_CONSUME`,
  `STEAM_START_ACK_EVENT`, `.STEAMSTART`.
- Remedy: none for that exe; use another platform's depot if its binary is clean.

Entropy does not detect CEG: the template's code is not encrypted (`.text` entropy ~5.0), and it
imports no `Steamworks_*` CEG runtime function. The replaced entry point is the whole wrap; WinMain,
the engine and the renderer are all present and never execute.

## SteamStub v3.1

### Anatomy (Civilization VI)

`CivilizationVI.exe` (and `CivilizationVI_DX12.exe`, identically) is not a plain PE. It carries a
10th section named `.bind` (206104 bytes, high entropy), and its entry point is inside it:
0x036d1310, while the real code starts at 0x00e950dc. The wrapper's own header sits at
EntryPoint-0xF0, dword-XOR chained from its first dword. Decoded:

    signature 0xC0DEC0DF   imagebase 0x140000000   OEP 0x00e950dc   appid 289070   flags 0x6
    embedded payload: a 191336-byte AES-encrypted SteamDRMP.dll at .bind+0x39b0

The wrapper decrypts the image, then manually maps its embedded `SteamDRMP.dll` (Valve's own Steam
API) and asks that whether the app is owned. That code is not the `steam_api64.dll` on disk, so
replacing the on-disk library, which is all `steam.emu` otherwise does, cannot answer it.

### Locating the caller (Civilization VI)

The targeted wine `+relay` trace that places the wrapper's Steam calls in an anonymous mapping, the
controls that prove the on-disk library is never consulted, and the reasons propnix loads gbe_fork's
patcher from a proxy DllMain rather than upstream's loader are in the header of
emulators/gbe-fork/steamstub-proxy.nix. Details that trace adds:

- The relay is narrowed to `OutputDebugString`/`ShellExecute`. The full set of wrapper lines:

      Call KERNEL32.OutputDebugStringA("[S_API] SteamAPI_Init(): SteamAPI_IsSteamRunning() …") ret=01054a4e
      Call KERNEL32.OutputDebugStringA("[S_API] SteamAPI_Init(): Could not determine Steam …") ret=01054c77
      Call shell32.ShellExecuteA(0,"open","steam://run/289070//",0,0,1)  ret=01053ec2

- `steam://run/%u//` is a format string that exists in the payload's shipped Valve `steam_api64.dll`
  and in no Firaxis binary.
- The live-bind control: gbe_fork's shim bound directly over the shipped dll (`PROPNIX_EXTRA_BINDS`)
  changes those three lines not at all, while a non-PE bound over the same path produces
  `err:module:import_dll … failed (c000012f)`.
- `steam.emu`'s union replacement is inert for this title's boot; it still serves the DLC
  entitlement once the game runs.

### Run evidence (Civilization VI, x86_64-linux, 2026-09-03)

Run as `nix run .#civilization-6` under a headless sway on an RX 7900 XTX.

Without `steam.emu.steamStub`: `PROPNIX_WINEDEBUG=+loaddll` shows the wrapper unpacking and the
engine loading (DatabaseDLL, Localization, HavokScript, bink2w64, EOSSDK, then dxgi + d3d11, then
DXVK reading its own env). The process dies after all that, at the ownership check, with exit 53.

With `steam.emu.steamStub = true`: window, Bink logo movies, the ~2.5-minute intro cinematic, then
the front end (the CIVILIZATION VI title card with its legal text and a live `Continue` button,
screenshotted). The engine's logs are the durable evidence:

    Renderer.log       Renderer::CreateD3DDevice() → CreateDefaultSwapChain 1920x1080 @60,
                       Fullscreen, "Selected GPU device: AMD Radeon RX 7900 XTX (RADV NAVI31)"
    UserInterface.log  ForgeUI started up! … ContextBase::Initialize 'StartupScreen' /
                       'IntroScreen', LOADING ../../../Base/Assets/UI/FrontEnd/IntroScreen.lua
    Modding.log / ArtDef.log / Lua.log / Database.log / Localization.log   all populated

Ruled out by inspection on the same build: the static import closure resolves completely (44
modules: the engine's own `*_FinalRelease.dll`, EOSSDK and bink2w64 beside the exe, the rest prefix
system32 or apiset forwarders), and all 17 `steam_api64.dll` entry points the exe imports statically
are exported by the gbe_fork PE shim.

### The exit-53 trap

Without the patcher the launch exits immediately with status 53, shows no window, and writes nothing
anywhere: the save dir is empty, and so is the persistent profile overlay's upper
(`$PROPNIX_STATE/wine/users`, which holds exactly what a run wrote), including gbe_fork's
`AppData/Roaming/GSE Saves/settings/configs.user.ini`. That absence does not mean the process died
before the first Steam API call and so before the engine: `+loaddll` shows the engine fully loaded
and DXVK initialising first. The wrapper's ownership check runs inside the process's own startup,
and losing it exits before the engine opens a single file. An empty directory bounds nothing about
how far execution got; a loader or relay trace does.

### `steam.emu.offline` does not reach a wrapped exe

The offline key only changes what gbe_fork answers (`BLoggedOn`/`BConnected`/`GetLogonState`). A
wrapper carrying its own copy of Valve's API never asks gbe_fork, and flipping the key on
Civilization VI changes nothing.

### Skyrim Special Edition (Steam)

The other SteamStub-wrapped payload in the tree is Skyrim SE's Steam build: `SkyrimSE.exe` carries
the same signature and flags 0x6, with appid 489830. The Steam build is not launched; everything
verified for Skyrim SE is measured on the GOG build, whose exe is a different, unwrapped binary. A
Steam launch needs `steam.emu.steamStub = true`.

### What the patcher does not cover

gbe_fork's patcher handles only the `.bind` variant (see
[steam-entitlement.md](steam-entitlement.md#steamstub-wrapped-exes-steamemusteamstub)), and gbe_fork
does not implement the older `STEAM_DRM_IPC` startup handshake.

## CEG

CEG ships a template exe in the depot and generates the runnable, per-user exe for an entitled
account at install time, in the real Steam client. The runnable bytes are not depot content, so
`fetchSteamDepot` can never obtain them, and no pin could make them reproducible if it could. This
is the general limitation of raw depot downloads for CEG titles, independent of host, emulator,
renderer or Steam-API shim: nothing can reach code that exits at its entry point.

### Civilization V: the Windows exes are templates

Measured on the payload:

- `AddressOfEntryPoint` of `CivilizationV.exe` is a three-instruction stub with no conditionals and
  no fall-through:

      call <notify Steam>
      push $0x8000dead
      call *KERNEL32!ExitProcess

  All three game exes (DX9, DX11, Tablet) have that shape, and every launch exits 173
  (`0x8000dead & 0xff`) having drawn nothing and opened not one game asset.

- Each exe has an export table (unusual for an EXE) whose name field is the original build:
  `Civ5Win32Final Release Steam CEG.exe`.

- A sibling of the stub is a guarded `MessageBoxA(NULL, "This file has been stripped", …)`, Valve's
  own wording for this state.

- The stub performs the `STEAM_DRM_IPC` startup handshake. Answering it (a patched gbe_fork build)
  shortens the refusal from ~33 s to ~13 s and still exits 173.

### Civilization V: the Linux build is clean

CEG replaced the Windows PE's entry point; Aspyr's Linux build is a separately built ELF and reaches
the game's own code. Checked against the artifact rather than assumed from CEG being a Windows
mechanism:

- `Civ5XP` (36 MB i386 ELF) enters a textbook glibc `_start` whose `main` tail-calls `ASL::Main(…)`,
  Aspyr's shim layer, which takes the original WinMain as a function pointer.
- None of the Windows build's DRM markers (`STEAM_DRM_IPC`, `STEAM_DIPC_CONSUME`,
  `STEAM_START_ACK_EVENT`, `.STEAMSTART`, `"has been stripped"`) appears in any of the depot's 37
  files; none of its 821 imports matches `ceg`/`drm`/`secret`/`Steamworks_`; `.text` entropy is
  6.23; it keeps 43706 dynamic symbols.
- It runs (`steam/i386-linux`, on aarch64 through emulators/fex-linux).

### Detection recipe

Before packaging any Windows Steam title:

1. Disassemble at `AddressOfEntryPoint`. Three instructions ending in
   `push $0x8000dead; call *KERNEL32!ExitProcess`, or a launch that exits 173, is CEG.
2. Check for an export table on the exe whose name field contains `CEG`.
3. Grep for `This file has been stripped`.

For a CEG title, check the other platforms' depots the same way; Civ V ships on its Linux depots.
