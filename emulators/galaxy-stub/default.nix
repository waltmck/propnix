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
# NOT A CRASH WORKAROUND. These stubs are offline policy. The rpcrt4 fault the real SDK hit under
# wine was an ARM64EC variadic exit-thunk defect in the compiler, fixed by the toolchain backport in
# emulators/llvm-mingw (RESEARCH §23); the real SDK DLLs load without faulting. Nothing here is
# load-bearing for stability, so do not "fix" a crash here (docs/research/galaxy-sdk-offline.md).
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
# a new title needs them. The ABI strategy + the C bodies each symbol aliases to are documented in
# `src/galaxy_stub.c` (and pops in `src/pops_stub.c`).
#
# ARCH. The stub DLLs match the GAME's arch, not the host: a game's Galaxy64.dll is x86_64, so wine's loader
# resolves the import against x86_64 (even on aarch64/ARM64EC, where the tiny stub then runs emulated — its
# cost is nil). So these are x86_64 (+ i386) PEs. BOTH hosts wire this in — see lib/default.nix and
# lib/builders/wine.nix.
#
# 32-BIT CALLERS CANNOT USE THIS. The whole design rests on one uniform vtable of zero-argument slots
# standing in for interfaces of unknown arity, which is only ABI-valid where the CALLER cleans the stack.
# i386 SDK interfaces are __thiscall (callee pops), so such a slot leaves the arguments behind and the
# caller's next `ret` executes one of them — measured on homeworld-rm
# (docs/research/galaxy-sdk-offline.md). lib/backends/wine/defaults.nix therefore refuses
# `galaxyStubDlls` on i386 titles, which use `online = false` for the offline guarantee.
# Galaxy.dll is still built: prison-architect (a 64-bit exe) binds a 32-bit copy it never loads.
#
# The GalaxyFactory / api:: exports are MSVC-mangled (64-bit uses PEAV/PEBV far-encoding, 32-bit PAV/PBV),
# aliased to the plain C bodies via a .def EXPORTS list generated below by `classify` (the 32-bit names are
# derived from the 64-bit ones by the well-defined pointer-encoding transform).
#
# TOOLCHAIN, and why there are two. The stubs are plain C targeting x86_64 + i386 Windows — nothing here
# is ARM64EC — so ANY mingw cross-compiler can build them. Which one we get depends on the host:
#   * aarch64: `llvmMingw` already exists there (the ARM64EC toolchain wine/DXVK/vkd3d need), so building
#     with it is free.
#   * x86_64: that toolchain does NOT exist — `emulators/llvm-mingw` is `llvm-mingw-arm64ec`, a prebuilt
#     pinned to the aarch64-HOSTED release and grafted with an ARM64EC exit-thunk patch whose clang build
#     links multi-GB objects. Dragging it in to produce three tiny stubs would be absurd, so the x86_64 leg
#     uses nixpkgs' ordinary cross-mingw GCC (`pkgsCross.mingwW64` / `pkgsCross.mingw32`), which is cached.
{
  lib,
  runCommand,
  # The ARM64EC toolchain: present on aarch64, null on x86_64.
  llvmMingw ? null,
  # nixpkgs cross-mingw GCCs, used when llvmMingw is absent. Derivations, not paths.
  mingwGccW64 ? null,
  mingwGcc32 ? null,
  # mcfgthreads import libs for those GCCs (their driver emits a bare -lmcfgthread).
  mingwThreads64 ? null,
  mingwThreads32 ? null,
  python3,
}:
let
  useLlvm = llvmMingw != null;
  cc64 =
    if useLlvm then
      "${llvmMingw}/bin/x86_64-w64-mingw32-clang"
    else
      "${mingwGccW64}/bin/x86_64-w64-mingw32-gcc -L${mingwThreads64}/lib";
  cc32 =
    if useLlvm then
      "${llvmMingw}/bin/i686-w64-mingw32-clang"
    else
      "${mingwGcc32}/bin/i686-w64-mingw32-gcc -L${mingwThreads32}/lib";
  llvmAr = lib.optionalString useLlvm "${llvmMingw}/bin/llvm-ar";

  # Pin the C/symbol sources to a CONTENT-ADDRESSED store path (keyed only by src/'s bytes, not the flake
  # source), so unrelated repo edits never rebuild the stub — only touching src/ does.
  srcDir = builtins.path {
    path = ./src;
    name = "galaxy-stub-src";
  };

  # A gated GUARD, not a current defect: an llvm-mingw i386 compiler-rt builtins archive with
  # duplicate member names has an index that DROPS __alloca / ___chkstk_ms (the armap bug the
  # toolchain's postFixup fixes for the x86_64/aarch64 archives), and the 32-bit CRT's
  # pseudo-relocator references __alloca, so the i686 link would fail with
  # `undefined symbol: __alloca`. Should that happen, the build reindexes a private copy (reusing the
  # toolchain's own reindex-ar.py) and links it in a group — contained to this derivation, with no
  # llvm-mingw rebuild. The pinned release's archive measures clean, so the path does not fire
  # (docs/research/llvm-mingw-toolchain.md). Pinned content-addressed like srcDir above.
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
    # what each C body (noop_void / pump_void / ret_galaxy / ret_dummy / ret_apps / ret_registrar / ret_zero) does —
    # and for the measured defects those bodies exist to avoid. ORDER MATTERS: the ProcessData and
    # ListenerRegistrar cases must precede the catch-all `*@@YAX*` / default arms below.
    classify() {
      case "$1" in
        *ResetInstance@GalaxyFactory*)               echo noop_void ;;   # void
        *CreateInstance@GalaxyFactory*|*GetInstance@GalaxyFactory*) echo ret_galaxy ;;
        *GetErrorManager@GalaxyFactory*)             echo ret_dummy ;;   # IErrorManager* (non-null)
        '?GetError@'*)                               echo ret_zero ;;    # const IError* -> null (no error)
        # ProcessData is the SDK's CALLBACK PUMP, not a no-op: it delivers the pending sign-in result that
        # a game's `GameServicesAsync` init phase blocks on. See galaxy_stub.c, defect 1.
        '?ProcessData@'*|'?ProcessGameServerData@'*)  echo pump_void ;;
        # IListenerRegistrar needs a REAL Register() so the AUTH listener can be captured for that pump.
        '?ListenerRegistrar@'*|'?GameServerListenerRegistrar@'*) echo ret_registrar ;;
        # IApps has string-valued vtable methods that must return a readable empty string, while its bool
        # method must remain false. It therefore cannot use the scalar-zero leaf fallback.
        '?Apps@'*)                                    echo ret_apps ;;
        *@@YAX*)                                     echo noop_void ;;   # void free funcs (Init/Shutdown/…)
        *)                                           echo ret_dummy ;;   # scalar-safe interface fallback
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
    # Skipped when the archive has no duplicate members (true on the pinned release). Kept gated,
    # not unconditional: re-archiving is not free of risk — doing it to the ARM64EC builtins on this
    # same toolchain DESTROYS EC symbol resolution, because it flattens the `obj.arm64ec/` member
    # paths upstream uses to disambiguate (RESEARCH §22).
    rt_args=()
    ${lib.optionalString useLlvm ''
      i386_rt="$(ls ${toString llvmMingw}/lib/clang/*/lib/windows/libclang_rt.builtins-i386.a | head -1)"
      if [ "$(${llvmAr} t "$i386_rt" | sort | uniq -d | wc -l)" != 0 ]; then
        echo "i386 builtins have duplicate member names — reindexing for __alloca"
        mkdir -p rt386
        python3 ${reindexPy} "$i386_rt" rt386
        ( cd rt386 && ${llvmAr} rcs libclang_rt.builtins-i386.a $(cat MANIFEST) )
        rt_args=(-Wl,--start-group,"$PWD/rt386/libclang_rt.builtins-i386.a",--end-group)
      else
        echo "i386 builtins index is upstream-correct — linking without the reindex workaround"
      fi
    ''}
    # NB the whole block above is llvm-mingw-specific: it guards against a BROKEN ARCHIVE INDEX in
    # that toolchain's i386 compiler-rt builtins. GCC's mingw32 has no such archive and no such bug,
    # so the x86_64 leg links straight through with an empty rt_args.
    ${cc32} -O2 -shared -o "$out/Galaxy.dll" ${srcDir}/galaxy_stub.c galaxy32.def "''${rt_args[@]}"
  ''
