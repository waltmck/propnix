# Research: an ARM64EC Mono runtime for x64 managed titles under Hangover

Status: proof of concept in progress. Nothing here is a decision; nothing here is packaged. Work
happens in incremental build trees under /var/lib/games/mono-ec, never in Nix, until a patch is
ready to package.

## Why

Every managed title runs its Mono runtime as x64 code under FEX: wine-mono's
`libmono-2.0-x86_64.dll` (Space Engineers) and Unity's `mono-2.0-bdwgc.dll` (Hollow Knight,
Silksong, Iron Lung, KSP, REPO). The JIT emits x64 that FEX re-translates, and the JIT's
self-modifying-code pattern is what FEX's 4 KiB-granular tracking handles worst on a 16 KiB host.
A runtime built as ARM64EC would JIT straight to ARM64 and remove that layer for all managed code.

## The shape of the work (from reading, not yet from doing)

Who calls JITted code: other JITted code; the runtime's C code, only ever through JIT-generated
"runtime invoke" wrappers and trampolines; and x64 code outside mono, only through
"native-to-managed" wrappers (delegates as function pointers, reverse p/invoke). Outward, JIT code
calls runtime helpers, internal calls, and p/invoke targets (wine's EC DLLs, or the game's x64 DLLs).

So managed-to-managed code can stay plain ARM64 — the existing Windows-ARM64 backend as it is —
and EC lives at the boundaries:

- register reservations everywhere (x13, x14, x23, x24, x28, v16–v31 have no slot in the EC
  context, so a GC suspend or an exception resume would lose them);
- JIT pages registered in the EC bitmap (`peb->EcCodeBitMap`, wine `RtlIsEcCode`): clang-compiled
  runtime code checks every indirect call against it, FEX decides native-vs-emulated by it. Wine's
  `NtAllocateVirtualMemoryEx` already honours `MEM_EXTENDED_PARAMETER_EC_CODE` (unix/virtual.c), so no
  wine change: mono's code manager must allocate JIT memory through `VirtualAlloc2` with that attribute
  instead of `HeapCreate(HEAP_CREATE_ENABLE_EXECUTE)` / plain `VirtualAlloc` (mono-codeman.c,
  mono-mmap-windows.c);
- ARM64 unwind info for JIT frames (the ARM64-Windows port's Win32 unwind support, reused);
- the EC convention (x64's: four integer argument registers, 32-byte shadow space, x64 struct rules)
  for p/invoke-style signatures — runtime-invoke wrappers, native-to-managed wrappers, trampolines;
- outbound to x64: exit thunk per signature + the indirect-call check, resolved at JIT time where
  the target is known (wine's DLLs are EC → direct `bl`);
- inbound from x64: an entry thunk per native-to-managed wrapper, at the fixed offset before it.

## Sources

- wine-mono 11.3.0 (2026-08-17): adds a native ARM64-Windows Mono port and builds its native
  support libraries (SDL3, FAudio, FNA3D, FNAMF, monodx, WPF natives, btls) as arm64ec; `mono.make`
  fills the arm64ec runtime slot with the x86_64 build on purpose. The mono fork
  (gitlab.winehq.org/mono/mono, branch wine-mono) landed the ARM64-Windows port Jan–Jun 2026
  (MRs 176, 195, 215, 218, 229, 236, 237). wine-mono 11.2.0 (2026-06-17), the version the originally pinned
  Hangover compiles in, predates the last two merges; the PoC uses 11.3.0's source and class
  libraries together.
- Unity's fork (github.com/Unity-Technologies/mono): same mono 6.13.0 base; `mini-arm64.c` differs
  from wine's fork by 245 lines (2022.3), 421 (Unity 6), ~1,200 (2019.4, 2021.1); no Windows-ARM64
  or ARM64EC work at all; Boehm GC, and 148 Unity-only exports (82 `mono_unity_*`) that UnityPlayer
  needs. The EC work transplants as patches; wine-mono's runtime cannot be substituted.
- Toolchain: the repo's llvm-mingw 20260616 (`arm64ec-w64-mingw32-clang`, clang 22) predefines
  `__arm64ec__`, `__x86_64__`, `__amd64__` and NOT `__aarch64__`. Mono selects architectures both
  through configure (`TARGET_ARM64`/`HOST_ARM64`) and through compiler macros in headers, so every
  `__x86_64__` conditional that means "x86 machine code" must exclude `__arm64ec__`.
- Upstream policy: Wine's Clean Room Guidelines and the mono fork's README forbid LLM-generated
  code contributions. This work stays downstream; findings can go upstream as prose only.

## Harness

- Incremental x86_64 runtime recipe from the delegate-patch work: /var/lib/games/wine-mono-build
  (`configure-runtime.sh`, `rebuild.sh`), image /var/lib/games/wine-mono-hybrid, Hangover 11.15 prefix
  /var/lib/games/mono-test-prefix with `C:\windows\mono\mono-2.0 → wine-mono-hybrid`.
- EC work: /var/lib/games/mono-ec/{dl,src,build-arm64ec,image,prefix}.

## Log

(appended as the work proceeds)

### 2026-11-07 — step 1 begun: the runtime's C half as ARM64EC

- Source: the on-disk wine-mono 11.2.0 tree (`/var/lib/games/wine-mono-src/wine-mono-11.2.0/mono`),
  which already carries the delegate patch and, it turns out, the ARM64-Windows port bar two late
  merges (its `mini-arm64.c` is 35 lines from the fork's head; `exceptions-arm64.c` has the Win32
  unwind support). The 11.3.0 download was abandoned at 20 KB/s. Diff baseline:
  `/var/lib/games/mono-ec/pristine` (snapshot of `mono/` + `configure.ac` before any EC edit).
- Harness proven first: `/var/lib/games/mono-test-prefix` (Hangover 11.15) runs `mcs.exe` and a
  managed hello world on the x64 runtime under FEX. Baseline: fib(32) JIT-compiled = 26 ms.
- Configure trick (`/var/lib/games/mono-ec/configure-arm64ec.sh`): `--host=aarch64-w64-mingw32` so
  configure.ac's `aarch64-*mingw*` case selects TARGET_ARM64/HOST_ARM64, with
  `CC=arm64ec-w64-mingw32-clang` (llvm-mingw 20260616) so the code is ARM64EC. `--enable-nls=no`
  (no gettext on the host). Shared-library build confirmed.
- The macro shortcut (`-U__x86_64__`) is impossible: mingw's winnt.h requires `__x86_64__` under
  arm64ec (its PROBE_ALIGNMENT chain). So x64-only sites get `!defined(__arm64ec__)` guards. Census:
  only 20 `__x86_64__` sites in 14 runtime files; five needed guards —
  `mini-codegen.c` (an x86 `bsfq` asm), `mono-memory-model.h` (would have assumed x86 TSO ordering on
  ARM64 hardware — silent), `mono-context.h`/`.c` (the x64 MonoContext comes BEFORE the ARM64 one in
  an `#elif` chain, so without the guard x64 wins — silent), `mono-codeman.c` (the 32-bit mmap flag
  and the x86 `0xcc` fill byte). The memory-model chain has no ARM64 branch; the generic
  full-barrier fallback is the correct one.
- Build: `/var/lib/games/mono-ec/rebuild-arm64ec.sh [--image]`; image = upstream 11.2.0 tree with
  the EC DLL as `bin/libmono-2.0-x86_64.dll`; test prefix `/var/lib/games/mono-ec/prefix`.

### 2026-11-07 — the runtime LOADS; JIT code faults exactly where predicted

Build facts learned the hard way (all recorded in the configure/rebuild scripts):
- configure.ac line 171 forces `CC="$host-gcc"` for every cross build, so `--host` must be the
  `arm64ec-w64-mingw32` triple (configure.ac + generated configure: the `aarch64-*mingw*` case now
  reads `aarch64-*mingw*|arm64ec-*mingw*`); passing CC alone silently built plain ARM64 objects.
- A correct ARM64EC image is machine AMD64 (0x8664) + CHPE metadata (FEX's DLL, DXVK, a probe all
  are); ARM64X is 0xAA64 + CHPE (Hangover's ntdll); plain ARM64 is 0xAA64 without — wine skips it
  ("is for arch aa64", c000007b).
- After reconfiguring, `make` kept 152 stale ARM64 objects (config.h unchanged → nothing dirty); the
  link failed with lld's "undefined symbol: strlen (native symbol)". `make clean` after any host change.
- The ARM64 hosts need `_WIN32_WINNT=0x0A00` + `NTDDI_VERSION=0x0A000005`: `RtlAddGrowableFunctionTable`
  is declared only from 0x0602 (GCC tolerated the implicit declaration; clang 22 + C23 does not) and
  `VirtualAlloc2` only from RS4. Set per host in configure.ac.
- Under arm64ec `CONTEXT` is the x64 layout; the EC view is `ARM64EC_NT_CONTEXT` (individual X fields,
  no x13/x14/x18/x23/x24/x28, x16/x17 split into four WORDs, V[16]). Added
  `mono_arm64ec_context_to_monoctx`/back (mono-context.c), a `MONO_WIN32_CONTEXT_PC` accessor
  (mono-context.h) for exceptions-arm64.c and the profiler sampler, and `_M_ARM64EC` beside `_M_ARM64`.
- Guards (`!defined(__arm64ec__)`) on x64 inline asm / x64 assumptions: mini-codegen.c (bsfq),
  monobitset.c (bsfq, spelled `__x86_64` without trailing underscores — missed by the first census),
  valgrind.h (PLAT_amd64_win64), mono-memory-model.h (TSO), mono-context.h/.c (x64 MonoContext first
  in the #elif chain), mono-codeman.c (32-bit flag, 0xcc fill).

Result: `libmono-2.0-x86_64.dll` (ARM64EC, 28 MB) loads in the Hangover prefix ("Loaded … native"),
the runtime initialises, JIT-compiles, and the first call into JIT code faults: ACCESS_VIOLATION then
ILLEGAL_INSTRUCTION at 0x2E087FA/0x2E0899C — low addresses, i.e. code-manager memory — with x64-shaped
registers. FEX decoded the JIT's ARM64 instructions as x64: the JIT pages are not in the EC bitmap.
Next: allocate JIT memory with `MEM_EXTENDED_PARAMETER_EC_CODE` (wine's NtAllocateVirtualMemoryEx
honours it) in mono-codeman.c / mono-mmap-windows.c, and register ARM64 unwind info for EC frames.

### 2026-11-07 — managed JIT code RUNS natively; the first p/invoke is the next boundary

With JIT memory registered as EC code (`NtAllocateVirtualMemoryEx` + `MEM_EXTENDED_PARAMETER_EC_CODE`
in mono-mmap-windows.c for every executable allocation; the Windows executable heap dropped for the
dynamic code managers, mono-codeman.c), the hello world gets past the runtime-invoke wrapper and into
`Hello:Main` — JIT-compiled ARM64, executed by the CPU, not FEX. It dies in `Hello:GetCurrentProcessId`,
the p/invoke wrapper: ILLEGAL_INSTRUCTION at 0x6FFFFF6B0984, inside kernel32.dll (base 0x6FFFFF640000).
The JIT emitted a plain `blr` to the resolved import, which is kernel32's x64-facing export stub (an
ARM64X fast-forward sequence), so the CPU executed x64 bytes as ARM64. Exactly the predicted
"outbound to x64" boundary; the fault cascade that follows (AV at 0x6FFFFFA353D4, ntdll) is the
crash handler re-faulting, not a second bug.

Note the runtime-invoke wrapper worked unchanged: for up to four integer arguments the EC convention
and AAPCS64 use the same registers (x0–x3), so C→managed calls with small signatures survive by
coincidence. Stack arguments, the 32-byte shadow space, floats past v3 and struct passing will not.

### 2026-11-07 — HELLO WORLD RUNS on the ARM64EC runtime

```
hello from managed code, pid 32
fib(32)=2178309 in 16 ms        (x64 runtime under FEX: 26 ms)
runtime: v4.0.30319 ptr=8
```
Zero exceptions dispatched. The outbound boundary: p/invoke calls (`OP_CALL` family with a pinvoke
signature and an absolute target, and `OP_CALL_REG` with a pinvoke signature) now go through
`mono_arm64ec_native_call` (mini-arm64.c): x11 = target, then the OS checker this DLL's hybrid
metadata points at (`__os_arm64x_check_icall`, wine's `arm64x_check_call`), which returns an address
safe to `blr`: the target when it is EC code, the EC implementation when the target is an ARM64X
fast-forward stub (so kernel32 calls stay native), or `mono_arm64ec_exit_thunk` with x9 = the x64
target (shadow space, `__os_arm64x_dispatch_call_no_redirect`, result x8→x0). The checked sequence is
36 bytes, so cpu-arm64.md's call-family `len:` went from 32 to 48. PoC limits recorded in the code:
the exit thunk does not re-marshal stack arguments or mixed int/float lists, and the JIT still lays
out pinvoke arguments per AAPCS64 (identical to EC for ≤4 integer args).

### 2026-11-07 — hardware faults: the crash was FEX's, not mono's

A managed `NullReferenceException` is a real null dereference that the vectored handler turns into a
managed throw. On the EC runtime the process died with a bare SIGSEGV on wine's unix side instead.
Tracing wine's `segv_handler` (incremental tree, 8 s per rebuild) showed the fault itself was fine:
EC JIT code, sane sp, fault address 0x10, raised to `KiUserExceptionDispatcher` as expected. The
PE-side `prepare_exception_arm64ec` then calls the emulator's `ResetToConsistentState` hook, and FEX
called `NtContinue` with an ALL-ZERO context (pc = sp = 0). Cause, in FEX-2607
`Source/Windows/Common/JITGuardPage.h`: `HandleJITGuardPage` tests
`Address >= Thread->JITGuardPage && Address < JITGuardPage + 4096` before anything checks whether the
fault is in FEX code; `JITGuardPage` is assigned only when a thread compiles its first x64 block, so
on a never-JIT'd thread it is 0 and the test degenerates to "address < 4096": every null-page fault
matches, and FEX "resumes" through its never-initialised `RestartJump` buffer. The EC runtime's threads
never run x64 code (wine enters mscoree's `_CorExeMain` directly for a CLR image), so every managed
null check hit this. The x64 runtime's threads have JIT'd and hold a real guard page, which is why the
same test passes there. Fix = require a non-zero guard page:
`emulators/fex/patches/0002-jit-guard-page-needs-a-guard-page.patch` (the `JITGuardPage != 0` check; upstream from FEX-2611, so the patch no longer exists) (not yet wired into
`emulators/fex/default.nix` — doing so rebuilds fexdlls and every prefix). Verified through the
incremental FEX tree `/var/lib/games/fex-build` (`build-ec.sh`, ~20 s per rebuild; `nix develop
.#legacyPackages.aarch64-linux.fexdlls` supplies the toolchain) with the DLL dropped into the test
prefix. Any native EC code faulting on the null page from a never-JIT'd thread is affected the same way.

### 2026-11-07 — the EC boundary is complete: per-signature exit thunks, entry thunks, register masks

Verified with an x86_64 DLL built by the repo's llvm-mingw (`x86_64-w64-mingw32-clang`, cross, no
qemu) and a C# harness (`/var/lib/games/mono-ec/tests/x64test.{c,cs}`, 40 checks): calls into x64
code with 6 and 12 integer arguments (stack), mixed int/double and float/int32 lists, every struct
class (8/12/16/24 bytes, 2/3/4-float HFAs, a double pair) as argument and as return value, and the
reverse direction — x64 code calling managed delegates with the same shapes, 12 arguments, a managed
exception thrown and caught inside the callback. All pass on both runtimes. The 14-check suite
(p/invoke, exceptions, generics, GC pressure, threads, null dereference, divide by zero) passes;
fib(35) 70–75 ms vs 112 ms on the x64 runtime under FEX.

Protocol, as FEX implements it (`Source/Windows/ARM64EC/Module.S`) and clang emits it:

- OUT (EC → x64): the call site loads x11 = target, x10 = the exit thunk for the call's signature,
  then `blr` the checker, then `blr x11`. The checker returns x11 = target (EC code), the EC
  implementation (fast-forward stub) or x10 with x9 = the x64 target. Every system DLL export
  resolved through `GetProcAddress` is a fast-forward stub (first bytes `48 8b c4`, `RtlIsEcCode` 0)
  and the checker rewrites it to the EC implementation, so a p/invoke into kernel32/msvcrt is an
  EC→EC call with AAPCS64 arguments and no thunk at all; only genuinely x64 DLLs pay. The exit thunk
  allocates the shadow space and x64 stack slots, maps EC arguments to x64 positions (rcx/rdx/r8/r9 =
  x0–x3, xmm0–3 = v0–3 positionally, the rest on the stack), calls
  `__os_arm64x_dispatch_call_no_redirect` with exactly `blr x16` (FEX recognises that instruction at
  lr−4 to tell "return to an exit thunk" from "call an entry thunk"), and moves rax (x8) to x0.
- IN (x64 → EC): FEX reads the int32 at target−4 (bit 0 set, low two bits masked) as the offset to an
  entry thunk and enters it with x9 = target, x0–x3/v0–v3 = the first four x64 arguments, x4 = the x64
  stack (shadow space at +0, fifth argument at +0x20), lr = the return address. The thunk saves q6–q15
  (x64 preserves them whole; AAPCS64 only d8–d15), builds the wrapper's AAPCS64 layout, `blr x9`, puts
  the result in x8 and leaves through `__os_arm64x_dispatch_ret`. mono_codegen reserves a 16-aligned
  prefix in front of every `MONO_WRAPPER_NATIVE_TO_MANAGED` method (the only JIT code handed to native
  callers) and the arch hook emits the thunk there with the offset word at entry−4.
- Structs: x64 passes 1/2/4/8-byte structs by value in the integer slot and every other size as a
  pointer to a caller-owned copy; AAPCS64 packs ≤16 bytes into registers and HFAs into v registers.
  The thunks spill such arguments to a frame slot and pass the slot's 8 bytes or its address; returns
  go through a slot the same way (exact-size stores back into the x64 caller's buffer: a 12-byte struct
  must not get a 16-byte write).
- Ordering: both thunks first copy every register-held source into an image in their own frame, then
  build destinations with loads only. Any register-to-register schedule breaks on aggregates (a
  two-float HFA at position 0 occupies s0 AND s1, clobbering the float at position 1; a 16-byte struct
  in x0/x1 shifts every later integer index past its position) — two bugs the struct tests found.
- Exit thunks are cached per argument/return SHAPE (not per signature pointer, which can be recycled),
  in the root domain's code manager (EC-marked pages: the checker's return address must be EC code).
- Register allocator (mini-arm64.h, `__arm64ec__`): x13, x14, x23, x24, x28 and v16–v31 are out;
  x27 becomes the args register. Reason: they are absent from every CONTEXT the OS captures (a GC
  suspend would miss a reference there) and x64 code preserves none of them.
- Not handled (trap + warning at thunk creation): varargs signatures (the EC varargs convention is
  x4 = pointer to the stack arguments, x5 = their size). Mono's unwind registration stays ARM64-format:
  wine's EC `RtlLookupFunctionEntry` reads dynamic tables as `ARM64_RUNTIME_FUNCTION` for EC pcs.

### 2026-11-07 — Space Engineers, attempt 1: a generic Windows-ARM64 gap (frames > 512 KiB)

The stock package runs with the PoC artifacts shadowed in by a private user+mount namespace
(`/var/lib/games/mono-ec/bindns.sh`: the wine-mono store path → `image/`, the prefix lower's
`libarm64ecfex.dll` → the patched build; the launcher's own namespace nests inside and binds
recursively, so nothing on disk or in the store changes). The runtime loaded and the game died in
JIT compilation: `exceptions-arm64.c` `initialize_unwind_info_internal_ex` had a `TODO: UWOP_ALLOC_L`
assertion for a prolog allocating more than 512 KiB (`UWOP_ALLOC_M` covers 15 bits of 16-byte units).
Some SE method has such a frame. Not EC-specific — the mono fork's ARM64-Windows port would assert on
real Windows ARM64 too. Implemented the 3-byte `alloc_l` opcode (`11100000'x[24]`, x = size/16).

### wine-mono 11.3.0: the stack probe

wine-mono 11.3.0 carries the mono fork's MR 237, whose prolog probes frames over 4 KiB by calling the
`__chkstk` ntdll export it resolves with GetProcAddress. Under ARM64EC that export is the x64-facing
fast-forward stub, so the first large frame ends in an illegal instruction inside ntdll (Space Engineers:
"fatal error in the mono runtime" followed by wine's "Unhandled illegal instruction" at an ntdll address,
before the main menu). The patch routes the probe to `__chkstk_arm64ec`, the EC helper with the same
x15 = size/16 convention, and emits no probe when that address is not EC code — the fix the Unity
runtimes carry (unity-mono-arm64ec.md). 11.2.0 predates MR 237, so the earlier pin never hit it.

### 2026-11-07 — Space Engineers, attempt 2: main menu, world load, then Havok

With the large-frame opcode the game reached the main menu (DXVK swapchain 2560x1664, analytics
session, world configuration loaded) and the user loaded a save; the first physics build died in
`Havok.HkGridShape:HkGridShape_AddShapes` (x64 `Havok.dll`, the native engine; `HavokWrapper.dll` is
the managed side). Reproduced in isolation in `x64test`: the signature is
`(IntPtr, IntPtr, uint, Vector3S, Vector3S)` with `Vector3S` = three shorts, 6 bytes. x64 passes a
6-byte struct by POINTER; the thunk classified it as an 8-byte value because mono's `ArgInfo.size`
is the 8-ALIGNED stack size that `add_valuetype` computes, not the struct's size. The x64 code then
dereferenced the value (fault address 0x0000000300020001 = x,y,z = 1,2,3). Fix: classify by the real
native size from the parameter's `MonoType` (`mono_class_native_size` for pinvoke signatures), which
also makes the exact-size return stores exact. The generated thunk was disassembled from a word dump
printed under `MONO_ARM64EC_DEBUG` (also prints every exit/entry thunk's address range, to match
fault addresses). Harness now 43 checks. Note the crash handler itself hangs the process after the
report (both in the game and in the test) — a second problem, not yet looked at.

### 2026-11-07 — Space Engineers, attempt 3: past Havok, world loading

With the real-size classification the game reached the menu again (20 s) and the world load went
past `HkGridShape_AddShapes`. Open items noted on the way:

- Mono's native crash handler HANGS on the EC runtime after printing its report (the x64 runtime's
  aborts): a crashed game sits at ~2 cores instead of exiting. Diagnostic only, but it hides the exit
  code and holds the GPU. Not yet investigated — gdb attach needs `ptrace_scope` 0 or a gdb-spawned
  process (`handle SIGTRAP … pass` killed the inferior; wine needs its own SIGTRAP handling), so the
  next attempt should use `nix shell nixpkgs#gdb` with `nopass` for SIGTRAP or a core dump.
- A launch stalled once before the menu (swapchain created, window never fullscreen, every thread
  idle, main thread blocked in a server pipe read); the next launch with identical code worked.
  Intermittent startup race, cause unknown; the stock x64 runtime should be checked for the same.
- Exit thunks were being created for every internal call (icall wrappers carry a pinvoke signature):
  harmless, but each paid the checker. Now a p/invoke whose target is already EC code at JIT time
  (`RtlIsEcCode`) takes a plain `bl`; only x64 bytes (fast-forward stubs, x64 DLLs) go through the
  checker. (In the build tree; the running image predates it.)

### 2026-11-07 — SPACE ENGINEERS RUNS IN-WORLD ON THE ARM64EC RUNTIME

Attempt 5 (wine `+file,+seh` tracing and `MONO_LOG_MASK=gc` on): menu at 20:23:55, the user loaded
"Red Ship v2", `Session loaded` 12 s after `Loading session`, and the user reports it runs. Managed
code (the whole game: VRage, Sandbox, SharpDX bindings) executes as native ARM64 JIT output; Havok,
steam_api64 and the other x64 DLLs run under FEX behind the per-shape thunks; wine's EC DLLs are
called directly. Mono's GC log shows ordinary minor collections (6–7 ms, 12–16 ms stop-the-world)
with a 1.4 GB large-object space. Extra harness checks added on the way (46 total): a managed
exception thrown THROUGH x64 frames and caught by the managed caller, an x64 call after that unwind,
and a nested x64→managed→x64→managed chain all pass.

Two of five launches stalled (once before the menu with every thread idle; once at the 50 %
world-load mark with 21 threads inside `GetFileAttributesExW` at 72 % CPU — winedbg via
`nsenter -U --preserve-credentials -m -t <pid>` into the launcher's namespace, `attach 0x20; bt all`,
but it cannot unwind JIT frames). The traced run did not stall, so timing mattered. Both were the
stop-the-world stall diagnosed in the next entry: the runtime's preemptive suspend against the
emulator's doorbell polling, closed by cooperative suspend and, for the preemptive policy, by
emulators/fex/patches/0003.

### 2026-11-07 — the in-world freeze: a stop-the-world deadlock, from the SUSPEND POLICY

Root-caused from Mono's own suspend trace (`THREADS_SUSPEND_DEBUG`/`THREADS_STW_DEBUG` switched on in
`mono-threads-debug.h`) plus a suspend-count probe (`tests/suspcount.exe`: `NtQueryInformationThread
(ThreadSuspendCount)` over the game's threads, run inside the launcher's namespace with
`nsenter -U --preserve-credentials -m -t <pid>`, no attach, no perturbation). At the freeze the log
ends with the GC-initiating thread having issued `SuspendThread` for 16 threads (the main thread among
them) and then blocking inside `GetThreadContext` on the 17th, which never reports in; the 16 sit at
suspend count 1 forever. `ResumeThread` on them from outside (`tests/resumeall.exe`) un-froze the game
(the earlier "`peb_lock` … blocked by 0000" wait was one of them, parked between the lock's counter
increment and its owner write).

Why the 17th never reports: wine honours the ARM64EC suspend contract — a thread running x64 code
(`InSimulation`) or inside an emulator callback (`InSyscallCallback`) is not stopped; the doorbell is
rung and the thread parks itself at its next poll (`signal_set_full_context` → `wait_suspend`), and the
server hands out its context only then. FEX polls the doorbell at JIT block entry, before unconditional
backward branches and on every exit to native code, but NOT on a conditional backward branch (see "the
suspend contract" below, and `tests/spin.c`): a thread spinning in a conditional loop on something one
of the already-suspended threads must do never reaches a poll, and Mono's stop-the-world deadlocks.
Threads blocked in native waits are not the problem — both flags are clear there and they suspend at
once.

Why the x64 runtime does not hang the same way: wine-mono's x86_64 build has `ENABLE_HYBRID_SUSPEND`
(configure defaults it on for `X86 | AMD64` hosts on win32/linux/osx) — managed and runtime code
suspend cooperatively at safepoints, and only threads already in native/p-invoke code are preempted.
`arm64ec-w64-mingw32` falls outside that case, so the EC build silently got FULL PREEMPTIVE suspend.
The policy is runtime-selectable (`MONO_THREADS_SUSPEND=hybrid`; the define only matters for the
interpreter and the default), so the fix is `--enable-hybrid-suspend` for the EC build
(configure-arm64ec.sh updated) and, for the fork, adding ARM64 to that configure default. Hybrid still
preempts blocking threads in its mop-up phase, so the deadlock is narrowed, not proven impossible —
parity with the runtime the user already plays on is the bar here.

Hybrid was NOT enough: the next world load stranded 24 threads the same way, because hybrid's mop-up
phase still preempts threads outside managed code, and a thread preempted in simulation is subject to
the same doorbell gap. FULL COOPERATIVE suspend
(`MONO_THREADS_SUSPEND=coop`) never calls `SuspendThread`: running threads stop themselves at the
JIT's safepoint polls, threads inside native/p-invoke code count as safe and block on their way back
into managed code. Result with the same world: 0 native suspends across 827 stop-the-worlds, load in
11 s, no stranded threads, and the GC pause fell from 12–16 ms (preemptive) to ~3.6 ms, since nothing
waits on wine's cooperative EC suspension any more. configure-arm64ec.sh now carries
`--enable-cooperative-suspend` (compile-time default; the env var remains the override). The x64
runtime stays on hybrid; the FEX poll (emulators/fex/patches/0003, below) closes the gap for it as
well. The wine-side alternative (suspending an `InSyscallCallback` thread immediately
from its syscall frame) was tried and is wrong by the Windows contract — see "the suspend contract"
below. Coop needs nothing from wine.

Confirmed by the user: several leave-and-rejoin cycles on the cooperative-suspend runtime, all fine.
This closes the PoC phase; what follows is packaging (ARM64EC ABI in emulators/wine-mono for aarch64
hosts, `--enable-cooperative-suspend`, the FEX guard-page patch wired in, diagnostics stripped).

## Packaging (standing facts)

- `emulators/wine-mono/patches/0002-arm64ec-runtime.patch`: the whole runtime change (15 files + configure.ac),
  generated as `diff -ruN pristine/mono mono/mono` against the snapshot taken after patches/0001; applies with
  `-p1 --fuzz=0` on a fresh upstream tree after 0001. Its header is the design summary.
- `emulators/wine-mono/default.nix`: one `mkRuntime` recipe, two instances — `runtimeX86_64` (nixpkgs cross-GCC)
  and `runtimeArm64ec` (this tree's llvm-mingw, `--enable-cooperative-suspend --enable-nls=no`); on aarch64 hosts
  the ARM64EC build is installed as `bin/libmono-2.0-x86_64.dll` (the name mscoree asks for). Guards: machine
  `IMAGE_FILE_MACHINE_ARM64EC` + CHPE metadata (llvm-readobj), size ≤ 8 MB after `arm64ec-w64-mingw32-strip`
  (a fully stripped runtime passes the whole harness). `lib/default.nix` passes `llvmMingw` on aarch64 only.
- `emulators/fex/patches/0002-jit-guard-page-needs-a-guard-page.patch` (the `JITGuardPage != 0` check; upstream from FEX-2611, so the patch no longer exists): picked up automatically (every file under
  patches/ is applied).
- `emulators/wine-mono/tests/`: the harness sources and how to run them (not CI).
- Diagnostics left in the runtime: `MONO_ARM64EC_DEBUG=1` prints every exit/entry thunk's address range (and the
  exit thunk's words). Everything else (context prints, suspend traces) is gone.

Built through Nix on 2026-11-07: the FEX DLL is byte-identical to the incremental build that was tested in
the game; the ARM64EC runtime strips to 4.6 MB and passes the package guards; `ci/cache-audit.sh
aarch64-linux` passes; the STOCK `nix run .#space-engineers` (no namespace shadowing) runs on the packaged
runtime and reaches the menu.

## Benchmarks

Managed micro-benchmarks (`emulators/wine-mono/tests/bench.cs`; best of 3 in-process runs, same Hangover wine,
idle host, 2026-11-07), x86_64 runtime under FEX vs the ARM64EC runtime:

| benchmark | x64/FEX | ARM64EC | speed-up |
| --- | ---: | ---: | ---: |
| fib(35) | 109 ms | 70 ms | 1.6× |
| nbody 2M | 1325 ms | 352 ms | 3.8× |
| spectral-norm 1000 | 16183 ms | 225 ms | 72× |
| binary-trees 16 | 6708 ms | 177 ms | 38× |
| fannkuch 10 | 540 ms | 289 ms | 1.9× |
| mandelbrot 1600 | 598 ms | 471 ms | 1.3× |
| dict+strings+sort | 582 ms | 320 ms | 1.8× |
| alloc 20M | 8858 ms | 262 ms | 34× |
| interface dispatch | 132 ms | 113 ms | 1.2× |
| p/invoke 2M calls | 1425 ms | 42 ms | 34× |
| exceptions 200k | 254 ms | 95 ms | 2.7× |
| total | 36.7 s | 2.4 s | 15× |

Plain compute shows the expected emulation overhead (1.2–3.8×); allocation-heavy and p/invoke-heavy code is
30–70× faster, the pathological FEX behaviour on a 16 KiB-page host (JIT code writes and the nursery trip the
self-modifying-code tracking; every p/invoke crosses the emulator). The compiler itself: `mcs` compiling
suite.cs 2.61 s vs 5.06 s. World load of the same Space Engineers save on ARM64EC: 9.5–11.2 s cold,
3.3–3.5 s on rejoin.

In-game A/B (same save "Red Ship v2", same spot, MangoHud frame-time log over 60 s via `PROPNIX_BENCH=1` +
`MANGOHUD_CONFIG=…,toggle_logging=F2,log_duration=60`; the x64 run through `/var/lib/games/mono-ec/bindns-x64.sh`,
which shadows the packaged wine-mono with the previous x86_64 build; logs in /var/lib/games/mono-ec/mangohud/):

| | x64 runtime under FEX | ARM64EC runtime |
| --- | ---: | ---: |
| world load, cold | 37.1 s | 10.3 s (3.3–3.5 s warm rejoins) |
| average fps | 33.8 | 37.5 |
| median fps | 56.4 | 67.8 |
| 1 % low / 0.1 % low | 12.9 / 12.3 | 13.2 / 12.4 |
| p99 frame time | 75 ms | 73 ms |
| time spent in frames > 33 ms | 66 % | 67 % |
| CPU load (all 8 cores) | 43 % | 36 % |

Reading: the runtime switch takes a third of the CPU work off and makes loading 3.6× faster, but the in-game
frame rate is bounded by something both runtimes share — the stutter profile (a third of the frames slower than
33 ms, identical 1 %-lows) is the same on both. Candidates are the GPU side (DXVK on Asahi; MangoHud reports no
GPU-load counter on this driver) and the x64 Havok physics, which is still emulated on both. That is the next
thing to profile; it is not a Mono question any more.

### 2026-11-07 — the suspend contract, verified against the Windows conformance tests

What wine does with the three CHPE fields is the Windows contract, not a wine approximation.
`dlls/ntdll/tests/wow64.c` `test_suspend_doorbell` (Jacek Caban, 2026-05) runs on real Windows ARM64
and pins it:

- while `InSimulation` or `InSyscallCallback` is set, SuspendThread/GetThreadContext do not stop the
  thread: the kernel writes -1 to the doorbell, the thread keeps running, its syscalls and waits keep
  working, and GetThreadContext BLOCKS until the thread calls NtContinue with both flags clear ("with
  InSyscallCallback set, NtContinue does not suspend"; the same for InSimulation);
- a thread blocked in a syscall between two hook notifications (NtReadFile on a pipe) is suspended at
  once, 100 times in a row, with InSyscallCallback observed 0 — ntdll brackets only its calls into the
  emulator, never the blocking syscall itself;
- `InSyscallCallback` therefore means "ntdll is inside an emulator callback" (xtajit64's `BTCpu64Notify*`,
  `Notify*`, `ThreadInit`, …). Wine sets it in `enter_syscall_callback`/`leave_syscall_callback` around
  exactly those calls — the alloc/free/protect bracket spans the syscall between the before and after
  hooks, which is the interval FEX holds its `ThreadCreationMutex` — and FEX sets it itself inside
  `ResetToConsistentState` (`ScopedCallbackDisable`).

Wine's implementation of the contract: `usr1_handler` takes the cooperative branch when either flag is
set (server `SELECT_COOPERATIVE_SUSPEND` → the thread's context object is marked `cooperative`, the
doorbell is written -1, `suspend_pending` set); a cooperative thread does not count as suspended for
wait purposes, so its waits proceed; `get_thread_context` answers PENDING and the caller waits on the
context object; the thread parks in `signal_set_full_context` (reached by every NtContinue, including
FEX's direct-syscall `NtContinueNative`) once both flags are clear — `leave_syscall_callback`, the JIT's
`brk #0xCAFE` and `ExitFunctionEC`'s doorbell check all funnel there.

Consequences, each measured:

1. Threads blocked in waits entered from x64 code have both flags clear (`ExitFunctionEC` clears
   `InSimulation` before the call) and are suspended at once by the `is_inside_syscall` branch. In a
   traced preemptive session (original wine rule, `PROPNIX_WINEDEBUG=+seh` with a trace in
   `usr1_handler`): 28533 suspend signals, 5884 on that branch; the cooperative branch fired 135 times
   (JIT code, FEX hooks, syscalls inside a hook bracket) and all 135 were consumed; the session loaded a
   world and played to a normal quit, median stop-the-world 7.1 ms, p99 46 ms, max 108 ms.
2. A thread inside an emulator memory hook, holding the emulator's lock, can never be preemptively
   suspended — on Windows by the same contract. The experiment of suspending `InSyscallCallback`
   threads immediately from their syscall frame (wine `usr1_handler`, `MONO_THREADS_SUSPEND=preemptive`)
   deadlocked within 30 s on exactly that: of 1531 signals exactly one hit a thread with the flag set —
   the main thread in `FEXCore::LookupCache::InvalidateCacheRange`, called from `NotifyMemoryAlloc(After)`
   with `ThreadCreationMutex` held — and the collector, allocating a block mid-nursery-collection
   (`sgen_alloc_os_memory_aligned` → VirtualAlloc → the same hook → `RtlEnterCriticalSection`), waited on
   that mutex with the world stopped (`RtlpWaitForCriticalSection` timeout + `RtlCaptureStackBackTrace`,
   bases from `+loaddll`, symbols from the unstripped incremental FEX build). The deadlock is created by
   the rule change; it is not a property of emulated preemption, and there is no evidence that xtajit64
   is exposed to anything like it.
3. The real hazard of preemptive suspension under FEX is a thread in simulation that never reaches a
   doorbell poll. `tests/spin.c` isolates it: FEX emits the poll at block entry and before an
   UNCONDITIONAL backward branch (`JIT.cpp` `EmitSuspendInterruptCheck`), but `DEF_OP(CondJump)`
   (`BranchOps.cpp`) branches to a backward target with no poll. Under hangover wine, a loop closed by a
   conditional branch — `pause; mov; test; je 1b`, the canonical spin-wait — is suspended only when it
   exits (3000 ms, the watchdog's release); the `jmp`-closed loop and the loop containing a call suspend
   in 0 ms. FEX main (2026-11-07) has the same gap. A preemptive stop-the-world that catches a registered
   thread spinning in such a loop on something an already-suspended thread must do blocks in
   GetThreadContext forever — the observed shape of the preemptive and hybrid freezes (every suspended
   thread at count 1, the initiator parked on the last). It is a race: two preemptive loads froze, the
   traced session above did not.

Policy: full cooperative suspend sidesteps all of this and stays the shipped default; it needs nothing
from wine. Whether xtajit64 polls inside conditional loops is unverified (no Windows ARM64 machine
here); preemptive x64 runtimes work on Windows on ARM in practice, which is evidence that it does.
Experiment residue: none — wine tree, mono tree and PoC image are back to the packaged state, and the
packaged patch re-verified byte-identical to the source tree.

### 2026-11-08 — the FEX fix: poll before conditional back-edges (emulators/fex/patches/0003)

`DEF_OP(CondJump)` (`FEXCore/Source/Interface/Core/JIT/BranchOps.cpp`) now emits
`EmitSuspendInterruptCheck()` before its `b.cond`/`cbz`/`cbnz`/`tbz`/`tbnz` whenever the true target is
already emitted (`TrueTargetLabel->Backward.Location`), i.e. the branch is a loop back-edge — the same
poll the block loop already places before an unconditional backward branch. The check is flag-neutral
(doorbell load into a scratch register + `cbz`), so it is legal in front of a branch that consumes NZCV,
and it sits at a guest instruction boundary: a trap there reconstructs the state at the branch and the
branch re-executes on resume. Built in the incremental tree (`/var/lib/games/fex-build`, `build-ec.sh`);
the patch applies with `--fuzz=0` to the pinned FEX-2607 source, and the Nix `fexdlls` output built from
it (`libarm64ecfex.dll`) is byte-identical to the incremental build, as it was for patch 0002. Staging
the patch file is what makes the flake pick it up (every file under `emulators/fex/patches` is applied),
and the next `nix run` of an aarch64 game then rebuilds fexdlls, the prefix-lower and the game closure.

`tests/spin.c`, baseline vs patched DLL (bind-mounted over the x64 test prefix's copy with
`bindns-fex.sh`, nothing on disk changed):

| loop shape | baseline | patched |
| --- | --- | --- |
| `test; je 1b` | 3004 ms (only when the loop ended) | 0 ms, Rip inside the loop |
| `pause; test; je 1b` | 3001 ms | 0 ms |
| `jmp`-closed | 0 ms | 0 ms |
| loop containing a call | 0 ms | 0 ms |

Cost, `tests/bench.exe` on the x64 wine-mono runtime under FEX (best-of-3 per benchmark, one run each):

| benchmark | baseline | patched |
| --- | --- | --- |
| fib(35) | 109 ms | 109 ms |
| nbody 2M | 1321 ms | 1339 ms |
| spectral-norm 1000 | 15792 ms | 16472 ms |
| binary-trees 16 | 6318 ms | 6550 ms |
| fannkuch 10 | 538 ms | 545 ms |
| mandelbrot 1600 | 598 ms | 602 ms |
| dict+strings+sort | 578 ms | 597 ms |
| alloc 20M | 9084 ms | 8672 ms |
| interface dispatch | 132 ms | 132 ms |
| pinvoke 2M calls | 1457 ms | 1417 ms |
| exceptions 200k | 256 ms | 258 ms |
| TOTAL | 36183 ms | 36693 ms |

+1.4 % in total, with the loop-heaviest benchmarks (spectral-norm, binary-trees) at +4 %; two baseline
runs of the same binary on different occasions differ by 1.5 % in total and 2–6 % per benchmark, so the
poll's cost is at or below the measurement noise here. (These loops are x64 Mono JIT output and already
carry Mono's own safepoint polls; a pure native x64 inner loop would show the two added instructions
more clearly.) The same change lands in `libwow64fex.dll`, where `EmitSuspendInterruptCheck` emits the
interrupt-fault-page store WoW64 suspension uses, so 32-bit guests gain the poll too.

Who benefits: x64 runtimes under FEX that stop the world preemptively — Unity's Boehm collector, .NET
Framework, Mono in preemptive/hybrid mode. The shipped ARM64EC Mono stays cooperative and never
exercises this path.

Verification on the title: the packaged game on the Nix-built patched DLL with
`MONO_THREADS_SUSPEND=preemptive` loaded a world 5 times out of 5 (2026-11-08), against 2 freezes in 3
loads on the unpatched DLL. The shipped policy is unchanged: cooperative suspend, which does not depend
on this poll at all.

### 2026-11-08 — dynamic function tables under ARM64EC must be ARM64 entries

Found while porting to Unity 6, whose unwind code reads the packed bit-fields of the ARM64 entry and
so did not compile with mingw's `RUNTIME_FUNCTION`: for the arm64ec target mingw's `RUNTIME_FUNCTION`
is the 12-byte AMD64 layout (`UnwindData` at +8; `_Static_assert`-verified), while wine's unwinder
reads an EC process's growable tables as 8-byte `ARM64_RUNTIME_FUNCTION` entries (`UnwindData` at +4):
`RtlLookupFunctionEntry` in dlls/ntdll/unwind.c casts the result of `lookup_dynamic_function_table` to
`ARM64_RUNTIME_FUNCTION *` for EC code. The mono fork's Windows-ARM64 port fills `RUNTIME_FUNCTION`
entries by field name (`BeginAddress`, `UnwindData`), so under ARM64EC every table it registered with
`RtlAddGrowableFunctionTable` was misaligned from the second entry on: an OS-level walk through JIT
frames (SEH dispatch after the vectored handler declines, `RtlCaptureStackBackTrace`, the crash
reporter) could not unwind them. Managed exceptions never showed it because `mono_handle_exception`
walks frames with mono's own unwind ops. Fix in patch 0002: under `__arm64ec__`, `mini-arm64.h` maps
`RUNTIME_FUNCTION`/`PRUNTIME_FUNCTION` to the ARM64 entry types after `<windows.h>`, and the
registration call passes the table as `void *`. The same applies to the mono fork upstream (prose
report). Candidate explanation for the crash-handler hang seen on Space Engineers and REPO.

