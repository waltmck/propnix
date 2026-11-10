# The read-only wine system tree (prefixLower)

emulators/wine-prefix-lower.nix builds, in the Nix sandbox, a fully initialized wine "system"
prefix: the `wineboot -u` output (system32/syswow64, the default registry hives, DLL registration),
the FEX and box64 WoW64 DLLs with the registry keys that select them (aarch64), and the .NET CLR
(wine-mono-clr-in-prefix.md). Every per-app prefix view mounts it read-only. This document records
how the tree reaches a prefix, the gaps `wineboot -u` leaves for 32-bit (i386) guests and how each
is filled, and what keeps the tree bit-reproducible.

## How the tree reaches a prefix

The name "lower" does not mean the whole tree is an overlay lowerdir. The wine defaults
(`lib/backends/wine/defaults.nix`, `staticMounts`) mount individual subtrees of the store path into
the prefix view:

| target | mount |
|--------|-------|
| `.update-timestamp` | read-only bind |
| `drive_c/windows` | read-only bind |
| `drive_c/Program Files`, `drive_c/Program Files (x86)` | read-only bind |
| `drive_c/windows/temp` | ephemeral overlay (tmpfs upper), no skeleton |
| `dosdevices` | ephemeral overlay (tmpfs upper), no skeleton |
| `drive_c/users` | persistent CoW overlay, upper `$PROPNIX_STATE/wine/users` |
| `drive_c/ProgramData` | persistent CoW overlay, upper `$PROPNIX_STATE/wine/programdata` |

`.update-timestamp` holds `disable`, so wine never auto-runs wineboot against the prefix at runtime.
A wine or FEX bump produces a new store path, which the next launch mounts; nothing is reprovisioned
in place.

The tree ships all three registry hives, `system.reg` (HKLM), `userdef.reg` (HKU\.Default) and
`user.reg` (HKCU), as the wine-generated bases (`lib/builders/wine.nix`,
`lib/builders/wine-reg.nix`):

- `system.reg` and `userdef.reg`: `mkWineReg` applies the game's `systemReg`/`userdefReg` overrides
  on top of the base with `wine reg add` (no overrides returns the base hive verbatim, with no new
  store path) and the result is bound read-only.
- `user.reg`: the game-agnostic HKCU seed. It is copied into the persistent prefix root
  (`$PROPNIX_STATE/wine/prefix`, the mount at target `""`) on first launch through the row's `seed`,
  and every propnix HKCU override (graphics driver, DPI, per-game `userReg`, fps/vsync rows) is
  applied at each launch by the three-way merge, never baked. The root is a writable mount rather
  than a bind of the file because wine saves `user.reg` through `user.reg.tmp` + rename(2), and
  rename cannot replace a bind-mounted file (EBUSY).

Inside the tree, the syswow64 entries, the DLLs in the derived x86 SxS directories and
`drive_c/windows/mono/mono-2.0` are symlinks to fixed store paths. They resolve inside the
launcher's private mount namespace, where `/nix` is visible, and they keep the build
bit-reproducible.

The prefix is built for the fixed user `propnix` (`passthru.wineUser`); the launcher pins
`USER`/`LOGNAME` to it, so the store-built profile `drive_c/users/propnix` is found as-is. A
post-wineboot rename makes this hold whatever name wineboot picks in the sandbox.

## 32-bit (i386) guests

`wineboot -u` populates only the 64-bit side of this WoW64 prefix. Each gap below is filled at build
time; together they are what lets an i386 Windows title start, draw and play audio. Homeworld
Remastered Collection (`HomeworldRM.exe` and its HW1/HW2 Classic exes) and Don't Starve are i386;
the x86_64 titles run as ARM64EC on aarch64 and need none of this. The emulator-DLL and SxS steps
are aarch64-only; the syswow64 and CLSID steps run on both hosts.

### The i386 emulator DLL name: `wowbox64.dll`

On aarch64, Hangover's `wow64.dll` loads the x86 CPU emulator by the hard-coded name `wowbox64.dll`
(a UTF-16 literal in `wow64.dll`). It does not read the `HKLM\Software\Microsoft\Wow64\x86` value
the build writes, so without a file of that name every i386 guest aborts at startup with

    err:wow:load_64bit_module failed to load dll c0000135

(STATUS_DLL_NOT_FOUND). box64's `wowbox64.dll` is Hangover's default i386 emulator and is what the
tree installs; FEX's `libwow64fex.dll` is the alternative and would work renamed to `wowbox64.dll`.
The x86_64 (amd64) backend is FEX's `libarm64ecfex.dll`, selected by
`HKLM\Software\Microsoft\Wow64\amd64`. On an x86_64 host this whole step is skipped: wine's native
WoW64 runs i386 and x86_64 is native.

### Empty syswow64

`wineboot -u` copies the 64-bit/ARM64EC builtins into system32 but leaves syswow64 empty (0 files).
A 32-bit guest then dies at startup with

    wine: could not load kernel32.dll, status c0000135

because the loader finds no i386 kernel32/user32/… in the prefix. wine ships every i386 module in
`${wine}/lib/wine/i386-windows`, and the build symlinks the whole set into syswow64, only where
wineboot created nothing (so any fake it did write wins), skipping `*.a` build-time import
libraries.

Every module type is linked, not just `*.dll`: the graphics drivers are `.drv` files (`winex11.drv`,
`winewayland.drv`), and without them a 32-bit GUI process fails to bind a display driver and aborts
windowless with

    err:winediag:nodrv_CreateWindow ... The explorer process failed to start

The set also brings the i386 `.cpl`, `.exe`, `.acm`, `.ocx`, `.tlb` and `.drv16` companions. On
x86_64 the same i386 tree feeds native WoW64.

### MMDeviceEnumerator registered only in the 64-bit view

`wineboot -u` populates `HKLM\Software\Classes\CLSID` (the native arm64ec/64-bit view, 2288 entries)
but leaves `HKLM\Software\Wow6432Node\Classes\CLSID` empty (0 entries). A 32-bit process's
`CoCreateInstance(MMDeviceEnumerator)` then returns REGDB_E_CLASSNOTREG, and DirectSound/WASAPI find
no audio endpoint: the app runs mute. Verified in Don't Starve (32-bit, FMOD):

    err:dsound:get_mmdevenum CoCreateInstance failed: 80040154
    SoundSystem::Initialize failed

64-bit titles are unaffected. The build mirrors the entry into the 32-bit view as
`{BCDE0395-E52F-467C-8E3D-C4579291692E}` with `InprocServer32` = `C:\windows\system32\mmdevapi.dll`
and `ThreadingModel` = `Both`; the WoW64 file redirector resolves system32 to syswow64 (the i386
`mmdevapi.dll` linked above) for a 32-bit caller. Audio is the COM class every 32-bit title needs;
another 32-bit builtin class gets the same mirror when a title needs it. The .NET NDP detection keys
are written into both views for the same reason.

### SxS manifests emitted only for arm64

`wineboot -u` on the ARM64X build emits side-by-side manifests only for the arm64 arch:
`winsxs/manifests` has `arm64_*` and no `x86_*`. A 32-bit process that requests a side-by-side
assembly then fails. In Homeworld, `DCWindow.dll` pulls in comdlg32/comctl32, whose DllMain calls
`CreateActCtx` for `Microsoft.Windows.Common-Controls` 6.0; that fails with error 14001
(ERROR_SXS_CANT_GEN_ACTCTX) because no `x86_` manifest matches the process arch, and
`DCWindow.dll`'s init dereferences the resulting uninitialised state: EXCEPTION_ACCESS_VIOLATION
before the first frame, reproduced on both the box64 and the FEX i386 backends.

The build derives each `x86_` variant from the `arm64_` one: the same manifest with
`processorArchitecture="x86"` under the `x86_`-prefixed filename SxS matches by arch, plus an `x86_`
assembly directory carrying symlinks to the i386 build of each DLL from the i386-windows tree. On
x86_64 wineboot emits the `x86_`/wow64 manifests itself, the `arm64_` glob is empty and the step is
a no-op.

## Reproducibility

The tree is bit-reproducible: `nix-store --realise --check` passes. wineboot otherwise bakes
non-deterministic state into the output. The Nix sandbox normalizes output-file mtimes but not clock
or `/dev/urandom` reads during the build, and faketime is not an option (freezing the clock hangs
wineboot's internal waits). The sources, and what pins each:

- Random GUIDs. `MachineGuid` is set with `reg add` to `b0000000-0000-4000-8000-00000000c0de`;
  `MachineId`, `VideoID` and `ContainerId` (synthetic sandbox devices, re-enumerated from the host
  at runtime) are rewritten by a value-name-anchored `sed` to fixed
  `a0000000-0000-4000-8000-00000000000{1,2,3}` values.
- Wall-clock key stamps. Every `[Key] <filetime>` suffix and `#time=` line in `system.reg`,
  `userdef.reg` and `user.reg` is normalized to 0, as the last step, after which no wine process
  runs.
- `PendingFileRenameOperations`, a stale queue of random `dll*.tmp` names from the DLL install, is
  deleted.
- The `dll*.tmp` files themselves, wineboot's DLL-install temp cruft. Their rename queue is gone and
  wineboot never runs at runtime, so they are dead, and their random names are the last drift.

Fixed values are correct for every user because the hives are served read-only and games read none
of these values.

### Where wineboot leaves `dll*.tmp`

wineboot does not leave its temp files only at the top of system32. Measured on a tree whose sweep
was limited to `system32 -maxdepth 1` (`nix-store --realise --check` on that derivation): 33
surviving `dll*.tmp` under `drive_c/windows/syswow64` plus one under
`drive_c/windows/resources/themes/aero`, with fresh random names on each run, so `--check` fails.
The build therefore sweeps the whole windows tree:

    find "$WINEPREFIX/drive_c/windows" -name 'dll*.tmp' -delete

`find` does not follow symlinks by default, so the Mono runtime linked in at `windows/mono/mono-2.0`
is a leaf and its 2 790 files are never walked.
