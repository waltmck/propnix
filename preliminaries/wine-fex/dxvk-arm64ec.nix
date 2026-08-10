# dxvk-arm64ec.nix — DXVK (Direct3D 9/10/11 → Vulkan) built as NATIVE ARM64EC PE DLLs.
#
# Why: wine's builtin wined3d Vulkan renderer serializes presentation on the render thread and collapses
# to ~12 fps on this stack (RESEARCH §22); DXVK's async presenter fixes it (Hollow Knight → 60 fps,
# measured). Building DXVK as ARM64EC means the whole D3D→Vulkan translation runs NATIVE (only the game
# stays under FEX), matching the Hangover-recommended path — the right end-state and the enabler for
# D3D11-heavy titles (BG3, PLAN2 M3).
#
# No DXVK source patch is needed for ARM64EC itself — upstream merged EC support (PR #3900) in v2.4, and
# it is present in the pinned 2.7.1 (nixpkgs `dxvk_2.src`). The ONE workaround below is an unrelated LLVM
# 22 libc++ regression. The toolchain's ARM64EC linking is made to work by the builtins-archive re-index
# baked into ./llvm-mingw.nix (RESEARCH §22).
#
#   nix-build wine-fex/dxvk-arm64ec.nix   # -> $out/{d3d11,d3d10core,dxgi,d3d9,d3d8}.dll (all 0xA641)
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs {
    system = "aarch64-linux";
    config.allowUnfree = true;
  },
  llvmMingw ? import ./llvm-mingw.nix { inherit nixpkgs pkgs; },
}:
let
  # meson cross-file targeting arm64ec via llvm-mingw. cpu_family MUST be 'aarch64' (meson has no
  # 'arm64ec'; this also keeps DXVK's 32-bit x86 stdcall branch off). No -resource-dir override is needed
  # because the EC builtins archive is fixed in place inside llvmMingw (llvm-mingw.nix postFixup).
  crossFile = pkgs.writeText "dxvk-arm64ec-cross.txt" ''
    [binaries]
    c       = '${llvmMingw}/bin/arm64ec-w64-mingw32-clang'
    cpp     = '${llvmMingw}/bin/arm64ec-w64-mingw32-clang++'
    ar      = '${llvmMingw}/bin/llvm-ar'
    strip   = '${llvmMingw}/bin/arm64ec-w64-mingw32-strip'
    windres = '${llvmMingw}/bin/arm64ec-w64-mingw32-windres'
    dlltool = '${llvmMingw}/bin/arm64ec-w64-mingw32-dlltool'

    [properties]
    needs_exe_wrapper = true

    [host_machine]
    system     = 'windows'
    cpu_family = 'aarch64'
    cpu        = 'aarch64'
    endian     = 'little'
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "dxvk-arm64ec";
  version = "2.7.1";
  src = pkgs.dxvk_2.src; # pinned DXVK 2.7.1 (same source nixpkgs uses for the x86 PE build)

  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.glslang # glslangValidator — compiles DXVK's shaders (runs native on the build host)
    pkgs.python3
    llvmMingw
  ];

  # LLVM 22 libc++ regression: an empty piecewise key-tuple in an unordered_map emplace trips
  # __try_key_extraction.h. Pass the (default-constructed) key explicitly — semantically identical.
  # Target-independent; unrelated to ARM64EC. Drop if pinning an llvm-mingw whose libc++ is ≤ LLVM 21.
  postPatch = ''
    substituteInPlace src/dxvk/dxvk_pipemanager.cpp \
      --replace-fail 'std::tuple(),' 'std::tuple(key),'
    # Perf: arm64ec clang defines neither __aarch64__ nor _M_ARM64EC, so DXVK detects NEITHER x86 nor
    # ARM64 and falls back to a HINTLESS busy-loop in its spinlocks (sync_spinlock.h) instead of the ARM64
    # `yield`. ARM64EC *is* ARM64 codegen, so take the ARM64 branch — DXVK's spin loops then `yield`
    # (lower CPU under contention) and use the ARM64 bit-intrinsics. (RESEARCH §22.)
    substituteInPlace src/util/util_bit.h \
      --replace-fail '#elif defined(__aarch64__) || defined(_M_ARM64) || defined(_M_ARM64EC)' \
                     '#elif defined(__aarch64__) || defined(_M_ARM64) || defined(_M_ARM64EC) || defined(__arm64ec__)'
    # Bundled subprojects (e.g. libdisplay-info) ship build-time python tools with `#!/usr/bin/env
    # python3`, which has no interpreter in the sandbox — point them at the build python3.
    patchShebangs .
  '';

  configurePhase = ''
    runHook preConfigure
    meson setup build.ec \
      --cross-file ${crossFile} \
      --buildtype release -Db_ndebug=if-release \
      --wrap-mode nodownload
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C build.ec
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    for _d in d3d8 d3d9 d3d10core d3d11 dxgi; do
      _f="$(find build.ec -name "$_d.dll" -print -quit)"
      if [ -n "$_f" ]; then cp "$_f" "$out/$_d.dll"; else echo "WARN: $_d.dll not built"; fi
    done
    runHook postInstall
  '';

  # PE outputs: nix's ELF strip won't touch them, but be explicit — never risk dropping the ARM64X
  # load-config/CHPE sections (same rationale as wine-hangover's dontStrip).
  dontStrip = true;

  meta.description = "DXVK (D3D9/10/11 → Vulkan) as native ARM64EC PE DLLs (llvm-mingw), for wine+FEX on aarch64";
}
