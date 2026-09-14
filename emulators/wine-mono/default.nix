# wine-mono — the .NET CLR wine hosts for MANAGED Windows titles, as a store tree ready to be dropped into
# a prefix at `C:\windows\mono\mono-2.0`, with the x86_64 RUNTIME REBUILT FROM SOURCE so this tree's patches
# reach it.
#
# WHY THIS EXISTS. A "managed" (pure .NET) exe carries a CLR header and — for a modern C# build — NO import
# table at all; nothing in it is machine code the wine loader can enter. Windows' loader special-cases such
# an image and hands it to the CLR; wine does the same through `mscoree.dll`, which must find a real runtime
# to host. Ship none and every managed title dies at process start before a single frame. Space Engineers is
# the first such title in the suite (`Bin64/SpaceEngineers.exe`: 2 sections, no imports, CLR v4.0.30319,
# `.config` pinning `.NETFramework,Version=v4.6.1`); KSP/Iron Lung/Hollow Knight are Unity *Mono* builds that
# carry their OWN runtime inside the payload and therefore never needed one from the prefix.
#
# WHICH RUNTIME. Wine Mono is the runtime wine itself installs — the version is compiled INTO wine
# (`dlls/mscoree/mscoree_private.h: #define WINE_MONO_VERSION` in the pinned Hangover tree), so it is not a
# free choice; it is a property of the wine we build, and the guard at the bottom enforces the match.
#
# ── WHY A SOURCE BUILD AT ALL, AND WHY ONLY THE RUNTIME ───────────────────────────────────────────────────
# A weak reference in Mono's delegate bookkeeping makes every native→managed CALLBACK a coin flip under
# ARM64EC+FEX: the delegate is collected mid-callback and the callback runs with a null `this`. That is
# patches/0001, which reproduces in a 60-line probe (138/150 iterations fail upstream, 0/150 patched) and
# which is the difference between "Space Engineers does not start" and "Space Engineers plays" — see the
# patch's own header for the measurements and pkgs/games/space-engineers for the symptom.
#
# Fixing it means building Mono, and building ALL of Mono means the class libraries too: a bootstrap runtime,
# `monolite`, and hours. It also means running the x86_64-Linux llvm-mingw toolchain the source tarball
# bundles, which on an aarch64 host would mean qemu — something this tree never does.
#
# So this package is a HYBRID, and deliberately the smallest one that carries the fix:
#   * the RELEASE tarball supplies the class libraries, etc/, support/ — bytes upstream already built, and
#     nothing in them is affected by the patch;
#   * `libmono-2.0-x86_64.dll` — the native runtime, where the bug lives — is rebuilt from the SOURCE
#     tarball with ./patches applied, using upstream's own `--disable-mcs-build` recipe (runtime only, no
#     BCL, no bootstrap) and nixpkgs' `pkgsCross.mingwW64` cross-GCC, which RUNS natively on both hosts;
#   * every other file, including the 32-bit `libmono-2.0-x86.dll`, stays exactly as upstream shipped it.
#     The 32-bit runtime therefore still has the delegate bug. That is a deliberate scope limit, not an
#     oversight: no 32-bit managed title is packaged here, and building a second runtime would double the
#     build for a file nothing in this suite loads. A 32-bit managed game arriving is the signal to extend
#     `abis` below, not to rediscover the bug.
#
# The version and the release tarball's hash are unchanged from the prebuilt-only packaging this replaced,
# so the class libraries are bit-identical to what upstream ships for this release.
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  coreutils,
  gnutar,
  xz,
  autoconf,
  automake,
  libtool,
  python3,
  perl,
  which,
  file,
  gettext,
  # nixpkgs' x86_64-w64-mingw32 cross-GCC (`pkgsCross.mingwW64.stdenv.cc`). NOT the llvm-mingw this tree
  # uses for ARM64EC work and NOT the toolchain the source tarball bundles: this compiles an ORDINARY
  # x86_64 PE, which is what wine's x86_64 mscoree loads (under FEX on aarch64), and nixpkgs' cross-GCC is
  # cached and native on both hosts.
  mingwGccW64,
  wine, # only to CHECK the version against the wine we ship; nothing from it is installed
}:
let
  # MUST equal the wine we build against. See the guard at the bottom — it is not advisory.
  version = "11.2.0";

  release = fetchurl {
    url = "https://dl.winehq.org/wine/wine-mono/${version}/wine-mono-${version}-x86.tar.xz";
    hash = "sha256-yfsuKCOs8wsAC4gGF32w9AdReGE23T+Psr54l7FkPQY=";
  };

  src = fetchurl {
    url = "https://dl.winehq.org/wine/wine-mono/${version}/wine-mono-${version}-src.tar.xz";
    hash = "sha256-rr75tD3KgLPr5KCtoPRZJdgz83G6W0L1rPmZBGFWi6k=";
  };

  # Only ./patches keys this build (like emulators/wine-hangover): unrelated repo edits never perturb the
  # ~40 min runtime build, and dropping a `NNNN-name.patch` in is all it takes to add one.
  patchesDir = builtins.path {
    path = ./patches;
    name = "wine-mono-patches";
  };

  # ── the native runtime, from source ────────────────────────────────────────────────────────────────────
  runtime = stdenv.mkDerivation {
    pname = "wine-mono-runtime-x86_64";
    inherit version src;

    nativeBuildInputs = [
      mingwGccW64
      autoconf
      automake
      libtool
      python3
      perl
      which
      file
      gettext
    ];

    # The tarball is 293 MB and unpacks to 1.1 GB; only mono/ is needed.
    sourceRoot = "wine-mono-${version}/mono";

    postPatch = ''
      for p in ${patchesDir}/*.patch; do
        echo "applying $(basename "$p")"
        patch -p1 < "$p"
      done
      # 75 scripts in this tree (autogen.sh among them) carry `#!/usr/bin/env …`, which does not exist in
      # the sandbox; patch them before anything runs one.
      patchShebangs .
    '';

    # mono's tarball ships no configure (only autogen.sh), and NOCONFIGURE keeps autogen from running it
    # with the wrong arguments before ours.
    preConfigure = ''
      export CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++ LD=x86_64-w64-mingw32-ld
      export AR=x86_64-w64-mingw32-ar RANLIB=x86_64-w64-mingw32-ranlib STRIP=x86_64-w64-mingw32-strip
      export DLLTOOL=x86_64-w64-mingw32-dlltool OBJDUMP=x86_64-w64-mingw32-objdump
      NOCONFIGURE=1 ./autogen.sh
    '';

    # Check the ONE decision the whole build hinges on, before spending forty minutes to discover it in
    # installPhase: if libtool decided against shared libraries, every object still compiles and only the
    # final .dll is missing.
    postConfigure = ''
      grep -q "checking whether to build shared libraries... yes" config.log \
        || grep -q "^build_libtool_libs=yes" libtool \
        || { echo "libtool refused to build a shared library — the DLL would never appear."; \
             grep -aE "linker \(ld\) supports shared|libtool supports shared|whether to build shared" config.log | head -5; \
             exit 1; }
    '';

    # Upstream's own recipe (wine-mono's mono.make) plus three things this environment needs, each of which
    # FAILS SILENTLY into a static-only build if omitted:
    #   * LD (and friends) must name the MINGW tools. nixpkgs' cross setup exports LD=ld for the BUILD
    #     platform and `gcc -print-prog-name=ld` answers a bare "ld", so libtool probes the HOST linker for
    #     Windows-DLL support, concludes "no", and emits only a .a — with no error anywhere.
    #   * lt_cv_deplibs_check_method=pass_all: libtool then file-magic-tests the mingw IMPORT libraries
    #     (libadvapi32.a, libversion.a, …), fails to recognise them as shared, decides the DLL would have
    #     undefined symbols, and again falls back to static.
    #   * NO --disable-static: mono links noinst CONVENIENCE archives (mono_opcodes, mono_binary_search,
    #     mono_poll, …); disabling static drops them and the DLL link fails on exactly those symbols.
    # The toolchain vars are passed as configure COMMAND-LINE assignments, not via `env`: nixpkgs'
    # cc-wrapper setup hook runs AFTER the derivation env is applied and re-exports LD=ld for the BUILD
    # platform, which is exactly the clobber that sends libtool down the static path below.
    configureFlags = [
      "CC=x86_64-w64-mingw32-gcc"
      "CXX=x86_64-w64-mingw32-g++"
      "LD=x86_64-w64-mingw32-ld"
      "AR=x86_64-w64-mingw32-ar"
      "RANLIB=x86_64-w64-mingw32-ranlib"
      "STRIP=x86_64-w64-mingw32-strip"
      "DLLTOOL=x86_64-w64-mingw32-dlltool"
      "OBJDUMP=x86_64-w64-mingw32-objdump"
      "--host=x86_64-w64-mingw32"
      "--target=x86_64-w64-mingw32"
      "--build=${stdenv.buildPlatform.config}"
      "--enable-shared"
      "--with-tls=none"
      "--disable-mcs-build" # runtime only: the class libraries come from the release tarball
      "--enable-win32-dllmain=yes"
      "--with-libgc-threads=win32"
      "--disable-boehm"
      "PKG_CONFIG=false"
      "mono_cv_clang=no"
      "mono_feature_disable_cleanup=yes"
      "lt_cv_deplibs_check_method=pass_all"
    ];

    # Subdirectory order is upstream's and is NOT optional, and neither is `built_sources`: asking make for
    # `libmonosgen-2.0.la` directly skips automake's BUILT_SOURCES, and the build then dies on a missing
    # generated version.h. WINEPREFIX=/dev/null keeps any stray tool from creating one.
    buildPhase = ''
      runHook preBuild
      sed -e 's/-lgcc_s//' -i libtool   # upstream applies the same sed: that library does not exist here
      for d in eglib utils culture zlib sgen metadata; do
        make -j$NIX_BUILD_CORES -C "mono/$d" WINEPREFIX=/dev/null
      done
      make -C mono/mini built_sources WINEPREFIX=/dev/null
      make -j$NIX_BUILD_CORES -C mono/mini libmonosgen-2.0.la WINEPREFIX=/dev/null
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      dll=mono/mini/.libs/libmonosgen-2.0.dll
      # libtool emits a static .a and NO dll when it decides shared linking is impossible (see
      # configureFlags). That is the failure mode this build must never ship silently.
      [ -f "$dll" ] || { echo "no shared runtime was produced — libtool fell back to a static build"; exit 1; }
      # writable first: the mingw strip rewrites the file in place, so a 444 install would fail here
      install -Dm644 "$dll" "$out/libmono-2.0-x86_64.dll"
      x86_64-w64-mingw32-strip "$out/libmono-2.0-x86_64.dll"
      chmod 444 "$out/libmono-2.0-x86_64.dll"
      runHook postInstall
    '';

    dontStrip = true; # the mingw strip above is the right one; the host strip would not understand a PE

    meta = {
      description = "wine-mono ${version} native runtime (x86_64 PE), rebuilt from source with propnix's patches";
      license = lib.licenses.mit;
    };
  };
in
runCommand "wine-mono-${version}"
  {
    inherit release;
    nativeBuildInputs = [
      coreutils
      gnutar
      xz
    ];
    passthru = {
      inherit version runtime;
      patches = patchesDir;
    };
    meta = {
      description = "Wine Mono ${version} — the .NET CLR wine hosts for managed Windows executables";
      homepage = "https://gitlab.winehq.org/mono/wine-mono";
      license = lib.licenses.mit; # MIT (Mono) + LGPL21 parts; see the tarball's own LICENSE files
      sourceProvenance = [
        lib.sourceTypes.binaryNativeCode # the release tarball's class libraries and 32-bit runtime
        lib.sourceTypes.fromSource # the x86_64 runtime above
      ];
    };
  }
  ''
    mkdir -p "$out"
    # The tarball unpacks to a single `wine-mono-<version>/` dir holding bin/ etc/ lib/ support/. Strip that
    # component so `$out` IS the runtime root — i.e. exactly what wine expects to find AT
    # `C:\windows\mono\mono-2.0`, so the consumer symlinks `$out` there with no path arithmetic.
    tar -xJf "$release" -C "$out" --strip-components=1

    # ── the patched runtime replaces upstream's, and ONLY that file ──
    # Keeping the release bytes for everything else is the whole point of the hybrid (see the header): the
    # class libraries are unaffected by our patches, so there is no reason to rebuild — or to diverge from —
    # them. Compare sizes on the way past: upstream ships this stripped at ~4 MB, and a silent 30 MB here
    # would mean the strip in the runtime derivation stopped working.
    [ -f "$out/bin/libmono-2.0-x86_64.dll" ] \
      || { echo "propnix: wine-mono ${version} release tarball has no bin/libmono-2.0-x86_64.dll to replace"; exit 1; }
    chmod u+w "$out/bin"
    install -m444 ${runtime}/libmono-2.0-x86_64.dll "$out/bin/libmono-2.0-x86_64.dll"
    _sz=$(stat -c%s "$out/bin/libmono-2.0-x86_64.dll")
    [ "$_sz" -le 8000000 ] || {
      echo "propnix: the rebuilt runtime is $_sz bytes (upstream ships ~4 MB stripped) —"
      echo "         the mingw strip in the runtime derivation stopped working"; exit 1; }

    # ── Guards. Each of these is a silent-breakage mode, so make it a build failure instead. ──

    # 1. The two native cores `find_mono_dll()` looks for (`dlls/mscoree/metahost.c` picks by the arch
    #    mscoree ITSELF was built for; on aarch64 the ARM64EC mscoree asks for the x86_64 one and runs it
    #    through FEX). Without them mscoree finds a directory but no runtime, falls through every other
    #    search path, and ends at the appwiz downloader — which, offline, means the managed title dies
    #    exactly as it does with no mono at all.
    for _core in bin/libmono-2.0-x86.dll bin/libmono-2.0-x86_64.dll; do
      [ -f "$out/$_core" ] || { echo "propnix: wine-mono ${version} is missing $_core"; exit 1; }
    done

    # 2. Our runtime must actually BE an x86_64 PE. A cross-build misconfiguration that produced an ELF, or
    #    an ARM64 PE, would still install fine here and then fail at CLR startup inside the game.
    case "$(od -An -tx1 -N2 -j0 "$out/bin/libmono-2.0-x86_64.dll" | tr -d ' \n')" in
      4d5a) ;; # "MZ"
      *) echo "propnix: the rebuilt libmono-2.0-x86_64.dll is not a PE image"; exit 1 ;;
    esac

    # 3. The Windows-support package. Not installed here (see wine-prefix-lower.nix for why the .NET
    #    registry facts are written declaratively instead), but its ABSENCE would mean the tarball layout
    #    changed under us, which is worth knowing at build time rather than at launch.
    [ -f "$out/support/winemono-support.msi" ] \
      || { echo "propnix: wine-mono ${version} is missing support/winemono-support.msi"; exit 1; }

    # 4. THE VERSION MUST MATCH THE WINE WE SHIP. `mscoree` hardcodes `WINE_MONO_VERSION` and uses it to
    #    reject a support package older than itself (`mscoree_main.c: compare_versions(WINE_MONO_VERSION,
    #    versionstringbuf) <= 0`) and to name the datadir it searches (`metahost.c: L"\\wine-mono-"
    #    WINE_MONO_VERSION`). A wine bump that moves that constant must move this pin too — otherwise the
    #    prefix silently ships a runtime wine no longer considers current. Read it back out of the BUILT
    #    builtin rather than the wine source tree (the source is not a runtime input, and every arch's
    #    mscoree.dll carries the constant as a UTF-16 literal; strip the NULs to match it as ASCII).
    # (Via a temp file, not `tr … | grep -q`: `grep -q` exits at the first hit, `tr` then dies of SIGPIPE,
    # and stdenv's `set -o pipefail` would report the whole pipeline as failed even on a MATCH.)
    _found=""
    for _m in ${wine}/lib/wine/*/mscoree.dll; do
      [ -e "$_m" ] || continue
      tr -d '\000' < "$_m" > "$TMPDIR/mscoree.strings"
      if grep -qa "wine-mono-${version}" "$TMPDIR/mscoree.strings"; then _found=yes; fi
    done
    [ -n "$_found" ] || {
      echo "propnix: none of ${wine}/lib/wine/*/mscoree.dll names wine-mono-${version}."
      echo "         The pinned wine expects a DIFFERENT WINE_MONO_VERSION — bump \`version\` + both"
      echo "         hashes in emulators/wine-mono/default.nix to whatever dlls/mscoree/mscoree_private.h"
      echo "         now says, and re-check that ./patches still apply to that release's mono."
      exit 1
    }
  ''
