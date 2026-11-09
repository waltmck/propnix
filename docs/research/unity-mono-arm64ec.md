# Unity's Mono as ARM64EC (emulators/unity-mono)

The port of the ARM64EC runtime work (docs/research/mono-arm64ec.md) to Unity's fork of Mono
(github.com/Unity-Technologies/mono), so that Unity titles with the Mono scripting backend run their
managed code natively on aarch64 instead of through FEX. Facts established at design time, then the
feasibility spike in an incremental tree.

## What UnityPlayer needs from the runtime

- UnityPlayer.dll does not import `mono-2.0-bdwgc.dll`; it loads `MonoBleedingEdge/EmbedRuntime/
  mono-2.0-bdwgc.dll` by name and resolves `mono_*` symbols with GetProcAddress. The names sit as plain
  strings in the player: 275 for KSP (Unity 2019.4.18f1), 288 for Hollow Knight (6000.0.61f1) and
  Silksong (6000.0.50f1, a custom `uum-100966` branch build), 58 of them `mono_unity_*`. Two of Hollow
  Knight's names (`mono_gc_set_heap_validate_frequency`, `mono_gc_set_heap_verifier_callback`) are absent
  from its own shipped runtime, so lookups can be optional. Compatibility rule for an EC runtime:
  exports ⊇ (names in the player ∩ exports of the game's shipped runtime).
- The player's version is a UTF-16 string in UnityPlayer.dll (`6000.0.61f1 (74a0adb02c31)`), which names
  the stream directly. The player registers icalls only through `mono_add_internal_call` (checked in
  the KSP and Hollow Knight players), never the raw no-wrapper variant.

## Upstream shape

- One branch per Unity stream: `unity-2019.4-mbe` (last commit 2022-01), `unity-2020.3-mbe`,
  `unity-2021.3-mbe` (2025-04), `unity-2022.3-mbe` (2025-06), `unity-2023.x-mbe`, `unity-6000.0-mbe`
  (2026-11) through `unity-6000.7-mbe`, `unity-main`. The stream is the unit propnix pins.
- Boehm is `external/bdwgc` (Unity-Technologies/bdwgc, with a nested `libatomic_ops` submodule). There is
  no in-tree `libgc/`. The autotools build does produce it: configure runs `AC_CONFIG_SUBDIRS(external/
  bdwgc)` when `support_boehm=yes` (the default), `mono/mini/Makefile.am.in` links
  `external/bdwgc/libgc.la` into `libmonoboehm-2.0`, which Unity's build.pl renames to
  `mono-2.0-bdwgc.dll`. configure forces sgen only for `x86_64-*-mingw` hosts ("Boehm not supported on
  64-bit Windows"); `arm64ec-w64-mingw32` is not matched. Unity's Windows runtime is otherwise an MSVC
  build (`build_win_no_cygwin.pl`, `msvc/mono.sln`).
- Unity's configure flags (build.pl): `--with-glib=embedded --disable-nls --with-mcs-docs=no
  --enable-no-threads-discovery=yes --enable-ignore-dynamic-loading=yes
  --enable-dont-register-main-static-data=yes --enable-thread-local-alloc=no --enable-unity-define=yes
  --with-unityjit=yes --with-monotouch=no` (the `--enable-*` ones are passed through to bdwgc's
  configure). `autogen.sh` runs `scripts/update_submodules.sh`, which clones every submodule including
  llvm-project; run `autoreconf` directly instead.
- Unity's tree has none of the Windows-ARM64 port the mono fork at gitlab.winehq.org received in 2026
  (MRs 176, 195, 215, 218, 229, 236, 237: ~950 added lines, mostly the ARM64 unwind-table code in
  exceptions-arm64.c). The transplant is therefore two layers: those merge requests first, then the
  ARM64EC patch (emulators/wine-mono/patches/0002) on top.

## Runtime-level differences from wine-mono

- **Boehm's register scan.** `copy_ptr_regs` in bdwgc's win32_threads.c pushes the x64 CONTEXT fields
  by name under `X86_64` (which clang's arm64ec target selects through `__x86_64__`): Rax..R15, i.e.
  x8, x0, x1, x27, fp, x25, x26, x2-x5, x19-x22. Native EC code and the EC JIT also hold live values in
  x6, x7, x9-x12, x15-x17 and lr, which the ARM64EC context stores in the floating-point save area
  (`X6`, `X7`, `X9`..`X12`, `X15`, `Lr`, and `X16_0..3`/`X17_0..3` as four WORDs each). A pointer held
  only in one of those at the moment of suspension would be missed and its object freed. Fix: an
  `__arm64ec__` branch that copies all 25 (PUSHED_REGS_COUNT 25) through `ARM64EC_NT_CONTEXT`, which
  llvm-mingw's winnt.h declares for the arm64ec target.
- **Icalls.** Unity's player uses `mono_add_internal_call` only, so every icall is reached through
  `mono_marshal_get_native_wrapper`, whose native call has a pinvoke signature and an absolute target:
  the existing JIT hook (`signature->pinvoke && MONO_PATCH_INFO_ABS && !RtlIsEcCode(target)`) covers
  it. The no-wrapper path (`MONO_ICALL_FLAGS_NO_WRAPPER`, where `mono_jit_compile_method` hands out the
  raw C address as the "compiled method") is not exercised by UnityPlayer; `direct_icalls_enabled` is
  false for the JIT.
- **Suspension.** Boehm stops the world with SuspendThread + GetThreadContext, so a thread in x64 code
  is suspended at FEX's next doorbell poll: this depends on emulators/fex/patches/0003.

## Spike log (incremental tree /var/lib/games/unity-mono)

- 2026-11-08: shallow clone of `unity-2022.3-mbe` (b8eb56fa, bdwgc 8167f75). The seven mono-fork
  merge requests apply with offsets only; the ARM64EC patch then applies except its UWOP_ALLOC_L hunk,
  which collides with MR 236's version of the same fix. **MR 236 is right and the shipped patch was
  wrong**: the ARM64 `alloc_l` unwind code is four bytes (`E0` + a 24-bit count, `0xe0000000 | x`,
  `push_unwind_op4`); the patch emitted a three-byte form (`0xe00000 | x`). Nothing had unwound through
  a >512 KiB frame, so it never showed. Corrected in emulators/wine-mono/patches/0002 to MR 236's form;
  the hunk is to be dropped on the next wine-mono bump, which carries MR 236 itself. configure.ac gets
  the WIN32_CPPFLAGS API-level case and the `aarch64-*mingw*|arm64ec-*mingw*` TARGET case; the
  Boehm register scan is added to `external/bdwgc/win32_threads.c`.
- First build of the configured tree (`--host=arm64ec-w64-mingw32`, Unity's flags, Boehm on; configure
  reports "Included Boehm GC with typed GC and parallel mark", shared libraries, JIT): four distinct
  failures. (1) bdwgc's bundled libatomic_ops selects its x86 inline-assembly backend from `__x86_64__`
  (`invalid output constraint '=q'`); mono never includes libatomic_ops itself, so the arm64ec host passes
  `--with-libatomic-ops=none` to the bdwgc sub-configure (compiler intrinsics, `GC_BUILTIN_ATOMIC`)
  instead of `no` (bundled). (2) Two Unity sources include Windows headers with MSVC capitalisation
  (`<Windows.h>` in mono-log-common.c, `"Evntcons.h"` in etw-profiler.c); mingw ships them lowercase.
  (3) Unity's mini Makefile has no `built_sources` convenience target (a wine-mono addition); the
  generated headers are `version.h` and `cpu-arm64.h`, built explicitly before the library. (4) Unity's
  `autogen.sh` must not be used (submodule cloning); `autoreconf -i` suffices, bdwgc has its own.
  bdwgc's gcconfig classifies the target correctly once mingw's `_mingw.h` is in (it defines `_M_X64`,
  `_M_AMD64` and `_M_ARM64EC` for arm64ec): X86_64, MSWIN32, 64-bit.
- Further build fixes: Unity's `mixed_callstack_plugin.c` forward-declares a function `static` that its
  header declares extern (clang errors); `boehm-gc.c` passes `void *(MonoDomain *)` as `GC_fn_type` and
  `MonoObject **` as `void **` (clang 22 errors on both; `-Wno-error=incompatible-function-pointer-types
  -Wno-error=incompatible-pointer-types` for the build, the Unity code is MSVC-era); the ETW profiler's
  message-compiler header defines its helpers `__inline` and `DECLSPEC_NOINLINE __inline`, which under C99
  emit no symbol — both macros are made `static` before the first declaration in etw-profiler.c; `oop.c`
  (out-of-process debugging, holds `mono_unity_{lock,unlock}_dynamic_function_access_tables64`, which the
  player resolves) is MSVC-only in Unity's Makefiles and joins `win32_sources`, its `_M_X64` bodies
  taking their fallback on arm64ec (mingw defines `_M_X64` there too); the mingw host case gets
  `COREARCH=arm64` so the Windows-ARM64 port's `-lntdll` applies, plus `-luuid` for the ETW `GUID_NULL`;
  `culture` and `sgen` join the build order. Maintainer mode is off, so a Makefile.am change needs
  `autoreconf` by hand. Result: `libmonoboehm-2.0.dll`, ARM64EC with CHPE metadata, 26 MB unstripped,
  5675 exports (the MSVC build exports 1237: ours exports every MONO_API symbol), all 296 names REPO's
  player needs present.
- First launch (REPO 2022.3.67f2, the DLL as an `extraLowers` store layer above the payload — a file
  bind inside the payload makes overlayfs refuse the game-dir lower with EINVAL): the runtime loads,
  managed code runs (`ClassLibraryInitializer.Init` → `System.Console..cctor` → `Encoding.GetEncoding`),
  then EXCEPTION_ILLEGAL_INSTRUCTION at ntdll's `__chkstk` export. Cause: the mono fork's MR 237 makes
  the JIT prolog call `GetProcAddress(ntdll, "__chkstk")` for frames over 4 KiB; in an ARM64EC process
  that export is the x64 fast-forward stub, and a raw `blr` executes x64 bytes as ARM64 code. EC code
  must use `__chkstk_arm64ec` (an EC-only export, same `x15 = size / 16` convention); under wine both
  helpers are a bare `ret` ("we shouldn't need that": wine commits thread stacks). The JIT now resolves
  `__chkstk_arm64ec` on ARM64EC and skips the probe unless the address is EC code. After the crash,
  Mono's native crash reporter printed the managed stack and the main thread spun at 100 % instead of
  exiting — the same crash-handler hang the Space Engineers work left open.
- With the probe routed to `__chkstk_arm64ec`: REPO loads the ARM64EC runtime, runs its managed startup,
  takes a managed null-reference fault as a hardware access violation that Mono's vectored handler turns
  into a managed exception (continue-execution), then loads dbghelp, XInput and the Steam API shim and
  proceeds to the game. The runtime is `extraLowers`-shadowed over the payload (`/var/lib/games/
  unity-mono/repo-ec.nix`, built with `--impure` from the incremental tree's DLL).
- Which titles the 2022.3-stream build serves, by the compatibility rule (names the player resolves ∩
  exports of its shipped runtime): REPO 2022.3.67f2 (296 names), Hollow Knight 6000.0.61f1 (286) and
  Silksong 6000.0.50f1 (286) — nothing missing, so one build covers the 2022.3 and 6000.0 streams. KSP
  2019.4.18f1 (275) and Iron Lung 2021.1.15f1 (280) each miss the same 8 (`mono_custom_attrs_construct_
  by_type`, `mono_method_signature_checked`, `mono_unity_capture_memory_snapshot`, `mono_unity_free_
  captured_memory_snapshot`, `mono_unity_liveness_calculation_begin`, …): the older API family, which
  needs the 2019.4/2021.3 stream build. Baby Steps, Papers Please, Rust and Iron Nest are IL2CPP (no
  mono runtime shipped) and are not affected. Silksong's package still uses a file mask, which does not
  compose with an extra lower (see the `maskFiles` docs), so it is not a test candidate yet.
- Hollow Knight (GOG Windows build, player 6000.0.61f1) on the 2022.3-stream runtime: the runtime loads
  and the player resolves every name, then an unhandled access violation in UnityPlayer's own x64 code
  (`UnityPlayer.dll+0x74beed`, reading through rax = 0x2326 with r9 pointing into the runtime's data;
  Mono's vectored handler declines it, the exe's SEH handler passes). The 43 `mono_unity_*` functions
  the player uses that could be matched have identical prototypes in both streams, so the exported API
  is not what differs: the player is reading runtime-internal data (a struct it peeks into, or a value
  whose meaning changed) in the 6000.0 layout. The export rule is necessary, not sufficient — the
  runtime must come from the player's own stream. (The default `games.hollow-knight` on aarch64 is the
  Steam Linux build under box64, which cannot use a Windows runtime at all; the test used
  `.apply { emulatedPlatform = "x86_64-windows"; }`, the GOG Windows payload already in the store.)
- `unity-6000.0-mbe` (e3f5e86f, bdwgc 1113fef) is a different base from 2022.3: Unity 6 carries its
  own Windows-ARM64 port — unwind-info generation (`mono_arch_unwindinfo_init_method_unwind_info_ex`,
  registration through `RtlAddGrowableFunctionTable` in mini-windows.c), a `__chkstk` JIT icall
  (`mono_chkstk_win64`, `G_BEGIN_DECLS void __chkstk (void)` — the same x64-stub hazard under ARM64EC),
  the high-to-low localloc zeroing, Windows context code in mono-context.c and `TARGET_ARM64` paths in
  mini-windows.c — but not wine's unwind tables (MR 215), ALLOC_L (MR 236) or the `aarch64-*mingw*`
  configure case. Wine's merge requests must therefore NOT be layered on it (a fuzz-3 application
  mangled `mono_arch_handle_exception`); the 6000.0 family is Unity's port plus the ARM64EC layer
  adapted to it. Its `oop.c` is already in `win32_sources` and guards the x64 tables with `_WIN64`,
  which arm64ec also defines. Note for patch generation: this git config uses `i/`/`w/` diff prefixes;
  repo patches must be produced with `a/`/`b/`.
- Unity 6 build mechanics: `mono/mini/Makefile.am` is a plain copy of `Makefile.am.in` that Unity's
  autogen.sh makes before autoreconf (its line 131); without it automake aborts on a missing
  `mono/mini/Makefile.in`, and an aborted autoreconf leaves `configure` newer than `configure.ac`, which
  a timestamp-driven regeneration then skips. `configure` itself runs `scripts/update_submodules.sh`
  (configure.ac line 7047): it cloned llvm-project, corefx, roslyn-binaries and more (943 MB) into
  `external/`; the packaged build (each stream's build-with-llvm-mingw patch) drops that invocation and
  assembles `external/bdwgc` with its `libatomic_ops` from pinned sources.
- The ARM64EC layer on Unity 6 (patch 0002 applied directly, no wine merge requests): the JIT hunks
  (mini-arm64.c, mini.c, mini-codegen.c, cpu-arm64.md, mono-context.h) apply unchanged; five sites are
  adapted to Unity's own port — `UCONTEXT_REG_{PC,SP,R0}` in mono-sigcontext.h read the ARM64EC layout
  (no contiguous `X[]`, so `UCONTEXT_GREGS` stays undefined there), `mono_monoctx_to_sigctx` gets the EC
  branch, mini-windows.c's thread-context read goes through `MONO_WIN32_CONTEXT_PC`, and the code-manager
  and valgrind `__x86_64__` guards exclude `__arm64ec__`; wine's ALLOC_L hunks are dropped because
  Unity's unwind generator has `mono_arch_unwind_add_alloc_l`. Unity 6's `mono_chkstk_win64` JIT icall
  is registered with `&__chkstk`, the x64 fast-forward stub under ARM64EC; it now resolves
  `__chkstk_arm64ec`, checks it is EC code, and otherwise registers a no-op.
- Unity 6's unwind code reads the ARM64 entry's packed bit-fields, which exposed that mingw's
  `RUNTIME_FUNCTION` for arm64ec is the AMD64 layout while wine's EC unwinder reads growable tables as
  ARM64 entries (docs/research/mono-arm64ec.md, 2026-11-08). Both trees and the shipped patch 0002 now
  map the type to `ARM64_RUNTIME_FUNCTION` under `__arm64ec__`; Unity 6 gets it in mono-sigcontext.h's
  Windows block (its mini-arm64.h does not include windows.h itself), with the registration going
  through Unity's function-pointer typedefs unchanged. Also gated: Unity 6's MSVC-only
  `MONO_INIT_CONTEXT_FROM_FUNC` (`_AddressOfReturnAddress`) on `_MSC_VER`, so clang takes the
  `__builtin_frame_address` form.
- Unity 6 runtime built (`build-6000`): ARM64EC with CHPE metadata, 26 MB unstripped, 5672 exports,
  all 286 names Hollow Knight's player resolves present. Beyond the adaptations above it needed only:
  `oop.c` added to `win32_sources` (not in Unity 6's Makefile.am either), the ARM64 Windows
  `MONO_CONTEXT_GET_CURRENT` gated on `!__GNUC__` (its implementation is `winarm64.asm`, MSVC armasm
  syntax, so clang takes the inline-assembly form), and `mono/mini/Makefile.am` regenerated from
  `Makefile.am.in` before every autoreconf.
- Hollow Knight (GOG Windows build, player 6000.0.61f1) on the Unity 6 ARM64EC runtime: loads and plays
  in-world (user-verified, 2026-11-08). The trace shows no access violation at all — the only
  exceptions are wine's RPC_S_SERVER_UNAVAILABLE noise. So the 6000.0 stream needs no wine merge
  requests: Unity's own Windows-ARM64 port plus the ARM64EC layer adapted as above is the whole patch
  family for Unity 6, and the stream-as-unit rule is confirmed from both sides (2022.3 build runs REPO,
  6000.0 build runs Hollow Knight, neither runs the other's title).

## Packaging (emulators/unity-mono)

- One derivation per stream (`unityMono.streams."2022.3"`, `"6000.0"`; `.#unityMono` links both and is
  the cachix job), each pinning Unity's `unity-<stream>-mbe` branch head, its `external/bdwgc` gitlink
  and bdwgc's `libatomic_ops` gitlink as `fetchFromGitHub` sources assembled into one tree. The product
  is `mono-2.0-bdwgc.dll` (stripped, ARM64EC-checked) plus its export list.
- The patch families are the incremental trees' deltas, generated with `a/`/`b/` prefixes. 2022.3:
  wine-mono's seven merge requests verbatim (0001-0007, each header naming the MR, its author and
  merge date), then the build fixes (0008) and the ARM64EC layer (0009: the remainder of the tree over
  the MR layer, which the worktree `wt-2022` holds as a commit). 6000.0: the build fixes (0001) and the
  ARM64EC layer adapted onto Unity's own port (0002). The bdwgc patch is shared (`patches/bdwgc`): the
  two revisions' `win32_threads.c` take the same hunks.
- The configure-time `scripts/update_submodules.sh` call is removed by each stream's build-fix patch;
  `autogen.sh` is not run (it clones every submodule), `AUTOPOINT=true autoreconf -i` after copying
  `mono/mini/Makefile.am.in` to `Makefile.am` replaces it, and autoreconf descends into
  `external/bdwgc` and its `libatomic_ops` (the latter present only for that descent; the collector is
  built on the compiler's atomics).
- Game side: `unity.mono.stream` (lib/modules/unity-mono.nix) puts the stream's DLL over the payload as
  an `extraLowers` tree (lib/builders/unity-mono-tree.nix) on aarch64 wine backends only. The tree's
  derivation reads the payload: the player's version string must begin with the declared stream, and
  every `mono_*` name the player carries that the shipped runtime exports must be in the ARM64EC
  runtime's export list (`winedump -j export` reads the shipped x64 runtime; the EC list comes from the
  runtime derivation). `unity.mono.enable = false` is the A/B switch back to the shipped runtime.
- Declared: Hollow Knight (`6000.0`; the Windows combos only, the default Linux combo under box64 is
  untouched), Silksong (`6000.0`; its GalaxyCSharpGlue whiteouts are gone, since a multi-lower game dir
  cannot take one — docs/research/silksong-galaxy-and-boot.md) and R.E.P.O. (`2022.3`). All three run on
  the packaged builds: Hollow Knight (GOG Windows, player 6000.0.61f1, 286 entry points) plays in-world,
  Silksong (6000.0.50f1, 286) boots, and R.E.P.O. (2022.3.67f2, 296) reaches its menu, each with the
  store build byte-identical to the DLL mounted in the game dir. KSP (2019.4.18f1) waits on the older
  stream.
- The packaged DLLs export the MONO_API surface (5295 and 5293 names); the incremental trees' DLLs
  additionally export 380 `GC_*` names, which no shipped runtime exports and no player binds.

