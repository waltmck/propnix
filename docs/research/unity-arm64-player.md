# Unity's native ARM64 Windows player under wine on aarch64

The facts behind `emulators/unity-player`, `lib/modules/unity-player.nix`, the per-target Windows package
set (`winPkgs.<target>`, `lib/win-toolchain.nix`) and the ARM64 builds of its contents. The code carries
the design; this page carries what was measured and where the numbers come from.

## What Unity publishes

Every editor release's Windows Build Support (Mono) module is a macOS target-support installer on the
download CDN:

    https://download.unity3d.com/download_unity/<changeset>/MacEditorTargetInstaller/UnitySetup-Windows-Mono-Support-for-Editor-<version>.pkg

It is an xar archive; `TargetSupport.pkg.tmp/Payload` is a gzip-compressed cpio whose `Variations/`
directory holds the player binaries the editor copies into a build: `win64_player_nondevelopment_mono`,
`win_arm64_player_nondevelopment_mono`, their `development` siblings, and `mono` (the editor's own). The
ARM64 variation contains `UnityPlayer.dll`, `WindowsPlayer.exe`, `UnityCrashHandler64.exe`, a `Data/`
directory, and `MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` — every PE `IMAGE_FILE_MACHINE_ARM64`
with no CHPE metadata (plain ARM64, not ARM64EC). The ARM64 variation ships no `MonoPosixHelper.dll`
and none of the NV/AMD helper plugins the x64 one has. Unity added the Windows ARM64 player in 2023.1;
2022.3 and older streams have no ARM64 variation.

The release API maps a version to its changeset and lists the module:

    https://services.api.unity.com/unity/editor/release/v1/releases?version=<version>

`results[].shortRevision` is the changeset; the `windows-mono` module entry (nested under the
platform downloads) carries the URL above, `downloadSize.value` and an md5 `integrity`. For 6000.0.61f1:
changeset `74a0adb02c31`, 309 040 054 bytes, SRI `sha256-eQ+uwEnymAd5Yiz2R21tFtFbPYYbpL7WfHz8gj8eU4g=`.
`ci/unity-player-check.sh` holds every packaged row to the API and a CDN HEAD on each CI run;
`.github/workflows/unity-player-verify.yml` downloads and extracts each row weekly.

## Why a title's data runs on it

A Mono-backend Windows build consists of the player (`UnityPlayer.dll`), a stub exe, the runtime, the
title's `<name>_Data` (assets, `Managed/` IL) and whatever native plugins the title vendors. The stub exe
derives `<name>_Data` from its own filename, so `WindowsPlayer.exe` installed under the title's exe name
is the entire integration. Hollow Knight's managed code is pure IL (134/134 DLLs), so nothing of the
game needs recompiling; the ARM64 player reads the x64 build's data directory unchanged.

Native plugins: the ARM64 player resolves them from `<Data>/Plugins/ARM64/` and never consults the x64
directory, so a title's vendored x64 plugins are simply absent rather than mis-loaded. Hollow Knight's
plugins are `steam_api64.dll` (the Steam build; `lib/modules/steam-emu.nix` places the ARM64 gbe_fork
there), `GalaxyCSharpGlue.dll` (the GOG build; absent, and the game's GOG init tolerates the missing glue
— verified in-game), `InControlNative.dll` (Hollow Knight ≥ 1.5 reads input through the Unity Input
System, so it is never asked for) and `XInputInterface64.dll` (XInputDotNet, MIT; an ARM64 build is a
candidate `unity.player.plugins` entry if a title needs it).

The x64 payload also carries `D3D12/D3D12Core.dll` (the Agility SDK). With DXVK/vkd3d or wine's d3d12 as
the D3D12 runtime that path is never consulted; no load error appears in the trace.

## The platform

`aarch64-windows` is an `emulatedPlatform` of its own (lib/strategy.nix): `lib/modules/unity-player.nix`
pins the pair from a title's `x86_64-windows` rows whenever their recorded player version is packaged,
the game ranks it in `platformPreference`, and `runnable` restricts it to aarch64 hosts (on x86_64 an
explicit selection evaluates and is refused at build as `meta.broken`, exactly like aarch64-linux
content). Everything platform-keyed — the Galaxy stub, DXVK/vkd3d, the Steam shim and its placement —
reads `emulatedPlatform` and `winPkgs.<platform>`; the x64 platform keeps the ARM64EC Mono runtime.

## Verified

Hollow Knight (GOG and Steam Windows builds, Unity 6000.0.61f1) on the Asahi aarch64 host, wine +
`PROPNIX_WINEDEBUG=-all,+loaddll`: `Hollow Knight.exe`, `UnityPlayer.dll`, our `mono-2.0-bdwgc.dll` and
`UnityCrashHandler64.exe` map as `native`, and no emulation DLL (`libarm64ecfex.dll`, `wowbox64.dll`) is
loaded during the run. In-game on wined3d (user-verified); the default D3D backend is the plain-ARM64
DXVK/vkd3d from `winPkgs.aarch64-windows`.

The intro video plays on the native platform and does not on the x64 player under FEX (user-verified
A/B). wine's Media Foundation/gstreamer path is the same builtin code for both processes, so the
difference is in the x64 code FEX executes — Unity's in-player video decode — not in wine: a FEX wall of
the x64 platform, which the native platform does not have.

## Pin facts

`propnix pin` records `unityVersion`, `unityChangeset` and `unityScripting` per row (a streaming-hash tap
on `UnityPlayer.dll`, `--fingerprint` for a backfill; both stores). The player's version string is
`<major>.<minor>.<patch><type><n>[-suffix] (<12 hex>)` — UTF-16 from 2022.3 on, ASCII in older players —
and the players also carry decoy strings (`5.0.0a1`, `2018.3.0a1`) ahead of the real one, so the
hash-suffixed form is matched first (`pkgs/propnix-cli/src/pin/unity.rs`, `lib/builders/unity-version.sh`).
Rows read off real payloads: Hollow Knight `6000.0.61f1`/`74a0adb02c31`/mono (all three rows), REPO
`2022.3.67f2`/`6bedba8691df`/mono, Silksong `6000.0.50f1-uum-100966-branch1`/`16f07294548e`/mono (an
internal Unity branch: no public module exists), KSP `2019.4.18f1`, Iron Lung `2021.1.15f1`.

**A player serves only data whose type hashes match its classes.** Tried for Silksong with the public
6000.0.50f1 ARM64 player (changeset `f1ef1dca8bff`, the nearest public release to the branch build),
in two steps. (1) As shipped: the process starts natively and stops at the first engine step —
Player.log reads `PlayerInitEngineNoGraphics settings: Failed to load PlayerSettings (internal index #0).
Most likely data file is corrupted, or built with mismatching editor and platform support versions.`
(2) With every root serialized file's engine string rewritten to `6000.0.50f1` in place (SerializedFile
v22: the real `metadata_size`/`data_offset` follow the legacy header fields; the metadata after the
string shifts, the data section stays): the same refusal. The gate is the 16-byte per-type hash a player
build records for each class in place of a type tree: Silksong's `globalgamemanagers` shares 17 of its
19 class hashes with Hollow Knight's 6000.0.61f1 file and differs in `PlayerSettings` (129) and
`PhysicsManager` (55), and the converse test — Hollow Knight's 61f1 data retagged to 50f1 on the 50f1
player — fails identically, so those layouts drift between 6000.0.x patch releases and the branch's
match no public release's. UUM-100966 itself is an audio main-thread stall fix. What remains would be
injecting full type trees for all classes of the root files (from a 6000.0.50f1 type-tree dump) so the
player takes its safe-read path, with the branch's true layouts unknown — not pursued. A future patch
of the title built on a public release gets the native platform automatically through its pin.

## The ARM64 target set

`lib/win-toolchain.nix` names four PE targets; `winPkgs.aarch64-windows` holds the plain-ARM64 builds a
native process loads: the Galaxy stub, DXVK, vkd3d-proton, the Mono runtime and the gbe_fork Steam shim,
all with llvm-mingw. Facts met building them:

* **nixpkgs' Windows cross sets are unusable here.** `pkgsCross.ucrtAarch64`'s clang toolchain does not
  bootstrap on the pinned nixpkgs (its compiler-rt builtins compile before winpthreads' `pthread.h`
  exists), and `curl`/`portaudio` refuse to evaluate for any Windows host platform (`pkgsCross.mingwW64`
  included). `pkgsCross.ucrtAarch64.pkgsStatic` silently switches to an experimental GCC 15 aarch64-mingw
  toolchain. So the shim's seven static dependencies are built from nixpkgs' pinned *sources* with
  llvm-mingw through each library's own CMake (`emulators/gbe-fork/win-deps.nix`), the way upstream's
  own Windows release is built.
* **ARM64EC vs ARM64 compiler macros.** `arm64ec-w64-mingw32-clang` defines `__x86_64__` and `__arm64ec__`
  and *not* `__aarch64__`; `aarch64-w64-mingw32-clang` defines `__aarch64__` only. Both define
  `__MINGW64__`, which several upstream sources (Mono's `valgrind.h`, bdwgc's `gcconfig.h`) read as "x64".
  A gate meant to exclude every ARM build must name both macros.
* **An ARM64EC image is an x64 image.** Its COFF machine is `IMAGE_FILE_MACHINE_AMD64`; only the CHPE
  metadata pointer in the load config distinguishes it (what wine's loader tests). `0xA641` is the
  machine of ARM64EC *object* files. `lib/pe-check.py` checks both facts for every PE built.
* **Mono 6000.0 on plain ARM64 mingw** needed three build fixes beyond the ARM64EC family
  (`emulators/unity-mono/patches/6000.0/0001`, `patches/bdwgc/0002`): `valgrind.h` took the amd64 branch
  via `__MINGW64__` (x86 client-request asm); the port's non-MSVC stack-probe registration names mingw's
  x64 `___chkstk_ms`, which has no AArch64 definition — a branch trampoline binds it to compiler-rt's
  `__chkstk`, whose contract (x15 = frame size in 16-byte units) is what the JIT prolog emits; bdwgc
  classified a mingw-aarch64 host as `NOSYS` (bare metal, newlib's `__stack_base__`) because its AArch64
  rule never excluded `_WIN32` and its Windows block knew AArch64 only by MSVC's `_M_ARM64`. `oop.c`'s
  x64 dynamic-function-table path must be gated on x64 proper: on ARM64 it includes `mini/mini.h`, whose
  GC-define guard fires inside `libmonoruntime`. The ARM64 player binds 286 `mono_*` entry points; our
  runtime exports them all (the tree builder checks the intersection with the module's own runtime).
  `support/` (MonoPosixHelper) builds for every target and is shipped beside the runtime.
* **The gbe_fork ARM64 shim** (`emulators/gbe-fork/shim-win.nix`): compiled from upstream's `api_regular`
  description for its Windows filters; links `-static` (no `--exclude-libs`: lld's COFF driver rejects it);
  Windows resolves includes case-insensitively and the sources spell SDK headers as the SDK does
  (`DbgHelp.h`), so a shim include directory maps those spellings onto mingw's lowercase files (the
  toolchain's include dirs are symlinks — `find -H`); abseil's thread identity needs winpthreads
  (`-lpthread`); ole32/setupapi/uuid/shell32/user32/advapi32 arrive on MSVC through default libraries and
  `#pragma comment(lib)` and must be named for mingw. Its gates: COFF machine, an allowlist of Windows
  system-DLL imports (UCRT api-sets included), and an export table identical to upstream's prebuilt x64
  release (1282 names).
* **Dependency deviations**, each at its site in `win-deps.nix`: opus with intrinsics off on ARM (its
  runtime CPU detection has no Windows method and its presume-only configuration leaves the NEON kernels
  undeclared); portaudio 19.7's `cmake_minimum_required` needs `CMAKE_POLICY_VERSION_MINIMUM=3.5`; zlib
  through `win32/Makefile.gcc` for a `libz.a`; curl against mbedtls with every optional dependency named off.
* **Store-path renames are the only config change.** The golden baked-config diff across every game
  between the committed tree and this work differs solely in the per-target store names
  (`dxvk-aarch64ec-windows`, `vkd3d-proton-aarch64ec-windows`, `galaxy-stub-<target>`); the DLLs are
  byte-identical to the previous `dxvk-arm64ec`/`vkd3d-proton-arm64ec`/`galaxy-stub` outputs. The Mono
  runtime's bytes differ only by its embedded `$out` prefix and PDB signature.

## Licensing stance

The player module is downloaded by each machine from Unity's CDN under the terms a download carries
(browse-wrap; no market harm from running a legitimately bought game on another CPU). It is unfree in
the package set, `allowSubstitutes = false`, never named in `cachix.yml`, and `ci/cache-audit.sh`
asserts both. Leaked Unity source is not used in any form.

## Smoke-test method (what the tree builder automates)

Extract the module (`xar -xf`, locate `Payload`, `gzip -dc | cpio -idm`), check `strings -el
UnityPlayer.dll` for `<version> (<changeset>)`, copy the four ARM64 files over a copy of the title's
directory with `WindowsPlayer.exe` renamed to the title's exe, run under wine with `+loaddll`, confirm
every engine module maps `native` and no `libarm64ecfex.dll` appears, then watch `Player.log` for
`Initialize engine version`, `DllNotFoundException` and `BadImageFormatException`.
