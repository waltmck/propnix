# vkd3d-proton-llvm-mingw.nix — vkd3d-proton (Direct3D 12 → Vulkan) built as NATIVE PE DLLs for an ARM
# Windows target with llvm-mingw: ARM64EC (`winPkgs.aarch64ec-windows.vkd3d`) or plain ARM64
# (`winPkgs.aarch64-windows.vkd3d`); the D3D12 sibling of dxvk-llvm-mingw.nix, mirroring it exactly — same
# toolchain record, same meson cross-file, same --wrap-mode nodownload / patchShebangs / dontStrip
# discipline. Building the D3D12→Vulkan translation native (only the game stays under FEX on the EC
# stack) is the Hangover-recommended path and the enabler for D3D12 titles (PLAN2 M3).
#
# ARM64EC support is ALREADY UPSTREAM in the pinned 2.14.1 (nixpkgs `vkd3d-proton.src`); NO source patch is
# needed for EC correctness. Verified against this toolchain (arm64ec-w64-mingw32-clang, LLVM 22):
#   * arm64ec clang predefines __x86_64__ / __amd64__ / __arm64ec__ but NOT __aarch64__, _M_ARM64EC or
#     __SSE2__. Every x86-only path is guarded and correctly falls back:
#       - include/private/vkd3d_common.h  : rdtsc is `defined(__x86_64__) && !defined(__arm64ec__)` → uses
#                                           clock_gettime on EC (upstream already excludes __arm64ec__).
#       - include/private/copy_utils.h    : SSE non-temporal copies are `#ifdef __SSE2__` → plain memcpy.
#       - include/private/vkd3d_spinlock.h: `_mm_pause()` is `#ifdef __SSE2__` → empty pause on EC (a
#                                           missing spin hint only; not a correctness or build issue).
#   * meson.build appends `-msse -msse2` via get_supported_arguments(); arm64ec clang REJECTS `-msse2`
#     ("unsupported option"), so meson drops both and __SSE2__ stays undefined — the broken libc++22
#     <emmintrin.h>/<mmintrin.h> path is never reached. Nothing to patch.
#   * meson only special-cases cpu_family=='x86' (32-bit stdcall fixup / libatomic); our cross-file is
#     cpu_family='aarch64', so that branch is inert, exactly as in DXVK.
# Plain aarch64 clang defines __aarch64__ and none of the x86 macros, so those paths never arise there.
# The toolchain's ARM64EC linking is made to work by the builtins-archive re-index baked into
# ./llvm-mingw (RESEARCH §22) — same as DXVK.
#
#   nix build .#vkd3d   # -> $out/{d3d12,d3d12core}.dll (the host's default target)
{
  stdenv,
  writeText,
  meson,
  ninja,
  pkg-config,
  glslang,
  python3,
  wine64Packages,
  vkd3d-proton,
  toolchain, # the target's lib/win-toolchain.nix record (the scope injects it)
  target,
}:
let
  # meson cross-file for the target via llvm-mingw — IDENTICAL to dxvk-llvm-mingw.nix. cpu_family is
  # 'aarch64' for both ARM targets (meson has no 'arm64ec'; this also keeps vkd3d's 32-bit x86 branch off).
  # No -resource-dir override is needed because the EC builtins archive is fixed in place inside llvm-mingw.
  crossFile = writeText "vkd3d-proton-${target}-cross.txt" ''
    [binaries]
    c       = '${toolchain.cc}'
    cpp     = '${toolchain.cxx}'
    ar      = '${toolchain.ar}'
    strip   = '${toolchain.strip}'
    windres = '${toolchain.windres}'
    dlltool = '${toolchain.dlltool}'

    [properties]
    needs_exe_wrapper = true

    [host_machine]
    system     = 'windows'
    cpu_family = 'aarch64'
    cpu        = 'aarch64'
    endian     = 'little'
  '';
in
stdenv.mkDerivation {
  pname = "vkd3d-proton-${target}";
  version = "2.14.1";
  src = vkd3d-proton.src; # pinned vkd3d-proton 2.14.1 (fetchSubmodules: bundles dxil-spirv +
  # khronos/{Vulkan,SPIRV}-Headers, so nothing is downloaded at build time)

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    glslang # glslang/glslangValidator — compiles vkd3d's shaders (runs native on the build host)
    python3
    # widl (Wine's IDL compiler) generates C headers from include/*.idl — meson: find_program('widl', ...).
    # It runs NATIVE on the build host. The default `pkgs.wine` won't even evaluate on aarch64 (it pulls the
    # i686 package set); wine64Packages.minimal does, ships bin/widl, and is available from cache.
    wine64Packages.minimal
  ]
  ++ toolchain.nativeBuildInputs;

  # Only build-metadata plumbing — no arm64ec/source fix is required (see header). vkd3d embeds a build id
  # via meson vcs_tag(); fetchFromGitHub stripped .git but saved the describe output to .nixpkgs-auxfiles/,
  # so inject those as the vcs_tag fallbacks (identical to nixpkgs' own vkd3d-proton). Without this meson
  # would silently fall back to the plain project version — harmless, but this keeps the real build id.
  postPatch = ''
    substituteInPlace meson.build \
      --replace-fail "vkd3d_build = vcs_tag(" \
                     "vkd3d_build = vcs_tag( fallback : '$(cat .nixpkgs-auxfiles/vkd3d_build)'," \
      --replace-fail "vkd3d_version = vcs_tag(" \
                     "vkd3d_version = vcs_tag( fallback : '$(cat .nixpkgs-auxfiles/vkd3d_version)',"
    # Bundled subprojects (dxil-spirv) ship build-time helpers with `#!/usr/bin/env python3`, which has no
    # interpreter in the sandbox — point them at the build python3. (Same as DXVK.)
    patchShebangs .
  '';

  configurePhase = ''
    runHook preConfigure
    meson setup build \
      --cross-file ${crossFile} \
      --buildtype release -Db_ndebug=if-release \
      --wrap-mode nodownload
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C build
    runHook postBuild
  '';

  # vkd3d-proton ships ONLY d3d12.dll + d3d12core.dll. It links dxgi as an import lib (libdxgi.a stub) but
  # does NOT build a dxgi.dll — at runtime it uses DXVK's dxgi.dll (see integration note / dxvk-arm64ec.nix).
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    for _d in d3d12 d3d12core; do
      _f="$(find build -name "$_d.dll" -print -quit)"
      if [ -n "$_f" ]; then cp "$_f" "$out/$_d.dll"; else echo "WARN: $_d.dll not built"; fi
    done
    ${toolchain.checkPe} "$out"/*.dll
    runHook postInstall
  '';

  # PE outputs: nix's ELF strip won't touch them, but be explicit — never risk dropping the ARM64X
  # load-config/CHPE sections (same rationale as dxvk-llvm-mingw.nix / wine-hangover's dontStrip).
  dontStrip = true;

  meta.description = "vkd3d-proton (D3D12 → Vulkan) as native ${target} PE DLLs (llvm-mingw)";
}
