# llvm-mingw — prebuilt clang/LLVM cross toolchain (mstorsjo/llvm-mingw) that can target
# arm64ec-w64-mingw32. We fetch the aarch64-Linux-hosted release and autoPatchelf it for NixOS.
# Hangover uses this same toolchain.
#
# THIS IS THE UNPATCHED BASE. Nothing consumes it directly: `llvmMingw` in lib/default.nix is
# ./patched-22.nix, which grafts a clang built from the same commit WITH llvm/llvm-project#190933 (the
# ARM64EC variadic exit-thunk fix) onto this tree. That thunk bug corrupts every `[out]` context handle —
# i.e. every Windows installer that registers a service (RESEARCH §23) — and the only released toolchain
# carrying the fix is 20260812 = clang 23.1.0-rc3, whose libc++ churn costs far more than the fix is
# worth. Hence: stable base here, one backported patch there. See patched-22.nix for that whole argument.
#
# WHY WE PACKAGE IT WHEN NIXPKGS ALSO HAS ONE. nixpkgs ships mstorsjo's toolchain too (as an internal
# input of `wineWow64Packages`) and its arm64ec driver works fine, but we need to control the pin (so the
# graft matches commit-for-commit) and we need the `reindex-ar.py` fix below. Every arm64ec consumer
# resolves the patched wrapper: wine (see wine-hangover/default.nix, which substitutes it into nixpkgs'
# nativeBuildInputs), FEX's emulator DLLs, native-EC DXVK and vkd3d-proton, and galaxy-stub.
#
# The `reindex-ar.py` fix below is ACTIVE on this pin, which ships the duplicate member names; it
# self-disables on releases where upstream fixed the archive layout (20260812 onwards). `dontStrip` is
# what keeps that detection honest — see the comments on each.
{
  stdenv,
  fetchurl,
  autoPatchelfHook,
  python3,
  zlib,
  zstd,
  libxml2,
  ncurses,

  # Overridable, so a newer upstream release can be evaluated without disturbing the pin everything
  # builds against.
  version ? "20260616",
  sha256 ? "0aqhfvfi669rakkflgx5j59wfsp6n2jk79mfx8xjlgrxv4sx3rg7",
}:
stdenv.mkDerivation rec {
  pname = "llvm-mingw-arm64ec";
  # 20260616 = clang 22.1.8 (llvm-project ca7933e47d3a). The last STABLE release before the
  # 23.x line, and the commit ./patched-22.nix builds from — they must match, or the grafted
  # clang and the libc++/compiler-rt kept from this tree disagree. Note the patched thunk
  # emits #__chkstk_arm64ec, so the builtins archive's symbol index has to be intact for WINE
  # now, not just for DXVK/vkd3d — which is what the reindex + `dontStrip` below protect.
  inherit version;

  src = fetchurl {
    url = "https://github.com/mstorsjo/llvm-mingw/releases/download/${version}/llvm-mingw-${version}-ucrt-ubuntu-22.04-aarch64.tar.xz";
    inherit sha256;
  };

  # The clang/lld/llvm binaries are Ubuntu ELF executables; patch their interpreter and
  # RPATH for NixOS. The Windows PE artifacts (arm64ec DLLs/objects) are skipped by
  # autoPatchelf automatically.
  nativeBuildInputs = [
    autoPatchelfHook
    python3 # re-index the ARM64EC builtins archives (postFixup below)
  ];
  buildInputs = [
    stdenv.cc.cc.lib # libstdc++/libgcc_s
    zlib
    zstd
    libxml2
    ncurses
  ];

  dontConfigure = true;
  dontBuild = true;

  # MUST NOT STRIP — stripping silently corrupts the ARM64EC builtins archives.
  #
  # nixpkgs' fixupPhase strips before it runs postFixup, and `strip` on a static archive rewrites it
  # while FLATTENING member names to basenames. Upstream (20260812) disambiguates the ARM64EC objects
  # purely by path — `chkstk.S.obj` vs `obj.arm64ec/chkstk.S.obj` — so stripping collapses all 290 EC
  # members onto their ARM64 namesakes and re-creates exactly the duplicate-name collision that drops
  # `#__chkstk_arm64ec` from the symbol index. Every arm64ec link then fails with
  # `undefined symbol: #__chkstk_arm64ec (EC symbol)`; meson reports it as "library 'd3d9' not found",
  # because find_library is a link test. The raw tarball links fine, which is what localises it to us.
  # nixpkgs' own llvm-mingw sets this for the same reason. Nothing here is ours to strip anyway: it is a
  # prebuilt release, and the size win does not justify breaking the toolchain.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a ./* "$out/"
    runHook postInstall
  '';

  # Some bundled binaries reference libs we don't provide (rare tools); don't fail the build
  # over those — the compilers/linkers we need are covered by buildInputs.
  autoPatchelfIgnoreMissingDeps = true;

  # ARM64EC / x86_64 linking fix — SELF-DISABLING, and that matters.
  #
  # Up to and including llvm-mingw 20260616 the shipped compiler-rt builtins archives
  # (lib/clang/*/lib/windows/libclang_rt.builtins-{aarch64,x86_64}.a) listed their ARM64 and ARM64EC
  # objects under the SAME member name. llvm-ar/llvm-ranlib then built a symbol index that DROPPED the
  # ARM64EC ('#'-mangled) symbols — notably `#__chkstk_arm64ec`, and x86_64's `___chkstk_ms` — so lld
  # failed with `undefined symbol: #__chkstk_arm64ec` when linking any EC C/C++ DLL (DXVK, vkd3d,
  # galaxy-stub; RESEARCH §22). The workaround rebuilt each index over de-duplicated member names.
  #
  # 20260812 fixes it upstream, by giving the EC objects a distinct PATH instead of a duplicate name:
  #     chkstk.S.obj   and   obj.arm64ec/chkstk.S.obj
  # Nothing collides, the index keeps `#__chkstk_arm64ec`, and the archive links as shipped. Running the
  # old workaround on top of that is WORSE THAN USELESS: flattening `obj.arm64ec/chkstk.S.obj` to
  # `0001_chkstk.S.obj` loses whatever lld keys EC resolution on, and every arm64ec link then fails on
  # `#__chkstk_arm64ec` again — including meson's `find_library` probes, which surface it as the
  # misleading "library 'd3d9' not found".
  #
  # So: only reindex an archive that ACTUALLY has duplicate member names. On a fixed toolchain this is a
  # no-op that says so in the log; on an older pin it still repairs the index. Runs in postFixup because
  # it executes llvm-ar, which autoPatchelfHook must have patched first.
  postFixup = ''
    # autoPatchelfHook lives in postFixupHooks, which run AFTER this $postFixup body (runHook runs the
    # $postFixup variable first), so llvm-ar's ELF interpreter isn't patched yet here. Patch now, then
    # re-index (the second autoPatchelf from the hook is idempotent).
    autoPatchelf "$out"
    for _a in "$out"/lib/clang/*/lib/windows/libclang_rt.builtins-aarch64.a \
              "$out"/lib/clang/*/lib/windows/libclang_rt.builtins-x86_64.a; do
      [ -e "$_a" ] || continue
      # Compare FULL member names, not basenames: upstream's fix is precisely that the EC objects now
      # live under `obj.arm64ec/`, so basename-stripping would re-manufacture the collision it removed.
      _dupes=$("$out/bin/llvm-ar" t "$_a" | sort | uniq -d | wc -l)
      if [ "$_dupes" = 0 ]; then
        echo "$(basename "$_a"): no duplicate members — upstream index is correct, NOT reindexing"
        continue
      fi
      echo "$(basename "$_a"): $_dupes duplicated member name(s) — reindexing"
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
