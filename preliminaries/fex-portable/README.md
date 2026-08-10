# fex-portable

FEX-Emu **2605** patched to run on hosts whose kernel page size is larger than
4K. Upstream FEX regressed large-page support in 2508 and now hard-requires a
4K host page; Fedora Asahi ships no fix. This fork restores operation on the
16K pages used by Apple Silicon / Asahi Linux, and — because every boundary is
derived from `sysconf(_SC_PAGESIZE)` at runtime rather than assuming a value —
the same binary also works at 32K and 64K.

Status: runs x86_64 (and x86) Linux ELFs correctly and stably — both **static**
(`hello`, `coreutils` with correct `sha256sum` digests / prime `factor`) and
**dynamically linked** (glibc, libstdc++, libm, libgcc_s all load and run), with
the guest seeing `x86_64` from `uname`. This is a research proof-of-concept
intended to be shown to the FEX maintainers, and a base for packaging emulated
x86_64 apps on this host.

## Layout

- `fex-portable.patch` — the entire fork, one reviewable ~295-line patch over
  the exact FEX 2605 source nixpkgs already pins (`flake:nixpkgs`'s `fex.src`
  is byte-identical to what the patch was cut against, so it applies cleanly).
- `default.nix` — `pkgs.fex.overrideAttrs` that applies the patch. We reuse
  nixpkgs' FEX build (cmake flags, thunks, FEXServer) rather than vendoring the
  tree, so the diff stays small and rebases trivially onto a newer FEX.

```sh
nix-build preliminaries/fex-portable      # -> result/bin/{FEX,FEXInterpreter,FEXServer}
```

## Why it broke, and the eight walls

The core mismatch: FEX emulates a guest that sees **4K** pages on a host whose
kernel only accepts `mmap`/`mprotect` on **16K** boundaries. Two failure modes
recur:

1. an `mmap`/`mprotect` with a 4K-granular address or length is rejected with
   `EINVAL`, and
2. a guest page's permissions must change at 4K granularity, but the smallest
   unit the host can reprotect is a 16K page that also covers three unrelated
   4K guest pages (the *mixed-permission* problem).

Each hunk fixes one concrete instance. Diagnosis was almost entirely
`strace -f -e mprotect,rt_sigreturn,mmap` on a storming run: the offending
`... = -1 EINVAL` line plus mapping the fault address back to its owning `mmap`
region identified every wall. (gdb attach and in-handler `write()` probes did
*not* work — FEX routes faults through its own signal fast-paths.)

| # | File | Fix |
|---|------|-----|
| 1 | `External/jemalloc_glibc/pregen/.../jemalloc_internal_defs.h` | `LG_PAGE` 12 → **16**. jemalloc refuses to start when its compiled page < the system page. 16 (64K) is chosen over 14 (16K) so one binary spans 16K/32K/64K (compiled page ≥ system page always holds). |
| 2 | `FEXCore/include/FEXCore/Utils/AllocatorHooks.h` | `VirtualProtect`: asymmetric host-page snap. When *removing* access (guard/PROT_NONE) only the fully-contained host pages are touched, so we never revoke a live neighbour; when *adding* access the range is widened to the enclosing host pages. |
| 3 | `Source/Tools/LinuxEmulation/VDSO_Emulation.cpp` | Snap the VDSO size and placement hint to the host page before the `MAP_FIXED_NOREPLACE` top-down scan. Unaligned hints `EINVAL` every attempt, spinning the scan ~2³³ times (looked like a hang). |
| 4 | `Source/Tools/FEXInterpreter/ELFCodeLoader.h` | Replace the per-segment file-backed `MAP_FIXED` loader with span-reserve + `pread`. ELF `PT_LOAD` segments are 4K-aligned but often *not* 16K-aligned, so they cannot be `MAP_FIXED`-mapped individually on 16K; instead reserve the whole span host-aligned once, then read each segment's bytes in. |
| 5 | `Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp` | `GuestMprotect`: snap addr/len to the host page so guest `mprotect` calls don't `EINVAL`. |
| 6 | `Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp` | **SMC works on 16K (both directions).** SMC tracking read-protects code pages so guest writes to code fault and get re-translated. Both `mprotect`s must be host-page-aligned: `UnprotectRegionCallback` (the on-write handler) snaps *out* and grants RW (a 16K page with any writable 4K guest page becomes writable); `MarkGuestExecutableRange` (the protect side, `mprotect(PROT_READ)`) also snaps *out* to protect the enclosing host page(s). Snapping the protect side out also RO-protects neighbouring 4K pages, but that is correctness-safe — a write there faults and is handled — and JIT code (e.g. Mono) sits in its own host-page-aligned executable allocation, so there is usually no collateral. This lets us keep upstream's `MTRACK` default rather than disabling SMC. |
| 7 | `Source/Tools/LinuxEmulation/LinuxSyscalls/ThreadManager.{cpp,h}` | **The decisive storm — the CALLRET stack.** Its guard pages were `FEX_PAGE_SIZE` (4K), so `CallRetStackBase = AllocBase + 4096` was not 16K-aligned and the `mprotect` that commits the 4 MB stack `EINVAL`ed. The stack stayed `PROT_NONE`, so *every guest `CALL`* faulted; the overflow handler just reset the stack pointer and returned, re-faulting forever (100k+ identical SIGSEGVs/sec). Fix: guard pages become one host page each (`CallRetGuardSize()` = `sysconf`), making the base host-aligned. |
| 8 | `Source/Tools/LinuxEmulation/LinuxSyscalls/SyscallsSMCTracking.cpp` | **Dynamic linking — `GuestMmap`.** The guest `ld.so` maps each shared-library PT_LOAD segment with a file-backed `MAP_FIXED` at 4K granularity; the 16K kernel rejects any whose address *or* file offset is sub-host-page, so no dynamically-linked guest can load `libc`. Emulate it: back the whole host-page span with private anonymous memory (always writable, never beyond-EOF) and `pread` the segment's bytes in, preserving the neighbour fragments in the shared end pages via a fault-safe `/proc/self/mem` read (offsets aren't host-aligned either, as ELF only guarantees `vaddr ≡ offset mod 4K`). File sharing/COW is traded for correctness; this is box64's loader logic, moved into FEX's mmap syscall. |

(Walls 5, 6 and 8 are hunks in the same file, so the patch touches seven files.)

## Portability across page sizes

Only wall 1 is a compile-time constant. Every other hunk reads
`sysconf(_SC_PAGESIZE)` and aligns to it, so the runtime adapts to whatever the
host reports. With `LG_PAGE = 16` the jemalloc floor is 64K, which satisfies
jemalloc's "compiled ≥ system" rule on 4K/16K/32K/64K hosts. Net cost on a 16K
host: jemalloc manages FEX's *own* heap at 64K granularity (a little extra RSS);
guest memory management is unaffected (it uses the runtime page size).

## Limitations

- **SMC has a mixed-permission cost** (wall 6). SMC tracking is enabled
  (`MTRACK`, upstream default) and works, but read-protecting a 4K code page on
  a 16K host protects the three neighbouring 4K pages too. That stays *correct*
  — a write to a neighbour faults and is handled — but each such write costs a
  fault, so a 16K page mixing code and hot data is slow. It also means a syscall
  that writes into a guest buffer sharing a host page with code could see
  `EFAULT`; not observed with the guests tested, but a real edge. A per-4K
  shadow-permission scheme would remove both costs and is the deeper design
  question for upstream.
- **JIT guests are not fully working yet.** A JIT that patches its own code in
  place (e.g. Mono trampolines) exercises SMC hard; Hollow Knight (Unity/Mono)
  gets through Mono load and Unity init under fex-portable but then hits a guest
  `SEGV_MAPERR` at NULL during early Mono runtime init — a null jump not yet
  resolved by the SMC fix (see `poc/hollow-knight-x86_64-fex.nix`).
- Dynamically-linked guests work, but wall 8's emulation drops file-backing for
  the sub-host-page segments (they become anonymous copies), so those pages are
  not shared between processes and do not show as file-backed in the guest's
  `/proc/self/maps`. Fine for running apps; a concern only for tools that
  introspect their own mappings.
- Run with `FEX_ROOTFS=/` when the guest's interpreter and libraries are
  absolute store paths (as nixpkgs x86_64 binaries are); a foreign binary with a
  bundled `/lib64/ld-linux-x86-64.so.2` needs `patchelf` or a populated RootFS.

## For the FEX maintainers

The single patch is deliberately small and each hunk is annotated with a
`propnix 16K-host:` comment explaining the failure it fixes. The clean design
question it raises: FEX currently assumes host page size == guest page size ==
4K in several places (jemalloc, the CALLRET guard geometry, VDSO/ELF placement,
and the SMC protect path). Walls 1–7 are mechanical
`align-to-sysconf(_SC_PAGESIZE)` changes that would be reasonable upstream as-is
(the SMC pair, wall 6, keeps `MTRACK` working rather than disabling it). The one
that needs a real design decision is wall 8 (sub-host-page guest mmap — the
general problem of emulating a 4K-page guest on a larger-page host, which box64
solves in its own loader; the patch does the correct-but-lossy thing of copying
instead of file-mapping). The open frontier is a per-4K shadow-permission scheme
that would make both SMC and guest-driven `mprotect` exact on large pages — the
likely fix for the remaining JIT-guest (Mono) crash.
