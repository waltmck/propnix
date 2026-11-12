# FEX's wine unixlib: hardware TSO and kernel unaligned atomics on the wine path

FEX's Windows DLLs (`libarm64ecfex.dll` for x86_64 guests, `libwow64fex.dll` for i386) run inside a
wine process and cannot call the Linux kernel themselves. Every kernel interface they use goes through
a small native helper, FEX's wine *unixlib* (`Source/Windows/UnixLib/FEXUnixLib.cpp`), built as
`libarm64ecfex.so` and `libwow64fex.so`. emulators/fex builds both and installs them under
`$out/aarch64-unix/`; the launcher puts `$out` on `WINEDLLPATH` (the `wineDllPath` emulator field,
baked on aarch64 only).

## What goes through it

| unixlib call | kernel interface | without the unixlib |
|---|---|---|
| `SetHardwareTSOControl` | `PR_SET_MEM_MODEL` (`0x4d4d444c`), TSO | FEX emulates x86 ordering in software |
| `SetKernelUnalignedAtomicControl` | `PR_ARM64_SET_UNALIGN_ATOMIC` (`0x46455849`) | unaligned atomics take the signal path |
| `SupportsTPIDRRO_CPU` | `PR_GET_TPIDRRO_CPU` (`0x7F1DBB0`) | RDTSCP and RDPID hidden from the guest's CPUID |
| `MapFile` | `mmap` of the disk-cache files | the disk cache reads files instead of mapping them |
| `Madvise`, `SetVMAName` | `madvise`, `PR_SET_VMA` | no THP hints, unnamed JIT mappings |

Each wrapper returns "not supported" when the unixlib is absent, and FEX logs nothing about it. With it
present, `FEX_SILENTLOG=0` shows:

    FEX: Loaded FEXUnixLib
    FEX: Kernel unaligned atomics enabled!

and the game process maps `.../aarch64-unix/libarm64ecfex.so`.

## How wine finds it

The DLL asks for it by name (`NtQueryVirtualMemory(..., MemoryWineLoadUnixLibByName, L"libarm64ecfex")`).
wine's `load_unixlib_by_name` (dlls/ntdll/unix/loader.c) tries its build tree, then
`<entry>/aarch64-unix/<name>.so` for each entry of its DLL path: wine's own `lib/wine` first, then each
`WINEDLLPATH` directory. A unixlib beside the PE DLL in `system32` is not found. FEX's older fallback
(`MemoryWineUnixFuncs` on the DLL's own image) applies only to wine builtins, which the FEX DLLs are not.

The helper links libstdc++ and libgcc statically, so it depends only on glibc: wine `dlopen`s it into a
process that also carries the graphics stack's C++ runtime.

## Measurements (Apple M2, kernel with `CONFIG_ARM64_MEMORY_MODEL_CONTROL` and the unaligned-atomic patch)

An x64 loop of ordinary loads and stores (`buf[k] = acc ^ k`, 6 s, pinned to one performance core):

| | iterations in 6 s |
|---|---|
| FEX DLLs, no unixlib | 2.29–2.30 M |
| FEX DLLs + unixlib on `WINEDLLPATH` | 2.89–2.93 M |

A misaligned `lock inc` straddling a 16-byte boundary, 200 000 times on one core:

| | per operation | `SIGBUS` reaching the process |
|---|---|---|
| no unixlib (wine's signal path into FEX's handler) | 3 240–3 263 ns | 200 001 |
| unixlib (kernel emulation) | 230–233 ns | 0 |

The ordering mode is visible in the JIT code itself. Sampling the hottest blocks of a running game
(`perf record -p`, then the code read from `/proc/<pid>/mem` and disassembled):

| process | ordinary loads/stores | acquire loads (`ldapr`/`ldapur`/`ldar`) | release stores (`stlr`/`stlur`) |
|---|---|---|---|
| Victoria 3, wine path, no unixlib | 2 737 | 862 | 202 |
| Victoria 3, wine path, with the unixlib | 3 797 | 14 | 0 |
| Civilization V, Linux FEX (prctl called directly) | 4 210 | 0 | 7 |

With hardware TSO on, FEX turns its atomic-based TSO emulation off (`UpdateAtomicTSOEmulationConfig`
in FEXCore's Context.h), so ordinary guest accesses become plain `ldr`/`str`.

## The disk cache does not record the ordering mode

FEX's disk-cache bucket hash covers its format version, the host CPU feature registers, the process
type and the code-affecting config options. It does not cover whether hardware TSO is on, and the cache
is initialized in `InitCore`, before the TSO setup runs. Code compiled under software TSO therefore keeps
its barriers when reused with hardware TSO, and code compiled with hardware TSO is unsafe in a process
running without it. The launcher names the cache directory after the kernel's offer:
`<cache>/<app>/fex-tso` when `prctl(PR_GET_MEM_MODEL)` answers, `<cache>/<app>/fex` when it does not.
Both the wine and the Linux FEX paths use that directory.

## Kernel interfaces FEX probes

FEX-2611 uses several interfaces that are not in mainline Linux. On a given kernel:

| interface | prctl | used by | effect when missing |
|---|---|---|---|
| memory model control (TSO) | `PR_GET_MEM_MODEL` / `PR_SET_MEM_MODEL` | both paths | software TSO |
| unaligned atomic emulation | `PR_ARM64_SET_UNALIGN_ATOMIC` | both paths | signal-based handling in FEX |
| CPU index in `TPIDRRO_EL0` | `PR_GET_TPIDRRO_CPU` | both paths | wine path: no RDTSCP/RDPID; Linux path: `getcpu` syscall per RDPID |
| compat syscall input | `PR_GET_COMPAT_INPUT` / `PR_SET_COMPAT_INPUT` | Linux path, 32-bit guests | FEX translates compat syscall inputs itself |

Probe with `prctl(op, 0, 0, 0, 0)`: `EINVAL` means the kernel lacks it. The unaligned-atomic handler
publishes no counter, trace event or log line; its use by a given process shows only as alignment
faults that never reach it as `SIGBUS` (`strace -e trace=none -e signal=SIGBUS`), or, as root, as hits
on a kprobe on `do_unaligned_atomic_fixup` filtered by that process. The unaligned-atomic patch is
`arch: arm64: Implement unaligned atomic emulation/backpatching` (github.com/bylaws/linux, branch
`fex-unaligned-atomic`). The TPIDRRO CPU index is FEX PR #6087; compat input is an Asahi kernel patch
(FEX-2412 release notes).

box64, including `wowbox64.dll`, makes none of these calls: it uses wine's unix-call dispatcher only to
forward the 32-bit guest's own wine calls, and orders memory through its `BOX64_DYNAREC_STRONGMEM`
setting rather than the kernel's TSO mode.
