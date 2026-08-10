# llvm-mingw — prebuilt clang/LLVM cross toolchain (mstorsjo/llvm-mingw) that can target
# arm64ec-w64-mingw32. This is the one piece nixpkgs lacks: no arm64ec cross target exists
# in nixpkgs, and building the ARM64EC runtime from source is a project in itself. Hangover
# uses this same toolchain. We fetch the aarch64-Linux-hosted release and autoPatchelf it for
# NixOS, then use it to build hybrid (ARM64X) wine and FEX's ARM64EC emulator DLL.
#
# See ../fex-portable for the Linux FEX fork; this dir is the Windows/x86_64 path.
{
  nixpkgs ? builtins.getFlake "flake:nixpkgs",
  pkgs ? import nixpkgs { system = "aarch64-linux"; config.allowUnfree = true; },
}:
pkgs.stdenv.mkDerivation rec {
  pname = "llvm-mingw-arm64ec";
  version = "20260616";

  src = pkgs.fetchurl {
    url = "https://github.com/mstorsjo/llvm-mingw/releases/download/${version}/llvm-mingw-${version}-ucrt-ubuntu-22.04-aarch64.tar.xz";
    sha256 = "0aqhfvfi669rakkflgx5j59wfsp6n2jk79mfx8xjlgrxv4sx3rg7";
  };

  # The clang/lld/llvm binaries are Ubuntu ELF executables; patch their interpreter and
  # RPATH for NixOS. The Windows PE artifacts (arm64ec DLLs/objects) are skipped by
  # autoPatchelf automatically.
  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.python3 # re-index the ARM64EC builtins archives (postFixup below)
  ];
  buildInputs = [
    (pkgs.stdenv.cc.cc.lib) # libstdc++/libgcc_s
    pkgs.zlib
    pkgs.zstd
    pkgs.libxml2
    pkgs.ncurses
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a ./* "$out/"
    runHook postInstall
  '';

  # Some bundled binaries reference libs we don't provide (rare tools); don't fail the build
  # over those — the compilers/linkers we need are covered by buildInputs.
  autoPatchelfIgnoreMissingDeps = true;

  # ARM64EC / x86_64 linking fix. The shipped compiler-rt builtins archives
  # (lib/clang/*/lib/windows/libclang_rt.builtins-{aarch64,x86_64}.a) are ARM64X *hybrid* archives
  # whose object members appear under DUPLICATE names. llvm-ar/llvm-ranlib then build a symbol index
  # that DROPS the ARM64EC ('#'-mangled) symbols — notably `#__chkstk_arm64ec` — and the x86_64
  # `___chkstk_ms`, so lld fails with `undefined symbol: #__chkstk_arm64ec` when linking any EC C/C++
  # DLL (e.g. DXVK) and `___chkstk_ms` for x86_64 (RESEARCH §22). Fix: rebuild each archive's index over
  # de-duplicated member names (reindex-ar.py) so those symbols land in the map. Runs in postFixup so it
  # executes AFTER autoPatchelfHook has patched llvm-ar's interpreter/RPATH (it is a real ELF we run here).
  postFixup = ''
    # autoPatchelfHook lives in postFixupHooks, which run AFTER this $postFixup body (runHook runs the
    # $postFixup variable first), so llvm-ar's ELF interpreter isn't patched yet here. Patch now, then
    # re-index (the second autoPatchelf from the hook is idempotent).
    autoPatchelf "$out"
    for _a in "$out"/lib/clang/*/lib/windows/libclang_rt.builtins-aarch64.a \
              "$out"/lib/clang/*/lib/windows/libclang_rt.builtins-x86_64.a; do
      [ -e "$_a" ] || continue
      _tmp="$(mktemp -d)"
      python3 ${./reindex-ar.py} "$_a" "$_tmp"
      ( cd "$_tmp" && "$out/bin/llvm-ar" rcs "$_a.new" $(cat MANIFEST) )
      mv -f "$_a.new" "$_a"
      rm -rf "$_tmp"
      echo "reindexed $(basename "$_a"): $("$out/bin/llvm-nm" --print-armap "$_a" 2>/dev/null | grep -ci chkstk) chkstk syms in armap"
    done
  '';

  passthru = {
    # Convenience: the ARM64EC C/C++ drivers used to build hybrid wine + FEX EC.
    ccArm64ec = "arm64ec-w64-mingw32-clang";
    cxxArm64ec = "arm64ec-w64-mingw32-clang++";
    ccAarch64 = "aarch64-w64-mingw32-clang";
  };

  meta.description = "Prebuilt llvm-mingw toolchain with arm64ec-w64-mingw32 support (autoPatchelf'd for NixOS)";
}
