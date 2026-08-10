# wine-fex — x86_64 (and x86) Windows apps on 16K aarch64-linux, without muvm

> **These are the validated POCs + design notes.** The productionised tree now lives at the repo root
> (`flake.nix`, `lib/`, `emulators/`, `pkgs/`) — the `.nix` files here remain the authoritative **spec**
> the production code ports from (the Rust launcher `pkgs/propnix-launcher` ports `winefex.nix`
> stage-for-stage). Build/run the real thing with `nix run .#hollow-knight` (see the root `README.md`).

Goal: run Windows-only x86_64 games (Hollow Knight Windows build, and ultimately titles
with no Linux build such as Baldur's Gate 3) on this 16K-page Asahi host, using native
aarch64 WINE with FEX as the x86 CPU emulator — the Hangover architecture, packaged in nix.

## Why this path (vs. the Linux FEX path in ../fex-portable)

The Linux `fex-portable` fork runs x86_64 *Linux* ELFs, but a JIT/GC-heavy guest (Unity's
Mono) hits the 4K-vs-16K permission wall that only a soft-MMU would solve. The WINE path
sidesteps it: the x86_64 code runs as **ARM64EC inside a native-ARM64 WINE process** — no 4K
Linux guest, no `ld.so`; memory/protection are WINE's `ntdll` at the host page size, and FEX
only translates instruction blocks. (It is neither "WINE large-page support" nor NT 64K
granularity papering over it — RESEARCH §12; Route B has its own per-title walls, PLAN2 §2.2.)

## The blocker this solves

To host an x86_64 (ARM64EC) process, WINE's core PE DLLs (`ntdll`, `kernel32`, …) must be
**ARM64X hybrid** (carry CHPE metadata). Stock nixpkgs `wineWow64` (stable or staging) builds them **plain
ARM64** (`CHPEMetadataPointer: 0x0`), so an x86_64 process can't load them → `STATUS_NOT_SUPPORTED`
(0xc00000bb), and the FEX emulator never even loads. nixpkgs' wine already builds its PE side
with llvm-mingw (clang) and passes `--enable-archs=aarch64,x86_64,i386` — it just omits
`arm64ec`, which is what makes the core DLLs hybrid.

## The pieces

- **`llvm-mingw.nix`** — prebuilt clang/LLVM toolchain (mstorsjo/llvm-mingw) that targets
  `arm64ec-w64-mingw32`; autoPatchelf'd for NixOS. Validated: produces
  `IMAGE_FILE_MACHINE_ARM64EC` objects on this host. (nixpkgs' wine build carries its own copy
  of this toolchain; ours is for building FEX's EC DLL from source later.)
- **`wine-hangover.nix`** — **Hangover's wine fork** (`AndreRH/wine`@`arm64ec` = upstream wine 11.15 + the
  ARM64EC/WoW64 commits, one coherent tree; *not* staging), built by us via `wineWow64Packages.unstable`'s
  machinery with: `arm64ec` added to `--enable-archs` (→ ARM64X-hybrid core DLLs), `dontStrip = true`
  (§ below), and `gstreamerSupport = true` (Media Foundation decode; RESEARCH §18). The fork supplies the
  WoW64 runtime glue directly — cherry-picking those commits onto nixpkgs' 11.12 failed the compile
  (upstream-11.15 baseline gap; RESEARCH §22.1). No `wine-patches/`.
- **`fex-dlls.nix`** — FEX's emulator DLLs, **built from source at FEX-2607** with `llvm-mingw.nix`:
  `libarm64ecfex.dll` (x86_64 guests, ARM64EC 0xA641) + `libwow64fex.dll` (i386 guests, native ARM64
  0xAA64) from FEX-Emu/FEX, plus `wowbox64.dll` from AndreRH/box64. (This is a distinct target from
  `../fex-portable`, which builds FEX as a *Linux* binary for x86 ELF guests.) RESEARCH §22.
- **`dxvk-arm64ec.nix`** — DXVK (D3D9/10/11 → Vulkan) built from stock DXVK 2.7.1 as **native ARM64EC** PE
  DLLs, using `llvm-mingw.nix` (its `postFixup` re-indexes the compiler-rt builtins archives so the ARM64EC
  `#`-mangled symbols link — RESEARCH §22). Selected at runtime via `PROPNIX_WINE_D3D=dxvk`; the fast
  Vulkan path (wined3d's Vulkan renderer stalls to ~12 fps; DXVK → 60). `reindex-ar.py` is the archive fix.

## Wiring (validated mechanism)

In the WINE prefix: drop the FEX DLLs into `system32` and set
`HKLM\Software\Microsoft\Wow64\amd64 = libarm64ecfex.dll` (x86_64) and
`…\Wow64\x86 = libwow64fex.dll` (i386). Then `wine some_x86_64.exe`.

This is **baked into `wine-prefix-lower.nix`** (the store-built system tree) and symlinked into each
per-app prefix — there is no manual `reg add` at launch time.

## Status

**Working (2026-08-06): x86_64 Windows runs under wine+FEX on the 16K host — including a real
game.** Verified with an x86_64 `hello.exe`, a compute/FP `wintest.exe`, and — the decisive
result — the **Windows Hollow Knight is playable** (`hollow-knight-win.nix`): it boots through
Unity + Mono, renders via **native ARM64EC DXVK → Vulkan (60 fps — the default)** on the Apple GPU
(`PROPNIX_WINE_D3D=wined3d` selects the wined3d-GL fallback, also 60; wine's builtin wined3d-Vulkan
present-stalls to ~12 — RESEARCH §22), and a save can be started and
played. This is the exact workload that defeated the Linux `../fex-portable` path (Mono JIT +
graphics), working here because native-ARM64 wine owns the loader/Mono/memory/graphics and FEX
only JITs the x86_64 code. It is the intended path for Windows-only titles (e.g. Baldur's Gate 3).

Known minor issue: opening cinematics play **audio but no video** (skippable; gameplay renders fine).
Root cause is wine's Media-Foundation *video* pipeline (winegstreamer caps negotiation + a stubbed
`video_processor` MFT), not wined3d or a codec — RESEARCH §18. Enabling `gstreamerSupport` fixed the prior
black-and-silent state (the MF classes register; audio decodes). Not fixed by wine-staging.

The complete fix in `wine-hangover.nix` is two lines: add `arm64ec` to `--enable-archs`, **and
`dontStrip = true`** — stripping drops the sections that carry the ARM64X load-config, so wine
can't flip the header to the EC view → `STATUS_NOT_SUPPORTED` (`0xc00000bb`) loading ntdll (full
mechanism, and the byte-identical stock-wine/Hangover loaders, in RESEARCH §15). No wine source patch needed.

For fast iteration, an incremental wine dev tree lives in `scratchpad/winedev` (configure once via
`nix-shell wine-hangover.nix`, then `make` rebuilds a single DLL in seconds).

The reusable runner is **`winefex.nix`**: it assembles the wine prefix as a **symlink farm** — a
persistent per-app directory whose read-only content (the wine+FEX system tree — `wineboot` + FEX DLLs +
Wow64 keys, **built into the nix store** as `wine-prefix-lower.nix`) is symlinked in, while the writable
content (HKCU, the user profile) is real and persists there. No overlay, no mount, no namespace — so the
game runs as the real user with every host group intact. The RO symlinks are recreated each launch, so a
wine/FEX bump swaps the system tree while the user's data (HKCU, AppData) carries over; the system tree's
DLL closure is prefetched into cache at launch via `propnix-prefetch` (§7.2 / PLAN2 §6). Windows Hollow
Knight runs on it from the pinned GOG **Galaxy** build (`hollow-knight-win.nix`). Next: a D3D11-heavy
title (Baldur's Gate 3) via DXVK.

## Follow-ups (backlog)

- **MangoHud as a first-class dependency.** `PROPNIX_BENCH` currently shows DXVK's built-in HUD (fps,
  frametime, GPU load, GPU/driver, DXVK version, D3D level) — free on the DXVK backend, nothing extra
  needed. To get the same on-screen overlay on the **non-DXVK backends** (wined3d, and later the box64
  Linux path), add MangoHud as a runtime dependency and drive it via `MANGOHUD=1` there; also port the
  `/proc` RSS/CPU bench sampler from the POC `winefex.nix` `benchRunner` for a logged floor.
- **HODLL amd64 reg-add cleanup.** Hangover's wine may default the amd64 (x86_64) emulator via its HODLL
  glue, in which case `wine-prefix-lower.nix`'s explicit `HKLM\…\Wow64\amd64 = libarm64ecfex.dll` reg-add
  becomes redundant and could be dropped. Investigate against the fork's `HODLL` handling before removing
  (the `x86` key is still needed).
