# galaxy-stub — graceful no-op replacements for the GOG Galaxy SDK DLLs that some GOG games bundle.
#
# THE PROBLEM. Several GOG titles statically import GOG's Galaxy SDK (Galaxy64.dll / Galaxy.dll) and the
# older "POPS" online-services client (pops_api.dll). On startup the SDK spins up its offline network/RPC
# layer, which under wine faults with a NULL-pointer write inside builtin rpcrt4.dll (write to 0x10) — the
# process dies before it renders a frame. Reproduced on Prison Architect (Prison Architect64.exe):
#   wine: Unhandled page fault on write access to 0000000000000010 ... in rpcrt4.
#
# WHY A STUB (and why it can't be an empty DLL). The games *statically* import specific symbols, so the DLL
# must export exactly those, and the SDK "init" path must return cleanly without doing any RPC/socket work.
# We build tiny native PE DLLs that export the imported symbols and do nothing but hand back benign,
# "offline / not-signed-in" values. No RPC is ever attempted, so the rpcrt4 crash cannot happen.
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

    # ── 32-bit stub (Galaxy.dll) — needs the reindexed i386 builtins for __alloca (see note above) ──
    i386_rt="$(ls ${llvmMingw}/lib/clang/*/lib/windows/libclang_rt.builtins-i386.a | head -1)"
    mkdir -p rt386
    python3 ${reindexPy} "$i386_rt" rt386
    ( cd rt386 && ${llvmAr} rcs libclang_rt.builtins-i386.a $(cat MANIFEST) )
    ${cc32} -O2 -shared -o "$out/Galaxy.dll" ${srcDir}/galaxy_stub.c galaxy32.def \
      -Wl,--start-group,"$PWD/rt386/libclang_rt.builtins-i386.a",--end-group
  ''
