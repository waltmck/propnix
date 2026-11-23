# unity-mono — Unity's Mono runtime (`mono-2.0-bdwgc.dll`, the Boehm-collected build the Unity player
# embeds) rebuilt as an ARM64EC PE, one build per Unity STREAM, for Windows Unity titles under wine+FEX
# on aarch64 hosts.
#
# WHY. A Unity Mono title ships its runtime beside the player, at
# `MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll`: an x64 PE that UnityPlayer.dll loads by name and
# binds by GetProcAddress. Under wine on aarch64 that runtime — and every byte of JIT output — runs
# through FEX. Built as ARM64EC, the JIT emits native ARM64 for the game's C# and the runtime's C half is
# native; the player and the game's native plugins stay x64 behind the per-signature thunks the ARM64EC
# layer adds at the p/invoke boundary — the scheme emulators/wine-mono's runtime uses, ported to Unity's
# fork.
#
# THE STREAM IS THE UNIT. The player and its runtime are built together per Unity release line, and the
# player binds to runtime internals that move between lines, so a runtime is correct only for players of
# its own stream; lib/modules/unity-mono.nix holds a game's declaration against its player at build time.
# Each stream locks Unity's mono branch (`unity-<stream>-mbe`) with its bdwgc submodule and selects a
# patch family. 2022.3 has no Windows-ARM64 port of its own and takes wine-mono's upstream arm64 work
# (seven merge requests, verbatim) before the ARM64EC layer; 6000.0 carries Unity's own Windows-ARM64
# port, onto which the layer is adapted. `propnix pin` automatically records new source locks;
# policy.nix selects a family, and this builder fails if it cannot patch, compile, or validate the DLLs.
# The port notes are in docs/research/unity-mono-arm64ec.md.
#
# SUSPEND. Boehm stops the world preemptively (SuspendThread + GetThreadContext). Under the ARM64EC
# contract a thread in x64 code stops only at the emulator's next doorbell poll, so this runtime relies on
# an emulator that polls inside every x64 loop: emulators/fex/patches/0003. The collector's register scan
# reads the ARM64 register set out of the aliased ARM64EC context (patches/bdwgc).
#
# The runtime DLL and its MonoPosixHelper companion are produced: the game's class libraries, etc/ and
# Managed/ stay as shipped (the runtime implements the same ABI), and the module unions the DLL over the
# payload at the runtime's path.
{
  lib,
  stdenv,
  runCommand,
  fetchFromGitHub,
  autoconf,
  automake,
  libtool,
  python3,
  perl,
  which,
  file,
  gettext,
  # The target's lib/win-toolchain.nix record (the scope injects it; llvm-mingw only): ARM64EC for the
  # hybrid wine+FEX stack, plain ARM64 for a native player process (lib/modules/unity-player.nix).
  toolchain,
  target,
  unityMonoPins,
}:
let
  # The registry (sources.nix, also used for validation on x86_64). `branch` is where Unity publishes the
  # stream (Unity-Technologies/mono); the revision is the
  # branch head the patch family was made against, and `bdwgc` is that revision's `external/bdwgc`
  # gitlink (Unity-Technologies/bdwgc). `targets` lists the PE targets the stream is built for: every
  # stream has the ARM64EC runtime (the x64 player under wine+FEX), and a stream has the plain-ARM64 one
  # only where a native ARM64 Windows player exists to load it — Unity added that player in 2023.1, so
  # 2022.3 has no consumer for it and is not built.
  streams = unityMonoPins;

  # Legacy pins share this libatomic_ops revision; automatically locked streams record their gitlink.
  # It is in the tree only so
  # autoreconf can descend into the AC_CONFIG_SUBDIRS entry bdwgc's configure.ac names; the build itself
  # uses the compiler's atomics (the configure.ac patch: --with-libatomic-ops=none, GC_BUILTIN_ATOMIC).
  libatomicOps = fetchFromGitHub {
    owner = "Unity-Technologies";
    repo = "libatomic_ops";
    rev = "7e44a3b8dcf457207d6394e4e52e327189155e4f";
    hash = "sha256-MAUkuga0t7vFD2xCGpT/+ptUGLqiXpMlr6vRr13ZTz8=";
  };

  triple = toolchain.triple;

  # Only ./patches keys a stream's build (like emulators/wine-mono): unrelated repo edits never perturb it.
  patchesFor =
    stream:
    lib.throwIfNot (builtins.pathExists (./patches + "/${stream}"))
      "propnix: Unity Mono patch family ${stream} is unavailable; manual packaging is required in emulators/unity-mono"
      (
        builtins.path {
          path = ./patches + "/${stream}";
          name = "unity-mono-${stream}-patches";
        }
      );
  bdwgcPatches = builtins.path {
    path = ./patches/bdwgc;
    name = "unity-mono-bdwgc-patches";
  };

  mkRuntime =
    stream: pin:
    stdenv.mkDerivation {
      pname = "unity-mono-${target}-${stream}";
      version = "${stream}-${builtins.substring 0 8 pin.mono.rev}";

      src = fetchFromGitHub {
        owner = "Unity-Technologies";
        repo = "mono";
        inherit (pin.mono) rev hash;
      };
      bdwgc = fetchFromGitHub {
        owner = "Unity-Technologies";
        repo = "bdwgc";
        inherit (pin.bdwgc) rev hash;
      };
      libatomicOps =
        if pin ? libatomicOps then
          fetchFromGitHub {
            owner = "Unity-Technologies";
            repo = "libatomic_ops";
            inherit (pin.libatomicOps) rev hash;
          }
        else
          libatomicOps;
      inherit bdwgcPatches;
      streamPatches = map patchesFor ([ (pin.patchFamily or stream) ] ++ (pin.extraPatchFamilies or [ ]));

      nativeBuildInputs = toolchain.nativeBuildInputs ++ [
        autoconf
        automake
        libtool
        python3
        perl
        which
        file
        gettext
      ];

      # The submodules, placed where the tree's gitlinks point. Store sources are read-only and the build
      # writes into the collector's directory (its own configure and objects), so copy rather than link.
      postUnpack = ''
        rm -rf "$sourceRoot/external/bdwgc"
        cp -r --no-preserve=mode "$bdwgc" "$sourceRoot/external/bdwgc"
        cp -r --no-preserve=mode "$libatomicOps" "$sourceRoot/external/bdwgc/libatomic_ops"
      '';

      postPatch = ''
        for family in $streamPatches; do
          for p in "$family"/*.patch; do
            echo "applying $(basename "$family")/$(basename "$p")"
            patch --batch --forward --fuzz=0 -p1 --no-backup-if-mismatch < "$p"
          done
        done
        for p in "$bdwgcPatches"/*.patch; do
          echo "applying bdwgc/$(basename "$p")"
          patch --batch --forward --fuzz=0 -d external/bdwgc -p1 --no-backup-if-mismatch < "$p"
        done
        # The tree's scripts carry `#!/usr/bin/env …`, which does not exist in the sandbox.
        patchShebangs .
        # Unity's autogen.sh makes mono/mini/Makefile.am a plain copy of Makefile.am.in before autoreconf.
        # autogen.sh itself is not run: it also clones every submodule of the tree.
        cat mono/mini/Makefile.am.in > mono/mini/Makefile.am
      '';

      # The tree ships no configure. autoreconf descends into external/bdwgc (AC_CONFIG_SUBDIRS) and
      # generates the collector's too; AUTOPOINT=true skips gettext's autopoint, which the runtime does
      # not use (--enable-nls=no below).
      preConfigure = ''
        AUTOPOINT=true autoreconf -i
      '';

      # Check the ONE decision the whole build hinges on, before spending the build to discover it in
      # installPhase: if libtool decided against shared libraries, every object still compiles and only
      # the final .dll is missing.
      postConfigure = ''
        grep -q "checking whether to build shared libraries... yes" config.log \
          || grep -q "^build_libtool_libs=yes" libtool \
          || { echo "libtool refused to build a shared library — the DLL would never appear."; \
               grep -aE "linker \(ld\) supports shared|libtool supports shared|whether to build shared" config.log | head -5; \
               exit 1; }
      '';

      # Three groups of flags:
      #   * the cross toolchain, as configure COMMAND-LINE assignments (emulators/wine-mono's recipe
      #     explains why: nixpkgs' cc-wrapper hook re-exports LD=ld for the build platform after the
      #     environment is applied, and a bare `ld` sends libtool down a silent static-only path; the same
      #     goes for lt_cv_deplibs_check_method=pass_all and for keeping static convenience archives);
      #   * Unity's own configuration of the runtime (external/buildscripts/build.pl, the Windows player
      #     runtime: embedded glib, no docs, the Unity JIT and the threading/loading switches the player
      #     expects, Boehm — the collector this DLL is named after);
      #   * the wine-mono runtime-only build facts (no class libraries, win32 DllMain, no TLS keyword).
      configureFlags = [
        "CC=${triple}-clang"
        "CXX=${triple}-clang++"
        "LD=${triple}-ld"
        "AR=${triple}-ar"
        "RANLIB=${triple}-ranlib"
        "STRIP=${triple}-strip"
        "DLLTOOL=${triple}-dlltool"
        "OBJDUMP=${triple}-objdump"
        "WINDRES=${triple}-windres"
        "--host=${triple}"
        "--target=${triple}"
        "--build=${stdenv.buildPlatform.config}"
        "--enable-shared"
        "--with-tls=none"
        "--disable-mcs-build"
        "--enable-win32-dllmain=yes"
        "--with-libgc-threads=win32"
        "--enable-nls=no"
        "--with-glib=embedded"
        "--with-mcs-docs=no"
        "--enable-no-threads-discovery=yes"
        "--enable-ignore-dynamic-loading=yes"
        "--enable-dont-register-main-static-data=yes"
        "--enable-thread-local-alloc=no"
        "--enable-unity-define=yes"
        "--with-unityjit=yes"
        "--with-monotouch=no"
        "PKG_CONFIG=false"
        "mono_cv_clang=no"
        "mono_feature_disable_cleanup=yes"
        "lt_cv_deplibs_check_method=pass_all"
      ];

      # The compiler flags go through the environment (configureFlags is whitespace-split, so a flag with
      # spaces cannot be a command-line assignment). The tree's C predates clang 22's pointer-compatibility
      # errors at a few hundred sites, so those two diagnostics stay warnings.
      env = {
        CFLAGS = "-g -O2 -Wno-error=incompatible-function-pointer-types -Wno-error=incompatible-pointer-types";
        CXXFLAGS = "-g -O2";
      };

      # The collector first (mono/mini links its libgc.la), then the runtime's subdirectories in
      # dependency order, then mini's generated headers (BUILT_SOURCES: asking for the library directly
      # skips them) and the library itself. WINEPREFIX=/dev/null keeps any stray tool from creating one.
      buildPhase = ''
        runHook preBuild
        sed -e 's/-lgcc_s//' -i libtool   # that library does not exist here
        make -j$NIX_BUILD_CORES -C external/bdwgc WINEPREFIX=/dev/null
        for d in culture eglib arch utils zlib sgen metadata; do
          make -j$NIX_BUILD_CORES -C "mono/$d" WINEPREFIX=/dev/null
        done
        make -C mono/mini version.h cpu-arm64.h WINEPREFIX=/dev/null
        make -j$NIX_BUILD_CORES -C mono/mini libmonoboehm-2.0.la WINEPREFIX=/dev/null
        # MonoPosixHelper (support/): the runtime's companion library the class libraries P/Invoke for
        # compression streams and POSIX-shaped I/O, against the bundled zlib built above. Unity ships it
        # beside the runtime for x64 and not at all for ARM64; a swapped runtime ships its own so no
        # title has to find out which of its assemblies reaches for it.
        make -j$NIX_BUILD_CORES -C support WINEPREFIX=/dev/null
        runHook postBuild
      '';

      # Nix's test phase: verify the actual cross-built products before installing them. A successful
      # configure or static-only build is not a usable runtime, and a wrong-architecture DLL is fatal.
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        dll=mono/mini/.libs/libmonoboehm-2.0.dll
        [ -f "$dll" ] || { echo "no shared Mono runtime was produced" >&2; exit 1; }
        helper=$(find support/.libs -maxdepth 1 -name '*.dll' | head -1)
        [ -n "$helper" ] || { echo "no MonoPosixHelper DLL was produced" >&2; exit 1; }
        ${toolchain.checkPe} "$dll" "$helper"
        llvm-readobj --coff-exports "$dll" | awk '/^ *Name:/ { print $2 }' | sort -u > exports
        [ "$(wc -l < exports)" -ge 1000 ] || { echo "Mono export table is incomplete" >&2; exit 1; }
        for symbol in mono_jit_init_version mono_jit_cleanup mono_runtime_invoke mono_gc_collect mono_add_internal_call; do
          grep -Fxq "$symbol" exports || { echo "missing Mono entry point: $symbol" >&2; exit 1; }
        done
        runHook postCheck
      '';

      failureHook = ''
        echo "propnix: Unity Mono ${stream} (${target}) failed during ''${curPhase:-build}; manual packaging is required in emulators/unity-mono. See the build error above." >&2
      '';

      # The product, under the name the player loads, plus its export list (`exports`, one name per line)
      # for the module's build-time check against the player. The image must be the TARGET's: a plain x64
      # PE would silently be the emulated runtime this package exists to replace, an ARM64EC one loads in
      # no native ARM64 process and a plain ARM64 one in no x64 process (lib/pe-check.py).
      installPhase = ''
        runHook preInstall
        dll=mono/mini/.libs/libmonoboehm-2.0.dll
        [ -f "$dll" ] || { echo "no shared runtime was produced — libtool fell back to a static build"; exit 1; }
        install -Dm644 "$dll" "$out/mono-2.0-bdwgc.dll"
        ${triple}-strip "$out/mono-2.0-bdwgc.dll"
        chmod 444 "$out/mono-2.0-bdwgc.dll"
        helper=$(find support/.libs -maxdepth 1 -name '*.dll' | head -1)
        [ -n "$helper" ] || { echo "no MonoPosixHelper DLL was produced under support/.libs"; exit 1; }
        install -m444 "$helper" "$out/MonoPosixHelper.dll"
        ${triple}-strip "$out/MonoPosixHelper.dll"
        ${toolchain.checkPe} "$out/mono-2.0-bdwgc.dll" "$out/MonoPosixHelper.dll"
        install -m444 exports "$out/exports"
        runHook postInstall
      '';

      dontStrip = true; # the mingw strip above is the right one; the host strip would not understand a PE

      passthru = {
        inherit stream;
        inherit (pin) branch;
        monoRev = pin.mono.rev;
      };

      meta = {
        description = "Unity ${stream} Mono runtime (mono-2.0-bdwgc.dll) as a ${target} PE";
        homepage = "https://github.com/Unity-Technologies/mono";
        license = lib.licenses.mit;
        platforms = [ "aarch64-linux" ];
      };
    };

  runtimes = lib.mapAttrs mkRuntime (lib.filterAttrs (_: pin: lib.elem target pin.targets) streams);
  forVersion =
    version:
    let
      stream = lib.versions.majorMinor version;
    in
    runtimes.${stream}
      or (throw "propnix: Unity ${version} has no ${target} Mono source lock; re-pin the game or package the stream manually in emulators/unity-mono");
in
# One attribute for the whole set (`.#unityMono`: the cachix job builds every stream through it), with the
# streams reachable by name for the module (`unityMono.streams."6000.0"`). A stream the target does not
# build is simply absent from `streams`, which is how the modules tell "unpackaged" from "packaged".
runCommand "unity-mono-${target}"
  {
    passthru = {
      streams = runtimes;
      inherit target forVersion;
    };
    meta = {
      description = "Unity Mono runtimes as ${target} PEs, one per Unity stream (${lib.concatStringsSep ", " (lib.attrNames runtimes)})";
      platforms = [ "aarch64-linux" ];
    };
  }
  ''
    mkdir -p "$out"
    ${lib.concatMapStringsSep "\n" (s: ''ln -s ${runtimes.${s}} "$out/${s}"'') (lib.attrNames runtimes)}
  ''
