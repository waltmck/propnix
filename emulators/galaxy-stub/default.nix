# galaxy-stub — graceful no-op replacements for the GOG Galaxy SDK DLLs that some GOG games bundle.
#
# WHY. A packaged game must run FULLY OFFLINE, with no cloud dependencies — that is a design principle of
# this repo, not a per-game workaround. Several GOG titles statically import GOG's Galaxy SDK
# (Galaxy64.dll / Galaxy.dll) and the older "POPS" online-services client (pops_api.dll), which spin up a
# network/RPC layer at startup and reach for GOG's services. Neutralizing that is the same policy propnix
# applies to Steam builds by masking `steam_api64.dll` so the loader reports "no online subsystem": the
# game plays, nothing phones home, and the result does not depend on a service being reachable — today or
# in ten years, which is the whole point of packaging these reproducibly.
#
# WHY A STUB (and why it can't be an empty DLL). The games *statically* import specific symbols, so the DLL
# must export exactly those, and the SDK "init" path must return cleanly without doing any RPC/socket work.
# We build tiny native PE DLLs that export the imported symbols and do nothing but hand back benign,
# "offline / not-signed-in" values. No RPC is ever attempted. Static imports also cannot be turned off with
# WINEDLLOVERRIDES — wine's loader resolves them from the exe's own directory first — so a bound stub is
# the only mechanism that works.
#
# NOT A CRASH WORKAROUND. The SDK's RPC init used to fault wine's builtin rpcrt4 (`page fault on write
# access to 0000000000000010`), which is how these stubs were first discovered. That was an ARM64EC
# variadic exit-thunk defect in the compiler, fixed by the toolchain backport in emulators/llvm-mingw
# (RESEARCH §23) — VERIFIED 2026-08-21 by running Prison Architect, the original casualty, with the real
# Galaxy64.dll/pops_api.dll loaded: it reaches a window with no fault. So nothing here is load-bearing for
# stability; keep it for the offline guarantee, and do not "fix" a crash that no longer exists.
#
# THE TWO EXPORT SHAPES (dumped from the games' real DLLs with winedump -j import). Different SDK builds
# expose the API differently, so the stub exports the UNION so it is a drop-in for either:
#   * GalaxyFactory statics — the SDK header's inline api::Init/User/… wrappers resolve to these
#     (Prison Architect): CreateInstance, GetInstance, GetErrorManager, ResetInstance.
#   * galaxy::api:: FREE functions — some builds export these directly and the game imports them
#     (Hollow Knight's GalaxyCSharpGlue.dll): Init, Shutdown[Ex], ProcessData, User, Friends, Chat,
#     Matchmaking, Networking, Stats, Utils, Apps, Storage, CustomNetworking, Telemetry, CloudStorage,
#     Logger, ListenerRegistrar, GetError, and their GameServer* / *GameServer* variants.
# pops_api.dll (Prison Architect): POPS_Initialize/Shutdown/RunCallbacks/AccountLogInWithAuthToken/
#   AutoStandardTelemetryEnable/LegalGetDocument/LegalGetDocumentsList/GenerateGUID.
# The 64-bit union is `src/symbols64.txt` (one mangled symbol per line); add a game's extra imports there if
# a new title needs them. The ABI strategy + the four C bodies each symbol aliases to are documented in
# `src/galaxy_stub.c` (and pops in `src/pops_stub.c`).
#
# ARCH. The stub DLLs match the GAME's arch, not the host: a game's Galaxy64.dll is x86_64, so wine's loader
# resolves the import against x86_64 (even on aarch64/ARM64EC, where the tiny stub then runs emulated — its
# cost is nil). So these are x86_64 (+ i386) PEs, built with llvm-mingw. Only aarch64 (the winefex path)
# wires this in; see lib/default.nix and lib/builders/wine.nix.
#
# The GalaxyFactory / api:: exports are MSVC-mangled (64-bit uses PEAV/PEBV far-encoding, 32-bit PAV/PBV),
# aliased to the plain C bodies via a .def EXPORTS list generated below by `classify` (the 32-bit names are
# derived from the 64-bit ones by the well-defined pointer-encoding transform).
{
  lib,
  runCommand,
  llvmMingw,
  python3,
}:
let
  cc64 = "${llvmMingw}/bin/x86_64-w64-mingw32-clang";
  cc32 = "${llvmMingw}/bin/i686-w64-mingw32-clang";
  llvmAr = "${llvmMingw}/bin/llvm-ar";

  # Pin the C/symbol sources to a CONTENT-ADDRESSED store path (keyed only by src/'s bytes, not the flake
  # source), so unrelated repo edits never rebuild the stub — only touching src/ does.
  srcDir = builtins.path {
    path = ./src;
    name = "galaxy-stub-src";
  };

  # llvm-mingw ships the i386 compiler-rt builtins with a broken archive index that DROPS __alloca /
  # ___chkstk_ms (the same duplicate-member armap bug the toolchain's postFixup already fixes for the
  # x86_64/aarch64 archives, but NOT i386). The 32-bit CRT's pseudo-relocator references __alloca, so a
  # naive i686 link fails with `undefined symbol: __alloca`. Reindex a private copy here (reusing the
  # toolchain's own reindex-ar.py) and link it in a group — contained entirely to this derivation, so it
  # needs no llvm-mingw rebuild (which would cascade into wine/dxvk/FEX and disrupt other work). Pinned
  # content-addressed like srcDir above.
  reindexPy = builtins.path {
    path = ../llvm-mingw/reindex-ar.py;
    name = "reindex-ar.py";
  };
in
runCommand "galaxy-stub"
  {
    nativeBuildInputs = [
      llvmMingw
      python3
    ];
    meta.description = "Graceful no-op GOG Galaxy SDK stubs (Galaxy64.dll/Galaxy.dll/pops_api.dll) for wine";
  }
  ''
    set -euo pipefail
    mkdir -p "$out" build && cd build

    # Classify each 64-bit symbol by return type and emit galaxy64.def (+ galaxy32.def with the 32-bit
    # pointer encoding: far PEAV/PEBV/AEBU/AEBV/AEAV -> near PAV/PBV/ABU/ABV/AAV). See src/galaxy_stub.c for
    # what each C body (noop_void / ret_galaxy / ret_dummy / ret_zero) does.
    classify() {
      case "$1" in
        *ResetInstance@GalaxyFactory*)               echo noop_void ;;   # void
        *CreateInstance@GalaxyFactory*|*GetInstance@GalaxyFactory*) echo ret_galaxy ;;
        *GetErrorManager@GalaxyFactory*)             echo ret_dummy ;;   # IErrorManager* (non-null)
        '?GetError@'*)                               echo ret_zero ;;    # const IError* -> null (no error)
        *@@YAX*)                                     echo noop_void ;;   # void free funcs (Init/Shutdown/…)
        *)                                           echo ret_dummy ;;   # interface accessors (non-null)
      esac
    }
    echo EXPORTS > galaxy64.def
    echo EXPORTS > galaxy32.def
    while IFS= read -r sym; do
      [ -n "$sym" ] || continue
      impl="$(classify "$sym")"
      echo "$sym = $impl" >> galaxy64.def
      sym32="$(printf '%s' "$sym" | sed 's/PEAV/PAV/g; s/PEBV/PBV/g; s/AEBU/ABU/g; s/AEBV/ABV/g; s/AEAV/AAV/g')"
      echo "$sym32 = $impl" >> galaxy32.def
    done < ${srcDir}/symbols64.txt

    # ── 64-bit stubs (Galaxy64.dll, pops_api.dll) ──────────────────────────────────────────────────
    ${cc64} -O2 -shared -o "$out/Galaxy64.dll" ${srcDir}/galaxy_stub.c galaxy64.def
    ${cc64} -O2 -shared -o "$out/pops_api.dll" ${srcDir}/pops_stub.c

    # ── 32-bit stub (Galaxy.dll) — reindex the i386 builtins only if they actually need it ────────────
    # On the pinned llvm-mingw (20260616 and 20260812 alike) the i386 archive is clean — 150 members, zero
    # duplicate names, `__alloca` in the armap — and a plain i686 link succeeds, so the workaround is
    # skipped. Keep it gated rather than
    # unconditional: re-archiving is not free of risk — doing it to the ARM64EC builtins on this same
    # toolchain DESTROYS EC symbol resolution, because it flattens the `obj.arm64ec/` member paths
    # upstream now uses to disambiguate (RESEARCH §22).
    i386_rt="$(ls ${llvmMingw}/lib/clang/*/lib/windows/libclang_rt.builtins-i386.a | head -1)"
    rt_args=()
    if [ "$(${llvmAr} t "$i386_rt" | sort | uniq -d | wc -l)" != 0 ]; then
      echo "i386 builtins have duplicate member names — reindexing for __alloca"
      mkdir -p rt386
      python3 ${reindexPy} "$i386_rt" rt386
      ( cd rt386 && ${llvmAr} rcs libclang_rt.builtins-i386.a $(cat MANIFEST) )
      rt_args=(-Wl,--start-group,"$PWD/rt386/libclang_rt.builtins-i386.a",--end-group)
    else
      echo "i386 builtins index is upstream-correct — linking without the reindex workaround"
    fi
    ${cc32} -O2 -shared -o "$out/Galaxy.dll" ${srcDir}/galaxy_stub.c galaxy32.def "''${rt_args[@]}"
  ''
