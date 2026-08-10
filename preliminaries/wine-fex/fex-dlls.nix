# FEX's Windows emulator DLLs, built FROM SOURCE. WINE loads these to run foreign-architecture PE code
# under an ARM64 host:
#   * libarm64ecfex.dll  — x86_64 guests. FEX-Emu/FEX @ FEX-2607, arm64ec triple.
#                          IMAGE_FILE_MACHINE_ARM64EC (0xA641).
#   * libwow64fex.dll     — i386 guests. FEX-Emu/FEX @ FEX-2607, aarch64 triple.
#                          IMAGE_FILE_MACHINE_ARM64 (0xAA64) — see note below.
#   * wowbox64.dll        — i386 guests (box64's emulator, the WOW64 default; FEX's libwow64fex.dll is the
#                          alternative). Built from AndreRH/box64 branch wow64.
#                          IMAGE_FILE_MACHINE_ARM64 (0xAA64).
#
# MACHINE-TYPE NOTE (important — libwow64fex.dll is NOT i386):
#   The WOW64 x86-on-ARM64 CPU emulator is itself a *native ARM64* PE that the ARM64 wine/ntdll loads
#   to JIT i386 guest code (the analogue of Windows' xtajit.dll). The "i386" in its name refers to the
#   GUEST it emulates, not the DLL's own machine type. Only libarm64ecfex.dll is ARM64EC (0xA641);
#   libwow64fex.dll and wowbox64.dll are both COFF-ARM64 (0xAA64). (Any claim that libwow64fex.dll should
#   be i386/0x14c is mistaken.)
#
# WHY libarm64ecfex + libwow64fex come from FEX and wowbox64 comes from box64:
#   libarm64ecfex.dll and libwow64fex.dll are FEX CPU emulators (FEX-Emu/FEX, Source/Windows/{ARM64EC,
#   WOW64}). wowbox64.dll is an ENTIRELY SEPARATE PROJECT — box64's WOW64 build (AndreRH/box64, branch
#   wow64) — which Hangover ships as the default i386 emulator. It cannot be "built from FEX source"; it
#   is built here from box64 source so $out ships all three emulators. It is pinned to the box64 commit
#   Hangover 11.9 uses (7eeb5016).
#
# WINDOWS target, distinct from ../fex-portable:
#   * ../fex-portable  = FEX built as a LINUX aarch64 binary that JITs x86_64/i386 *Linux* ELFs (a
#     from-source fork with the 16K host-page patch; its bundled jemalloc is the thing that had to be
#     fixed). Output: bin/FEX{,Interpreter,Server}.
#   * this file        = FEX + box64 cross-compiled with llvm-mingw to *Windows* PE DLLs (arm64ec /
#     aarch64 triples) that run under wine. The Windows FEX build does NOT compile jemalloc_glibc (gated
#     off for MINGW: ENABLE_JEMALLOC_GLIBC_ALLOC:=FALSE, ENABLE_FEX_ALLOCATOR:=TRUE → rpmalloc only), so
#     none of the 16K jemalloc walls apply here — memory/loader are wine's responsibility, FEX/box64
#     only JIT blocks. (A 16K-page runtime re-test of these DLLs happens at integration.)
#
# Build/verify:
#   nix-build wine-fex/fex-dlls.nix   # -> $out/{libarm64ecfex.dll,libwow64fex.dll,wowbox64.dll}
#   llvm-readobj --file-headers $out/libarm64ecfex.dll | grep Machine   # ARM64EC (0xA641)
#   llvm-readobj --file-headers $out/libwow64fex.dll   | grep Machine   # ARM64   (0xAA64)
#   llvm-readobj --file-headers $out/wowbox64.dll      | grep Machine   # ARM64   (0xAA64)
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
  llvmMingw ? import ./llvm-mingw.nix { inherit nixpkgs pkgs; },
}:
let
  # --- FEX-Emu/FEX (UPSTREAM) tag FEX-2607 ---------------------------------------------------------
  # The ARM64EC/WOW64 Windows build lives in upstream FEX as of the arm64ec merge: Source/Windows/
  # {ARM64EC,WOW64} + Data/CMake/toolchain_mingw.cmake + the CI at .github/workflows/mingw_build.yml.
  # AndreRH/FEX (branch arm64ec) is only Hangover's PIN (submodule) of upstream FEX, +2 trivial commits vs
  # upstream main (ahead 2 / behind 20): a debug print ("starting FEX based libarm64ecfex.dll") and a
  # private-header struct rename (IMAGE_LOAD_CONFIG_CODE_INTEGRITY). NEITHER is functional arm64ec code, so
  # building the newer upstream FEX-2607 tag (which also has the x87/THP/memory wins) needs no fork.
  rev = "FEX-2607";
  revHash = "1cc4b93e7a71c883ec021b71359f136394dc1f3c";

  # --- box64 (AndreRH/box64, branch wow64) → wowbox64.dll ------------------------------------------
  # Pinned to the exact commit Hangover 11.9 bundles (its box64 submodule at tag hangover-11.9). box64 has
  # NO git submodules (external/musl is vendored in-tree), so fetchSubmodules is unnecessary.
  box64Rev = "7eeb5016493dab4e143d53da50dd47bfb44a9509";

  # wowbox64 is a CMake SUPERBUILD: the outer box64 project (native aarch64 compiler) computes the
  # dynarec source lists (DYNAREC_PASS/ASM, INTERPRETER) and drives an ExternalProject that
  # cross-compiles wowbox64.dll as a native-ARM64 PE via aarch64-w64-mingw32-* (wine/toolchain_mingw.
  # cmake). We must therefore drive the OUTER project and build only the `wowbox64` target — the FEX
  # toolchain file cannot build box64. This is exactly Hangover's build path.
  wowbox64 = pkgs.stdenv.mkDerivation {
    pname = "wowbox64";
    version = "box64-hangover-11.9";

    src = pkgs.fetchFromGitHub {
      owner = "AndreRH";
      repo = "box64";
      rev = box64Rev;
      hash = "sha256-XESbBWXSj2vrwVaHsVIU+m/Ru/hOXcx9ywrA2WqXG/o=";
    };

    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
      pkgs.python3 # functions_list (wrapper table) + gen_dynacache_hashes.py + override_wine_builtin.py
      pkgs.git # generate_git_head_target runs `git rev-parse` (no .git here → empty GITREV, harmless)
      llvmMingw # aarch64-w64-mingw32-{clang,as,dlltool} for the inner (PE) ExternalProject build
    ];

    # Superbuild driven by hand: outer configure with the NATIVE compiler (stdenv `cc`, which llvm-mingw
    # does NOT shadow — it ships no bare cc/gcc), then build only the `wowbox64` ExternalProject target
    # (its inner build cross-compiles to a PE). Building `wowbox64` does NOT build the native box64
    # binary; it pulls in only generate_git_head_target → functions_list and the inner PE build.
    dontUseCmakeConfigure = true;

    # PE ARM64 output — never let nix's ELF strip near it (no-op on PE, but keep CHPE/load-config safe).
    dontStrip = true;

    buildPhase = ''
      runHook preBuild
      echo "=== configuring box64 (WOW64 superbuild, native outer) ==="
      cmake -S . -B build_pe -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DARM_DYNAREC=ON \
        -DWOW64=ON \
        -DCMAKE_C_COMPILER=cc
      echo "=== building wowbox64 (inner PE cross-build via aarch64-w64-mingw32) ==="
      ninja -C build_pe wowbox64
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      # ExternalProject puts it at build_pe/wowbox64-prefix/src/wowbox64-build/wowbox64.dll; `find` to
      # stay robust to CMAKE_RUNTIME_OUTPUT_DIRECTORY moving it under .../bin/.
      _w="$(find build_pe -name wowbox64.dll -print -quit)"
      [ -n "$_w" ] || { echo "ERROR: wowbox64.dll not built"; exit 1; }
      install -m444 "$_w" "$out/wowbox64.dll"
      echo "== wowbox64.dll machine type =="
      "${llvmMingw}/bin/llvm-readobj" --file-headers "$out/wowbox64.dll" | grep -i Machine || true
      runHook postInstall
    '';

    meta.description = "box64 i386 CPU emulator PE DLL (wowbox64.dll, ARM64) for WOW64-on-ARM64 wine, from AndreRH/box64 @ Hangover 11.9 pin";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "fex-wine-dlls";
  version = "FEX-2607";

  # fetchSubmodules = true mirrors FEX CI's `git submodule update --init` (setup-env action). For this
  # exact config (BUILD_TESTING=False, ENABLE_ZYDIS default off, VIXL sim/disasm off, jemalloc off for
  # MINGW) only rpmalloc/fmt/xxhash/unordered_dense/range-v3 (+ in-tree tiny-json/SoftFloat-3e/cephes)
  # are actually compiled; the rest (vixl, zydis, Catch2, tracy, Vulkan-Headers, *-tests-bins, jemalloc)
  # are fetched-but-unused. Fetching all is simplest and faithful; hash pins the whole set.
  src = pkgs.fetchFromGitHub {
    owner = "FEX-Emu";
    repo = "FEX";
    rev = rev;
    fetchSubmodules = true;
    hash = "sha256-9nDivYerWJfL1Nioeo9rgX44FH7JoriSY7xQe4QiDOA=";
  };

  nativeBuildInputs = [
    pkgs.cmake
    pkgs.ninja
    pkgs.python3 # find_package(Python 3.9 REQUIRED) — configure-time only
    pkgs.coreutils # patch_library_wine() runs `dd` as a POST_BUILD step on each DLL
    llvmMingw # puts arm64ec-/aarch64-w64-mingw32-{clang,clang++,ar,dlltool,windres} on PATH
  ];

  # We drive cmake twice by hand (one build tree per MINGW_TRIPLE), so suppress the cmake setup hook's
  # single-tree auto-configure.
  dontUseCmakeConfigure = true;

  # PE ARM64X outputs. Nix's ELF strip won't touch PE, but be explicit — never risk dropping the ARM64X
  # load-config / CHPE sections (same rationale as wine-hangover / dxvk-arm64ec dontStrip).
  dontStrip = true;

  # Shared cmake flags. We reuse FEX's own in-tree toolchain file (Data/CMake/toolchain_mingw.cmake) — it
  # is authoritative and carries the load-bearing linker flags (--file-alignment=4096 so debug/section
  # layout is correct, /mllvm:-align-loops=1 to dodge LLVM bug 47432, and -static -static-libgcc
  # -static-libstdc++ so the DLL needs no mingw runtime). It resolves the ${MINGW_TRIPLE}-* tools from
  # PATH (llvmMingw). Passing OVERRIDE_VERSION/HASH avoids find_package(Git) (there is no .git in the
  # Nix source) and stamps the real version instead of "FEX-Unknown". TUNE_CPU=none disables the
  # native -mcpu probe (Scripts/aarch64_fit_native.py against /proc/cpuinfo — wrong for a cross build /
  # unavailable in the sandbox) and is also the documented fix for spurious `.seh directives` errors.
  commonFlags = [
    "-G Ninja"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DENABLE_LTO=False"
    "-DBUILD_TESTING=False"
    "-DTUNE_CPU=none"
    "-DOVERRIDE_VERSION=${rev}"
    "-DOVERRIDE_HASH=${revHash}"
  ];

  buildPhase = ''
    runHook preBuild

    tc="$PWD/Data/CMake/toolchain_mingw.cmake"
    common="$commonFlags -DCMAKE_TOOLCHAIN_FILE=$tc"

    echo "=== configuring ARM64EC (x86_64 emulator -> libarm64ecfex.dll) ==="
    cmake -S . -B build_ec $common -DMINGW_TRIPLE=arm64ec-w64-mingw32
    echo "=== building arm64ecfex ==="
    ninja -C build_ec arm64ecfex

    echo "=== configuring aarch64/WOW64 (i386 emulator -> libwow64fex.dll, native ARM64 PE) ==="
    cmake -S . -B build_wow64 $common -DMINGW_TRIPLE=aarch64-w64-mingw32
    echo "=== building wow64fex ==="
    ninja -C build_wow64 wow64fex

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    _ec="$(find build_ec -name libarm64ecfex.dll -print -quit)"
    _wow="$(find build_wow64 -name libwow64fex.dll -print -quit)"
    [ -n "$_ec" ]  || { echo "ERROR: libarm64ecfex.dll not built"; exit 1; }
    [ -n "$_wow" ] || { echo "ERROR: libwow64fex.dll not built"; exit 1; }
    install -m444 "$_ec"  "$out/libarm64ecfex.dll"
    install -m444 "$_wow" "$out/libwow64fex.dll"

    # wowbox64.dll (box64, separate derivation above) — copied in so $out ships all three emulators.
    install -m444 "${wowbox64}/wowbox64.dll" "$out/wowbox64.dll"

    # Sanity: assert the PE machine types (0xA641 / 0xAA64 / 0xAA64).
    echo "== machine types =="
    for _d in libarm64ecfex.dll libwow64fex.dll wowbox64.dll; do
      printf '%s: ' "$_d"
      "${llvmMingw}/bin/llvm-readobj" --file-headers "$out/$_d" | grep -i Machine || true
    done
    runHook postInstall
  '';

  passthru = {
    amd64Emulator = "libarm64ecfex.dll"; # x86_64 guests (ARM64EC 0xA641)
    x86Emulator = "libwow64fex.dll"; # i386 guests, FEX (native ARM64 0xAA64)
    x86EmulatorBox64 = "wowbox64.dll"; # i386 guests, box64 default (native ARM64 0xAA64)
    inherit rev revHash box64Rev;
    inherit wowbox64; # the box64 sub-derivation, exposed for debugging/reuse
  };

  meta.description = "FEX x86_64/i386 + box64 i386 emulator DLLs for WINE-on-ARM64, built from source (FEX-2607 + box64 Hangover-11.9 pin)";
}
