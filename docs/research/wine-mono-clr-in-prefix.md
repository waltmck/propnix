# The .NET CLR in the wine prefix

A managed (pure .NET) Windows exe carries a CLR header and, for a modern C# build, no import table
at all: there is no machine code for wine's loader to enter, so it hands the image to `mscoree.dll`,
which must find a runtime to host. Without one the process dies at start, with no window and no
frame. The wine package ships no runtime (`${wine}/share/wine/` holds only fonts, nls, `wine.inf`
and winmd, no `mono`), so propnix installs Wine Mono (emulators/wine-mono) into the read-only system
tree (emulators/wine-prefix-lower.nix) at `C:\windows\mono\mono-2.0`. This document records how
mscoree finds it, why it goes in after `wineboot -u`, which registry facts are declared and which
are left out, and what the `mscoree` DLL override does and does not do.

Unity Mono titles (KSP, Iron Lung, Hollow Knight) carry their own runtime in the payload and do not
use the prefix CLR. Kerbal Space Program is the precedent for that other managed shape: Unity's
bundled Mono needs no prefix runtime, only a writable, non-overlay `Managed` dir.

## Space Engineers, the reference managed title

`Bin64/SpaceEngineers.exe` is a pure managed assembly: two sections (`.text` + `.rsrc`), no import
table, `file` reports "Mono/.Net assembly", and its CLR header names runtime v4.0.30319. The sidecar
`SpaceEngineers.exe.config` pins

    <supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.6.1"/>

Wine Mono is pinned at 11.2.0, the `WINE_MONO_VERSION` the pinned wine 11.15 hardcodes
(`dlls/mscoree/mscoree_private.h`). The built prefix was verified by compiling and running a managed
exe under it (`Environment.Version` = 4.0.30319.42000). The game's own log then opens with

    Environment.Version: Mono 6.13.0 (tarball)
    Environment.CommandLine: C:\game\Bin64\SpaceEngineers.exe

so managed `Main` executes.

## How mscoree finds the runtime

`dlls/mscoree/metahost.c: get_mono_path()` tries, in order:

1. `C:\windows\mono\mono-2.0` (`get_mono_path_local`);
2. `HKCU\Software\Wine\Mono\RuntimePath` (`get_mono_path_registry`);
3. the wine datadir, `INSTALL_DATADIR/wine/mono`, `/usr/share/wine/mono` and `/opt/wine/mono`, each
   looking for a `wine-mono-<WINE_MONO_VERSION>` subdirectory.

The first is the only one that needs neither a registry value nor a path inside the wine package,
and being first it wins outright, so nothing later can shadow it. mscoree derives Mono's own roots
from whatever path it found (`mono_lib_path = <path>\lib`, `mono_etc_path = <path>\etc`, fed to
`mono_set_dirs`), so the wine-mono store path has to be the runtime root itself, and the tree links
it in verbatim: `drive_c/windows/mono/mono-2.0` is a symlink to the wine-mono store path.

`find_mono_dll()` then probes `<path>\bin\libmono-2.0-<arch>.dll`, with `<arch>` taken from the arch
mscoree itself was built for: `-x86` for i386, `-x86_64` for x86_64 and for ARM64EC (wine's
`include/winnt.h` establishes that an arm64ec compile defines `__x86_64__`; an x86_64 guest on
aarch64 is arm64ec). The prefix build fails if either `libmono-2.0-x86.dll` or
`libmono-2.0-x86_64.dll` is not readable at that path. On aarch64 the `-x86_64` slot holds an
ARM64EC build of the runtime (emulators/wine-mono; mono-arm64ec.md).

The symlink keeps the runtime a separate closure entry: the system tree's NAR does not grow by the
runtime's 219 MiB, and a Mono bump does not re-push the prefix. It also keeps the launcher's
start-up prefetch walk small, because propnix-prefetch never descends through a symlink to a
directory: the walk (`warm(&[view], &["dll","drv","exe"])`, run for every wine title) covers the
tree's 1 557 PE modules and not Mono's 2 676 managed `.dll`/`.exe` files (2 790 files in all).

## Why Mono goes in after `wineboot -u`

`wine.inf`'s RegisterDlls step registers `mscoree.dll`, and `mscoree_main.c: DllRegisterServer` →
`install_wine_mono()` goes on, if it finds a runtime, to
`MsiInstallProductW(<mono>\support\winemono-support.msi)`, the package that adds the .NET fake DLLs
and the NDP registry tree. Letting that run inside the prefix build is wrong on two counts:

- Arch asymmetry. wineboot is native (x86_64 on an x86_64 host, arm64 on aarch64), and the arm64
  mscoree asks `find_mono_dll` for `libmono-2.0-arm64.dll`, which wine-mono 11.2.0 does not ship in
  any form (the release directory holds only `-x86.msi`, `-x86.tar.xz`, `-src`, `-dbgsym` and
  `-tests`). The support package would install on x86_64 and not on aarch64: two different system
  trees from one expression.
- Emulation and state in the sandbox. The support MSI's INSTALLFAKEDLLS custom actions shell out to
  `installinf-x86.exe` / `installinf-x86_64.exe`, which are x86 PEs: on aarch64 that is FEX JIT work
  inside the Nix build sandbox, which the prefix build otherwise avoids entirely (wineboot runs no
  x86 code). It also bakes MSI install state, a wall-clock `InstallDate` and a
  `C:\windows\Installer\` package cache, into a tree that is bit-reproducible by contract.

With Mono placed after wineboot, `install_wine_mono()` finds no runtime and falls through to
`invoke_appwiz()`, which is harmless in the headless sandbox. The registry facts the support package
would write are declared instead, deterministically and identically on both arches.

## Declared registry facts

The .NET Framework 4.x version-detection keys are transcribed from the Registry table of the support
package (`msiinfo export winemono-support.msi Registry`, the NDP4*/DotNetFrameworkPolicy40 rows,
byte-identical between its 32- and 64-bit components): `.NETFramework\policy\v4.0` and
`NET Framework Setup\NDP\v4\{Client,Full,Full\1033}` with `Release` = 0x82348 (533320) and `Version`
= 4.7.03190. `Release >= 394254` is the documented ".NET 4.6.1 or later" test, which is what a
`.NETFramework,Version=v4.6.1` target such as Space Engineers probes. They are written into both
registry views, because HKLM\Software is WoW64-redirected and a 32-bit process reads Wow6432Node.
They are not the CLR discovery path (`get_mono_path_local` needs no registry), and they are scoped
to v4: the support package also claims v1.1/v2.0/v3.0/v3.5, which no packaged title targets. All of
it goes in with one `wine reg import` rather than 28 `reg add` round-trips against wineserver.

`Software\Microsoft\.NETFramework\InstallRoot` is deliberately not written. Upstream points it at
`C:\windows\Microsoft.NET\Framework{,64}\`, a tree only the support package's cab populates, and
`mscoree_main.c: LoadLibraryShim()` shows why an empty root would be worse than none: with a root it
loads `<root>\<version>\<dll>` and nothing else (an empty directory is a guaranteed E_HANDLE), while
without one it falls back to a bare `LoadLibraryW(<dll>)` down the normal search path. Measured:
leaving it unset costs one cosmetic
`err:mscoree:LoadLibraryShim error reading registry key for installroot`, and Roslyn's `csc.exe`
runs to completion under the prefix.

## The `mscoree` DLL override

The wine defaults set `dllOverrides.mscoree = "b"`, and the prefix build exports the same
`WINEDLLOVERRIDES="mscoree=b;mshtml=;winemenubuilder.exe=d"` so the tree is initialized as it is
used. With a runtime in the prefix the entry is load-bearing:

- `b` is not a choice between implementations. The builtin is the only mscoree that exists: wine
  builds it into `lib/wine/*/mscoree.dll`, and Wine Mono installs no native mscoree anywhere (its
  payload is `bin/libmono-2.0-x86{,_64}.dll` plus managed assemblies). `n` would find nothing to
  load and `""` would disable .NET outright, so every managed title depends on `b`.
- It does not govern the wine-mono install prompt. That prompt is mscoree's `DllRegisterServer` →
  `install_wine_mono()` → `invoke_appwiz()`, reached only when `wine.inf`'s RegisterDlls step
  registers mscoree during `wineboot -u`. propnix runs wineboot once, at prefix build time, and
  never at runtime (`.update-timestamp` = `disable`). With a CLR present, `get_mono_path()` succeeds
  anyway.

`prefixLower.override { wineMono = null; }` builds a tree with no CLR (saving about 219 MiB); every
managed title then dies at process start, before its first instruction.
