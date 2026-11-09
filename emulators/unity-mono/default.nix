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
# Each stream pins Unity's mono branch (`unity-<stream>-mbe`) with its bdwgc submodule and carries its own
# patch family. 2022.3 has no Windows-ARM64 port of its own and takes wine-mono's upstream arm64 work
# (seven merge requests, verbatim) before the ARM64EC layer; 6000.0 carries Unity's own Windows-ARM64
# port, onto which the layer is adapted. A new stream is a new pin plus a family; the port notes are in
# docs/research/unity-mono-arm64ec.md.
#
# SUSPEND. Boehm stops the world preemptively (SuspendThread + GetThreadContext). Under the ARM64EC
# contract a thread in x64 code stops only at the emulator's next doorbell poll, so this runtime relies on
# an emulator that polls inside every x64 loop: emulators/fex/patches/0003. The collector's register scan
# reads the ARM64 register set out of the aliased ARM64EC context (patches/bdwgc).
#
# Only the DLL is produced: the game's class libraries, etc/ and Managed/ stay as shipped (the runtime
# implements the same ABI), and the module unions the DLL over the payload at the runtime's path.
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
  # This tree's llvm-mingw (emulators/llvm-mingw): `arm64ec-w64-mingw32-clang` and friends.
  llvmMingw,
}:
let
  # The pins. `branch` is where Unity publishes the stream (Unity-Technologies/mono); the revision is the
  # branch head the patch family was made against, and `bdwgc` is that revision's `external/bdwgc`
  # gitlink (Unity-Technologies/bdwgc).
  streams = {
    "2022.3" = {
      branch = "unity-2022.3-mbe";
      mono = {
        rev = "b8eb56fab45dd52845fabba7b7ddc9a80b2b0498";
        hash = "sha256-QRpU0Wck/OEdWQuOeDdzxPeC69Y5LGMzGnI/4coJ+Gs=";
      };
      bdwgc = {
        rev = "8167f758c8e8d9c4a276971629d0ca98e20759f3";
        hash = "sha256-WxjDLmjeAMzn7EHlN13ENlffN8+sSJ7vPoW9jHtNJhg=";
      };
    };
    "6000.0" = {
      branch = "unity-6000.0-mbe";
      mono = {
        rev = "e3f5e86f047452d5ae757c195490df0059418621";
        hash = "sha256-94Ku7xkvm0nobDRQD777K8+gy8dF+e+ifVZh1sJydEs=";
      };
      bdwgc = {
        rev = "1113fefc4ba0e895767ac780d84e9e456fd624db";
        hash = "sha256-pCEPVT7rpWsWcNnpeSblgiwW9ClL+UIXWdC4HJ9psnQ=";
      };
    };
  };

  # bdwgc's nested libatomic_ops submodule, the same commit in both streams. It is in the tree only so
  # autoreconf can descend into the AC_CONFIG_SUBDIRS entry bdwgc's configure.ac names; the build itself
  # uses the compiler's atomics (the configure.ac patch: --with-libatomic-ops=none, GC_BUILTIN_ATOMIC).
  libatomicOps = fetchFromGitHub {
    owner = "Unity-Technologies";
    repo = "libatomic_ops";
    rev = "7e44a3b8dcf457207d6394e4e52e327189155e4f";
    hash = "sha256-MAUkuga0t7vFD2xCGpT/+ptUGLqiXpMlr6vRr13ZTz8=";
  };

  triple = "arm64ec-w64-mingw32";

  # Only ./patches keys a stream's build (like emulators/wine-mono): unrelated repo edits never perturb it.
  patchesFor =
    stream:
    builtins.path {
      path = ./patches + "/${stream}";
      name = "unity-mono-${stream}-patches";
    };
  bdwgcPatches = builtins.path {
    path = ./patches/bdwgc;
    name = "unity-mono-bdwgc-patches";
  };

  mkRuntime =
    stream: pin:
    stdenv.mkDerivation {
      pname = "unity-mono-arm64ec-${stream}";
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
      inherit libatomicOps bdwgcPatches;
      streamPatches = patchesFor stream;

      nativeBuildInputs = [
        llvmMingw
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
        for p in "$streamPatches"/*.patch; do
          echo "applying $(basename "$p")"
          patch -p1 --no-backup-if-mismatch < "$p"
        done
        for p in "$bdwgcPatches"/*.patch; do
          echo "applying bdwgc/$(basename "$p")"
          patch -d external/bdwgc -p1 --no-backup-if-mismatch < "$p"
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
        runHook postBuild
      '';

      # The product, under the name the player loads, plus its export list (`exports`, one name per line)
      # for the module's build-time check against the player. The image must be ARM64EC: wine's x64
      # personality loads a plain ARM64 PE in no process, and a plain x64 PE would silently be the
      # emulated runtime this package exists to replace.
      installPhase = ''
        runHook preInstall
        dll=mono/mini/.libs/libmonoboehm-2.0.dll
        [ -f "$dll" ] || { echo "no shared runtime was produced — libtool fell back to a static build"; exit 1; }
        install -Dm644 "$dll" "$out/mono-2.0-bdwgc.dll"
        ${triple}-strip "$out/mono-2.0-bdwgc.dll"
        chmod 444 "$out/mono-2.0-bdwgc.dll"
        # Each report into a variable first: `readobj | grep -q` lets grep close the pipe on the first
        # match, readobj dies of SIGPIPE, and under pipefail a PASSING check reads as failed.
        hdr=$(llvm-readobj --file-headers "$out/mono-2.0-bdwgc.dll")
        grep -q "IMAGE_FILE_MACHINE_ARM64EC" <<<"$hdr" \
          || { echo "propnix: the runtime is not an ARM64EC PE"; grep Machine <<<"$hdr"; exit 1; }
        cfg=$(llvm-readobj --coff-load-config "$out/mono-2.0-bdwgc.dll")
        grep -qi "CHPEMetadata" <<<"$cfg" \
          || { echo "propnix: the runtime has no CHPE metadata — a plain x64 PE, not ARM64EC"; exit 1; }
        llvm-readobj --coff-exports "$out/mono-2.0-bdwgc.dll" | awk '/^ *Name:/ { print $2 }' | sort -u > "$out/exports"
        [ "$(wc -l < "$out/exports")" -ge 1000 ] \
          || { echo "propnix: the runtime exports $(wc -l < "$out/exports") names — the export table is wrong"; exit 1; }
        runHook postInstall
      '';

      dontStrip = true; # the mingw strip above is the right one; the host strip would not understand a PE

      passthru = {
        inherit stream;
        inherit (pin) branch;
        monoRev = pin.mono.rev;
      };

      meta = {
        description = "Unity ${stream} Mono runtime (mono-2.0-bdwgc.dll) as an ARM64EC PE";
        homepage = "https://github.com/Unity-Technologies/mono";
        license = lib.licenses.mit;
        platforms = [ "aarch64-linux" ];
      };
    };

  runtimes = lib.mapAttrs mkRuntime streams;
in
# One attribute for the whole set (`.#unityMono`: the cachix job builds every stream through it), with the
# streams reachable by name for the module (`unityMono.streams."6000.0"`).
runCommand "unity-mono-arm64ec"
  {
    passthru = {
      streams = runtimes;
    };
    meta = {
      description = "Unity Mono runtimes as ARM64EC PEs, one per Unity stream (${lib.concatStringsSep ", " (lib.attrNames streams)})";
      platforms = [ "aarch64-linux" ];
    };
  }
  ''
    mkdir -p "$out"
    ${lib.concatMapStringsSep "\n" (s: ''ln -s ${runtimes.${s}} "$out/${s}"'') (lib.attrNames streams)}
  ''
