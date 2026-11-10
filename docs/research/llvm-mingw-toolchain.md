# The llvm-mingw toolchain (ARM64EC)

On aarch64, the Windows code propnix compiles (wine, FEX's emulator DLLs, native-EC DXVK and
vkd3d-proton, the ARM64EC Mono runtimes, galaxy-stub) builds with one llvm-mingw toolchain, exposed
as `llvmMingw` in the aarch64 scope. It is mstorsjo's llvm-mingw 20260616 release (clang 22.1.8,
llvm-project ca7933e47d3a, the last stable release before the 23.x line) with a clang built from the
same commit plus one backported codegen fix grafted on. This document records why the toolchain is
22 with a backport rather than the 23 release that carries the fix, and the compiler-rt
archive-index facts that the toolchain and galaxy-stub guard against. x86_64 hosts have no
llvm-mingw at all: galaxy-stub and the x86_64 Mono runtime use nixpkgs' cross-mingw GCC there.

## Two pieces

- `llvmMingwPrebuilt` (emulators/llvm-mingw): the 20260616 aarch64-Linux-hosted release tarball,
  autoPatchelf'd, not stripped, with its ARM64EC builtins archives reindexed where needed (below).
  Nothing consumes it directly.
- `llvmMingwPatched` (emulators/llvm-mingw/patched-22.nix): the prebuilt tree with `bin/clang` (and
  lld, and the libLLVM they link) replaced by a build of the same llvm commit with
  llvm/llvm-project#190933 applied, rebased onto 22.1.8 and applied with `--fuzz=0`. That patch is
  the ARM64EC variadic exit-thunk fix: without it every `[out]` context handle is corrupted, so no
  Windows installer can register a service and the GOG Galaxy SDK's RPC init faults
  (preliminaries/RESEARCH.md §23). The graft works because `bin/<triple>-w64-mingw32-clang` is a
  symlink to `clang-target-wrapper.sh`, which execs a sibling `clang`.

`llvmMingw = llvmMingwPatched`, and every consumer in the scope resolves `llvmMingw`, so nothing can
build against the unpatched base. Only the compiler is rebuilt: the mingw-w64 sysroots, libc++ 22
and the compiler-rt builtins stay exactly as upstream shipped them. The patch touches only
`llvm/lib/Target/AArch64/{AArch64Arm64ECCallLowering,AArch64ISelLowering}.cpp` and no public
headers; clang and lld are rebuilt with it because grafting a libstdc++-built libLLVM under the
prebuilt libclang-cpp would mix two C++ ABIs.

The patched exit thunk emits `#__chkstk_arm64ec`, so wine itself, not only DXVK and vkd3d, depends
on an intact symbol index in the ARM64EC builtins archive.

## Why 22, not 23

The fix landed in llvm main, so the only released toolchain that carries it is llvm-mingw 20260812,
clang 23.1.0-rc3. Pinning it was implemented, measured and rejected:

- libc++ 23 drops a batch of transitive includes, which breaks pinned third-party sources one file
  at a time and needs a patch per source: DXVK, vkd3d-proton's dxil-spirv, and two files in FEX's
  CRT.
- It hard-blocks fex-dlls outright. libc++ 23's `locale_win32.cpp` calls kernel32's
  `GetACP`/`GetLocaleInfoEx`, while `libarm64ecfex.dll` is freestanding because wine's ntdll loads
  it before kernel32 exists.

That is an open-ended patch treadmill against a release candidate, in exchange for one two-file
codegen fix. The backport onto the stable 22.1.8 gives one toolchain, no third-party patches and no
skew; its build is a one-time cost that lives in the store.

## compiler-rt archive indexes

### ARM64EC builtins: duplicate member names (20260616)

Up to and including 20260616, `lib/clang/*/lib/windows/libclang_rt.builtins-{aarch64,x86_64}.a` list
their ARM64 and ARM64EC objects under the same member name. `llvm-ar`/`llvm-ranlib` then build a
symbol index that drops the ARM64EC (`#`-mangled) symbols, notably `#__chkstk_arm64ec`, and x86_64's
`___chkstk_ms`, so lld fails with `undefined symbol: #__chkstk_arm64ec` when linking any EC C/C++
DLL (DXVK, vkd3d, galaxy-stub). meson surfaces it as "library 'd3d9' not found", because
`find_library` is a link test.

The toolchain's `postFixup` repairs this with `reindex-ar.py`: extract every member under a unique
name, then re-archive with `llvm-ar rcs`, which produces an index that keeps the EC symbols. It runs
only on an archive whose full member names (`llvm-ar t | sort | uniq -d`) contain duplicates, and
logs that it skipped otherwise.

### 20260812 onward: disambiguation by path

20260812 fixes the layout upstream by giving the EC objects a distinct path instead of a duplicate
name: `chkstk.S.obj` and `obj.arm64ec/chkstk.S.obj`. Nothing collides and the index keeps
`#__chkstk_arm64ec` as shipped. Re-archiving such an archive is worse than useless: flattening
`obj.arm64ec/chkstk.S.obj` to an indexed basename (`0001_chkstk.S.obj`) loses whatever lld keys EC
resolution on, and every arm64ec link fails on `#__chkstk_arm64ec` again. That is why every reindex
is gated on actual duplicate names rather than run unconditionally, and why duplicates are counted
on full member names, never basenames.

`strip` does the same damage. nixpkgs' fixupPhase strips before `postFixup`, and `strip` on a static
archive rewrites it while flattening member names to basenames: on a path-disambiguated archive that
collapses all 290 EC members onto their ARM64 namesakes and recreates the collision. The toolchain
is built with `dontStrip = true`, which also keeps the duplicate-name detection above honest;
nixpkgs' own llvm-mingw sets it for the same reason, and the raw tarball links fine.

### i386 builtins and galaxy-stub

galaxy-stub's 32-bit `Galaxy.dll` links against the i386 builtins, `libclang_rt.builtins-i386.a`,
which the toolchain's own `postFixup` does not touch. If that archive carried duplicate member
names, its index would drop `__alloca` and `___chkstk_ms`, and since the 32-bit CRT's
pseudo-relocator references `__alloca`, a plain i686 link would fail with
`undefined symbol: __alloca`. Measured on 20260616 and 20260812 alike: the i386 archive is clean,
150 members, zero duplicate names, `__alloca` in the armap, and a plain i686 link succeeds.

galaxy-stub keeps a gated guard for it, contained in that derivation: if `llvm-ar t` on the i386
archive shows duplicate names, it reindexes a private copy with the toolchain's own `reindex-ar.py`
and links it inside `-Wl,--start-group … --end-group`, without rebuilding llvm-mingw. On the pinned
release the guard logs that the index is upstream-correct and links without it. The guard stays
gated for the same reason as the toolchain's: re-archiving a path-disambiguated archive destroys EC
symbol resolution. On x86_64 the stub builds with nixpkgs' mingw32 GCC, which has no such archive.
