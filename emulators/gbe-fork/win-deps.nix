# emulators/gbe-fork/win-deps.nix — the libraries gbe_fork's Windows shim links, built STATIC for one PE
# target with that target's lib/win-toolchain.nix record. One attribute per library; ./shim-win.nix
# links them. Instantiated per target through `winPkgs.<target>` (lib/default.nix).
#
# WHY NOT nixpkgs' CROSS SETS. The shim needs zlib, mbedtls, curl, opus, portaudio, abseil and protobuf
# for a Windows TARGET. nixpkgs' Windows cross package sets do not serve that here: curl and portaudio
# refuse to evaluate for any Windows host platform, and the aarch64 set's clang toolchain does not
# bootstrap on the pinned nixpkgs (its compiler-rt builtins are compiled before winpthreads' headers
# exist). What nixpkgs does provide, pinned and cached, is the SOURCES: every library below is the host
# package's `src` at its `version`, so a nixpkgs bump moves these with everything else — built with the
# llvm-mingw that produces every other PE in this repo, through each library's own CMake (zlib through its
# mingw makefile). Upstream gbe_fork does the same for its Windows release (premake5-deps.lua builds each
# dependency statically from a tarball); its option sets are reproduced below, named at each site.
#
# STATIC, ALL OF THEM: the shim is one self-contained DLL dropped into a game directory. A dependency
# built shared would become a runtime import the game's loader cannot satisfy, and the shim's own install
# check refuses any import that is not a Windows system DLL (./shim-win.nix).
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  toolchain, # the target's lib/win-toolchain.nix record (the scope injects it)
  target,
  # The host's packages: only `.src` and `.version` are read.
  zlib,
  mbedtls,
  curl,
  libopus,
  portaudio,
  abseil-cpp_202601,
  protobuf,
}:
let
  # stdenvNoCC: the host's compiler must stay out of the environment — the toolchain file names the
  # target's, and nothing else may be found. `dontConfigure`: a tarball's own `configure` would otherwise
  # be run by the generic phase.
  mkCmake =
    {
      pname,
      version,
      src,
      flags,
      prefixPath ? [ ],
      postInstall ? "",
    }:
    stdenvNoCC.mkDerivation {
      pname = "${pname}-${target}";
      inherit version src;
      nativeBuildInputs = toolchain.nativeBuildInputs ++ [
        cmake
        ninja
      ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        cmake -G Ninja -S . -B build \
          -DCMAKE_TOOLCHAIN_FILE=${toolchain.cmakeToolchain} \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$out" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DCMAKE_PREFIX_PATH="${lib.concatStringsSep ";" prefixPath}" \
          -DBUILD_SHARED_LIBS=OFF \
          ${lib.concatStringsSep " " (map lib.escapeShellArg flags)}
        cmake --build build -j"$NIX_BUILD_CORES"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        cmake --install build
        runHook postInstall
      '';
      inherit postInstall;
      dontStrip = true; # COFF archives; the host strip would not understand them
      meta = {
        description = "${pname} ${version}, static, for ${target} (gbe_fork shim dependency)";
        platforms = lib.platforms.linux;
      };
    };

  # Every archive a consumer must find. A library that quietly produced a DLL instead (a cmake option
  # renamed on a bump) would be caught at the shim's import check, but naming the archive here fails the
  # dependency itself, where the cause is.
  requireArchives =
    names:
    lib.concatMapStringsSep "\n" (n: ''
      [ -f "$out/lib/${n}" ] || { echo "propnix: ${n} was not produced under $out/lib"; ls "$out/lib"; exit 1; }
    '') names;

  # zlib's mingw makefile builds the archive alone (SHARED_MODE=0 is its default); the tarball's
  # `configure` is for Unix hosts and its CMake installs a `zlibstatic` name no consumer links as.
  zlibStatic = stdenvNoCC.mkDerivation {
    pname = "zlib-${target}";
    inherit (zlib) version src;
    nativeBuildInputs = toolchain.nativeBuildInputs;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      make -f win32/Makefile.gcc -j"$NIX_BUILD_CORES" libz.a \
        CC=${toolchain.cc} AR=${toolchain.ar} RC=${toolchain.windres} STRIP=${toolchain.strip}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm444 libz.a "$out/lib/libz.a"
      install -Dm444 -t "$out/include" zlib.h zconf.h
      runHook postInstall
    '';
    dontStrip = true;
    meta = {
      description = "zlib ${zlib.version}, static, for ${target} (gbe_fork shim dependency)";
      platforms = lib.platforms.linux;
    };
  };

  # premake5-deps.lua `mbedtls_common_defs`. GEN_FILES=OFF: the release tree carries its generated sources,
  # so no Python is needed.
  mbedtlsStatic = mkCmake {
    pname = "mbedtls";
    inherit (mbedtls) version src;
    flags = [
      "-DUSE_STATIC_MBEDTLS_LIBRARY=ON"
      "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF"
      "-DENABLE_TESTING=OFF"
      "-DENABLE_PROGRAMS=OFF"
      "-DMBEDTLS_FATAL_WARNINGS=OFF"
      "-DGEN_FILES=OFF"
    ];
    postInstall = requireArchives [
      "libmbedtls.a"
      "libmbedx509.a"
      "libmbedcrypto.a"
    ];
  };

  # premake5-deps.lua `curl_common_defs`: libcurl only, static, TLS through mbedtls, zlib, and every
  # optional dependency curl would otherwise look for switched off by name. Consumers compile with
  # CURL_STATICLIB (the shim does), or curl.h declares its API dllimport.
  curlStatic = mkCmake {
    pname = "curl";
    inherit (curl) version src;
    prefixPath = [
      mbedtlsStatic
      zlibStatic
    ];
    flags = [
      "-DBUILD_CURL_EXE=OFF"
      "-DBUILD_STATIC_LIBS=ON"
      "-DBUILD_TESTING=OFF"
      "-DBUILD_LIBCURL_DOCS=OFF"
      "-DBUILD_MISC_DOCS=OFF"
      "-DENABLE_CURL_MANUAL=OFF"
      "-DCURL_USE_PKGCONFIG=OFF"
      "-DCURL_USE_OPENSSL=OFF"
      "-DCURL_USE_MBEDTLS=ON"
      "-DMBEDTLS_INCLUDE_DIR=${mbedtlsStatic}/include"
      "-DMBEDTLS_LIBRARY=${mbedtlsStatic}/lib/libmbedtls.a"
      "-DMBEDX509_LIBRARY=${mbedtlsStatic}/lib/libmbedx509.a"
      "-DMBEDCRYPTO_LIBRARY=${mbedtlsStatic}/lib/libmbedcrypto.a"
      "-DCURL_ZLIB=ON"
      "-DZLIB_ROOT=${zlibStatic}"
      "-DCURL_CA_FALLBACK=OFF"
      "-DCURL_USE_LIBSSH2=OFF"
      "-DCURL_USE_LIBPSL=OFF"
      "-DUSE_LIBIDN2=OFF"
      "-DCURL_DISABLE_LDAP=ON"
      "-DUSE_NGHTTP2=OFF"
      "-DCURL_BROTLI=OFF"
      "-DCURL_ZSTD=OFF"
    ];
    postInstall = requireArchives [ "libcurl.a" ];
  };

  # premake5-deps.lua `opus_common_defs` (OPUS_STATIC_RUNTIME is an MSVC CRT switch with no mingw meaning).
  # On an ARM target the intrinsics are off, and the codec is plain C: opus's runtime CPU detection for
  # ARM has no Windows method, and its CMake's presume-only alternative leaves the NEON kernels undeclared
  # (their prototypes key on the runtime-detection macro). This is a voice-chat codec in a shim that
  # serves games offline; the kernels would never run.
  opusStatic = mkCmake {
    pname = "opus";
    inherit (libopus) version src;
    flags = [
      "-DOPUS_BUILD_SHARED_LIBRARY=OFF"
      "-DOPUS_BUILD_TESTING=OFF"
      "-DOPUS_BUILD_PROGRAMS=OFF"
      "-DOPUS_CUSTOM_MODES=OFF"
      "-DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF"
    ]
    ++ lib.optional (lib.hasPrefix "aarch64" target) "-DOPUS_DISABLE_INTRINSICS=ON";
    postInstall = requireArchives [ "libopus.a" ];
  };

  # premake5-deps.lua `portaudio_common_defs`, spelled in the option names of the portaudio release
  # nixpkgs pins (PA_BUILD_STATIC/PA_BUILD_SHARED, with the `_static` name suffix off so the archive is
  # `libportaudio.a` — the name upstream's link table uses). The four Windows host APIs are on, ASIO off
  # (its SDK is not redistributable). That release's cmake_minimum_required is below what CMake still
  # accepts; the policy floor is raised to the lowest version CMake allows.
  portaudioStatic = mkCmake {
    pname = "portaudio";
    inherit (portaudio) version src;
    flags = [
      "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
      "-DPA_BUILD_STATIC=ON"
      "-DPA_BUILD_SHARED=OFF"
      "-DPA_LIBNAME_ADD_SUFFIX=OFF"
      "-DPA_BUILD_TESTS=OFF"
      "-DPA_BUILD_EXAMPLES=OFF"
      "-DPA_ENABLE_DEBUG_OUTPUT=OFF"
      "-DPA_USE_ASIO=OFF"
      "-DPA_USE_DS=ON"
      "-DPA_USE_WMME=ON"
      "-DPA_USE_WASAPI=ON"
      "-DPA_USE_WDMKS=ON"
      "-DPA_USE_WDMKS_DEVICE_INFO=ON"
    ];
    postInstall = requireArchives [ "libportaudio.a" ];
  };

  # abseil, then protobuf against it (`protobuf_ABSL_PROVIDER=package`): the pairing nixpkgs makes for the
  # host's protobuf, so the generated code protoc (the host's, ./shim-win.nix) emits matches the runtime
  # linked here. STATIC IS LOAD-BEARING, not a preference — ./shim.nix has why (protobuf's process-global
  # descriptor pool and a library that is loaded twice into one game).
  abseilStatic = mkCmake {
    pname = "abseil-cpp";
    inherit (abseil-cpp_202601) version src;
    flags = [
      "-DABSL_PROPAGATE_CXX_STD=ON"
      "-DABSL_BUILD_TESTING=OFF"
      "-DABSL_ENABLE_INSTALL=ON"
      "-DCMAKE_CXX_STANDARD=17"
    ];
    postInstall = requireArchives [ "libabsl_base.a" ];
  };
  protobufStatic = mkCmake {
    pname = "protobuf";
    inherit (protobuf) version src;
    prefixPath = [ abseilStatic ];
    flags = [
      "-Dprotobuf_BUILD_TESTS=OFF"
      "-Dprotobuf_BUILD_PROTOC_BINARIES=OFF"
      "-Dprotobuf_BUILD_LIBPROTOC=OFF"
      "-Dprotobuf_BUILD_LIBUPB=OFF"
      "-Dprotobuf_BUILD_SHARED_LIBS=OFF"
      "-Dprotobuf_WITH_ZLIB=OFF"
      "-Dprotobuf_ABSL_PROVIDER=package"
      "-Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON"
      "-DCMAKE_CXX_STANDARD=17"
    ];
    postInstall = requireArchives [ "libprotobuf.a" ];
  };
in
{
  zlib = zlibStatic;
  mbedtls = mbedtlsStatic;
  curl = curlStatic;
  opus = opusStatic;
  portaudio = portaudioStatic;
  abseil = abseilStatic;
  protobuf = protobufStatic;
}
