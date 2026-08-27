# emulators/gbe-fork/shim.nix — ONE ABI's build of gbe_fork's `api_regular` target: `libsteam_api.so`, the
# Steam-API reimplementation the steam-emu module loads into a game's own process so it can answer DLC
# entitlement offline. Instantiate it once per ABI you need (see ./default.nix): `callPackage` for the host's
# own arch, `pkgsCross.<target>.callPackage` for a foreign one. Nothing here is arch-aware — that is the
# whole point of expressing it as an ordinary derivation rather than an unpack of upstream's releases.
#
# WHY FROM SOURCE. Upstream publishes prebuilt x86/x86_64 ELF and x86/x64 PE artifacts and NOTHING for
# aarch64 — but propnix now has an `aarch64-linux` emulatedPlatform (Factorio ships a native ARM64 Linux
# build), and this library is loaded INTO the game's process, so it must be the PAYLOAD's arch. Building it
# means every ABI comes from one description, and a foreign ABI is a CROSS build that runs the compiler
# natively — never a qemu-emulated native build, which on an aarch64 host would silently succeed slowly
# rather than fail.
#
# WHY NOT PREMAKE. Upstream drives premake5, whose project hardcodes `platforms { "x64", "x86" }` with every
# include/lib dir keyed on `x32_*`/`x64_*`, and whose dependency bootstrap downloads and builds vendored
# tarballs with a prebuilt x86_64 `7za`/`cmake` checked into `third-party/deps/linux`. Porting that platform
# axis would be a permanent private patch rebased on every pin bump, and the vendored toolchain binaries are
# exactly the qemu trap above. So the compiler is driven directly from premake5.lua's build DESCRIPTION —
# the file list, the defines, the flags — with the libraries taken from nixpkgs. Each deviation from what
# premake would emit is listed at its site below; there are no silent ones.
#
# VERIFY (aarch64):
#   nix build .#gbeFork && file result/share/gbe_fork/aarch64/libsteam_api.so   # → ELF … ARM aarch64
#   nm -D --defined-only result/share/gbe_fork/aarch64/libsteam_api.so | grep -c ' T '   # → 1301
# The acceptance gate is a SYMBOL DIFF against upstream's prebuilt x86_64 release: the `extern "C"` export
# surface must match exactly (1302 symbols, including SteamInternal_SteamAPI_Init and all 1023
# SteamAPI_ISteam* flat functions), because a shim that loads but is missing entry points is WORSE than no
# shim at all — the game's SteamAPI init throws instead of failing cleanly, which is precisely how the
# predecessor goldberg-emu 0.2.5 black-screened hollow-knight.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  buildPackages,
  # The library set. `mbedtls` MUST be 3.x: dll/auth.cpp calls the 5-argument
  # `mbedtls_pk_parse_key(…, f_rng, p_rng)` that 3.x introduced.
  protobuf,
  abseil-cpp_202601,
  curl,
  mbedtls,
  libopus,
  portaudio,
}:
let
  version = "2026_07_19";

  # PROTOBUF IS LINKED STATICALLY, and that is not a packaging preference — it is load-bearing.
  #
  # protobuf keeps a PROCESS-GLOBAL generated-descriptor database, and registering the same .proto file
  # into it twice is a hard `Check failed: GeneratedDatabase()->Add(...)` → abort, not a warning. This
  # library ends up loaded TWICE in a game's address space (it is both preloaded and discoverable in the
  # game dir, and box64's guest loader does not dedup the way glibc's dev:ino check would), so with a
  # SHARED libprotobuf both instances register gbe_fork's own `steammessages.proto` into the one pool and
  # the game dies during init:
  #
  #     descriptor_database.cc:683] File already exists in database: steammessages.proto
  #     descriptor.cc:2531] Check failed: GeneratedDatabase()->Add(encoded_file_descriptor, size)
  #
  # Observed as an immediate SIGABRT in hollow-knight. Upstream's premake links every vendored dependency
  # with its `:static` modifier and hides them with `-Wl,--exclude-libs,ALL`, which gives each instance a
  # PRIVATE descriptor pool and makes the double load harmless. Static here reproduces exactly that.
  #
  # PIC is required because these archives are linked INTO a shared object; nixpkgs' static builds
  # normally assume a fully-static world where it is not.
  staticPic =
    drv:
    drv.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_POSITION_INDEPENDENT_CODE=ON" ];
    });
  # `abseil-cpp` is only an alias that forwards `cxxStandard`; the `static` knob lives on the versioned
  # LTS package underneath it (nixpkgs keeps one per LTS branch deliberately — abseil treats every LTS as
  # a new major version).
  abseilStatic = staticPic (abseil-cpp_202601.override { static = true; });
  protobufStatic = staticPic (
    protobuf.override {
      enableShared = false;
      abseil-cpp = abseilStatic;
    }
  );
  # libssq — a small Source-server-query library gbe_fork calls from dll/source_query.cpp. Not in nixpkgs;
  # upstream vendors it as a tarball on an orphan branch of its own repo. Its companion `EDIT.diff` is
  # DELIBERATELY not applied: the edit is already present in the shipped tarball (src/error.c line 36 reads
  # `NULL` with no trailing comma), so `patch` fails on it — and the hunk sits inside `#ifdef _WIN32` around
  # a `FormatMessage` call, so it could not affect a Linux build either way.
  libssq = fetchurl {
    url = "https://github.com/Detanup01/gbe_fork/raw/third-party/deps/common/libssq/libssq.tar.gz";
    hash = "sha256-6Shg+P+U4ESFF0tuB1+sjdVqXrrLskXM7g2BBPowdPQ=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "gbe-fork-shim";
  inherit version;

  # NO `fetchSubmodules`: the submodules are orphan branches carrying vendored dependency tarballs and — in
  # `third-party/deps/linux` — prebuilt x86_64 `7za` and `cmake` binaries. None of it is used here, and on an
  # aarch64 host qemu binfmt would run those foreign binaries slowly instead of refusing them.
  src = fetchFromGitHub {
    owner = "Detanup01";
    repo = "gbe_fork";
    tag = "release-${finalAttrs.version}";
    hash = "sha256-W1iIOcbmw+r4GlC0UzEJw+Ir9DUE0yt41GdvFVHXhsg=";
  };

  # protoc must run on the BUILD machine even when the library is cross-compiled for another host.
  nativeBuildInputs = [ buildPackages.protobuf ];
  buildInputs = [
    protobufStatic
    abseilStatic
    curl
    mbedtls
    libopus
    portaudio
  ];

  strictDeps = true;
  dontConfigure = true;

  # `EMU_BUILD_STRING` is only ever stringified into a debug print (dll/settings_parser.cpp), and upstream
  # defaults it to `os.date(…)`. Pin it to the release tag so the build is reproducible.
  buildPhase = ''
    runHook preBuild

    tar xf ${libssq}
    ssq="$PWD/libssq"

    # ── generated protobuf ── THREE invocations, not one: dll/steam_game_coordinator.cpp includes
    # <steammessages.pb.h> and the five <tf2/*.pb.h>, and the build hard-fails without them.
    mkdir -p proto_gen/linux/tf2
    protoc dll/gc_steam/steammessages.proto -I./dll/gc_steam --cpp_out=proto_gen/linux
    protoc dll/gc_tf2/*.proto -I./dll/gc_steam -I./dll/gc_tf2 --cpp_out=proto_gen/linux/tf2
    protoc dll/net.proto -I./dll/ --cpp_out=proto_gen/linux

    includes=(
      -Idll -Iproto_gen/linux -Ilibs -Ilibs/utfcpp -Ihelpers -Icrash_printer -Isdk
      -Ioverlay_experimental -I"$ssq/include"
    )
    # CURL_STATICLIB is upstream's, for its statically-linked vendored curl; against a shared curl the macro
    # expands identically on GCC (curl.h falls through every branch to an empty CURL_EXTERN), so it is
    # dropped rather than carried as a lie about how this is linked.
    defines=(
      -DUTF_CPP_CPLUSPLUS=201703L -DCONTROLLER_SUPPORT
      -DEMU_BUILD_STRING=release_${finalAttrs.version}
      -DGNUC -DNDEBUG -DEMU_RELEASE_BUILD
    )
    # premake5.lua × premake-core's own gcc tool: optimize"On"→-O2, symbols"Off"→no -g, SharedLib→-fPIC,
    # visibility"Hidden"→-fvisibility=hidden, the gmake buildoptions→-fno-jump-tables -Wno-switch, and
    # -fno-char8_t on C++ only. `-fvisibility-inlines-hidden` is NOT passed: that is premake's separate
    # `inlinesvisibility` option, which gbe_fork never sets, so upstream's own builds do not get it.
    common=( -O2 -fPIC -fvisibility=hidden -fno-jump-tables -Wno-switch )
    cxxflags=( -std=c++17 -fno-char8_t "''${common[@]}" )
    cflags=( -std=gnu17 "''${common[@]}" )

    # ── the api_regular file set (premake `common_files`, system:not windows) ── dll/wrap.cpp IS built here
    # (only Windows removes it); libs/detours/** is Windows-only (`removefiles { detours_files }`);
    # overlay_experimental/** belongs to api_experimental and is an include dir only.
    mapfile -t src_cxx < <(
      {
        find dll -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' \)
        find proto_gen/linux -type f -name '*.cc'
        find libs -path libs/detours -prune -o -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' \) -print
        echo crash_printer/linux.cpp
        echo helpers/common_helpers.cpp
        echo helpers/dbg_log.cpp
        find helpers/common_helpers helpers/dbg_log -type f \( -name '*.cpp' -o -name '*.cc' \)
      } | sort -u
    )
    mapfile -t src_c < <( find libs -path libs/detours -prune -o -type f -name '*.c' -print | sort -u )
    # libssq is an independent library: gbe's -D/-I do not apply, but its own private headers live in src/.
    mapfile -t src_ssq < <( find "$ssq/src" -type f -name '*.c' | sort -u )
    echo "gbe_fork: ''${#src_cxx[@]} C++ + ''${#src_c[@]} C + ''${#src_ssq[@]} libssq translation units"

    mkdir -p _obj
    : > _obj/.cmds
    # KEEP THE EXTENSION in the object name. Stripping it collapses same-stem sources onto one object —
    # `dll/foo.c` vs `dll/foo.cpp`, or `a/b_c.cpp` vs `a/b/c.cpp` once `/` becomes `_` — which under
    # `xargs -P` is a parallel-write race whose losing translation unit then vanishes silently, because the
    # link picks up `_obj/*.o` by glob and `--start-group` resolves what remains. The symptom would be a
    # missing entry point at game time: "loads but is missing entry points" is worse than no shim at all.
    objof() { echo "_obj/$(echo "''${1#/}" | tr '/' '_' | tr '.' '_').o"; }
    for s in "''${src_cxx[@]}"; do
      printf '%s %s %s %s -c %q -o %q\n' "$CXX" "''${cxxflags[*]}" "''${defines[*]}" "''${includes[*]}" "$s" "$(objof "$s")" >> _obj/.cmds
    done
    for s in "''${src_c[@]}"; do
      printf '%s %s %s %s -c %q -o %q\n' "$CC" "''${cflags[*]}" "''${defines[*]}" "''${includes[*]}" "$s" "$(objof "$s")" >> _obj/.cmds
    done
    for s in "''${src_ssq[@]}"; do
      printf '%s %s -I%q -I%q -c %q -o %q\n' "$CC" "''${cflags[*]}" "$ssq/include" "$ssq/src" "$s" "$(objof "$s")" >> _obj/.cmds
    done
    xargs -d '\n' -P "''${NIX_BUILD_CORES:-1}" -n 1 sh -c 'eval "$1" || { echo "FAILED: $1" >&2; exit 255; }' sh < _obj/.cmds

    # ── link ── `linkgroups "On"` → --start-group; `linkoptions` → --exclude-libs,ALL, which is what keeps
    # the statically-absorbed libssq symbols (and anything else) out of .dynsym: this library is LD_PRELOADed
    # FIRST into a game process, so an exported dependency symbol would interpose the game's own copy.
    #
    # One deviation from upstream's `deps_link`, measured: SDL3 is dropped (api_regular has zero SDL
    # references — upstream's link table is shared with the overlay projects, which are the real consumers,
    # and keeping it added a DT_NEEDED for nothing).
    #
    # protobuf and abseil are linked as ARCHIVES BY PATH, and every archive in both prefixes is passed
    # rather than a hand-picked few. A static `libprotobuf.a` carries no DT_NEEDED, so nothing resolves its
    # abseil references transitively the way the shared build did — each archive actually used has to be on
    # the line. Upstream names ~115 `absl_*` archives explicitly for exactly this reason; globbing the
    # prefix is the same thing without a list that silently rots on every abseil bump. `--start-group`
    # makes the order irrelevant, and `--exclude-libs,ALL` keeps every absorbed symbol out of `.dynsym`.
    $CXX -shared -o libsteam_api.so -Wl,-soname=libsteam_api.so _obj/*.o \
      -Wl,--start-group \
        ${protobufStatic}/lib/*.a ${abseilStatic}/lib/*.a \
        -lpthread -ldl -lcurl -lmbedcrypto -lmbedtls -lmbedx509 \
        -lopus -lportaudio \
      -Wl,--end-group \
      -Wl,--exclude-libs,ALL

    runHook postBuild
  '';

  # The consumer copies this file next to a generated settings tree, so the BASENAME is contractual
  # (lib/builders/steam-offline-entitlement.nix), as is the SONAME — the game's own binary carries
  # `NEEDED libsteam_api.so`.
  installPhase = ''
    runHook preInstall
    install -Dm444 libsteam_api.so "$out/lib/libsteam_api.so"
    # LGPL notices travel with the binary. These are the upstream source's own files, so they document
    # exactly the revision this `.so` was built from.
    install -Dm444 -t "$out/share/doc/gbe_fork" LICENSE CHANGELOG.md CREDITS.md README.md
    runHook postInstall
  '';

  # A foreign-ABI build that silently came out host-arch (a cross set that fell back to the build platform,
  # or a qemu-emulated "native" build) is otherwise indistinguishable from a correct one, and the first
  # symptom would be a game-time "wrong ELF class" at LD_PRELOAD. Assert the machine type.
  #
  # In `postInstall`, NOT `installCheckPhase`: nixpkgs gates `doInstallCheck` on
  # `canExecuteHostOnBuild`, so an installCheck never runs on a cross build — which is precisely the case
  # this guard exists for. `buildPackages.file` is a build-platform binary, so it runs either way.
  postInstall = ''
    got=$(${buildPackages.file}/bin/file -b "$out/lib/libsteam_api.so")
    echo "gbe_fork shim (${stdenv.hostPlatform.system}): $got"
    case "$got" in
      *${lib.escapeShellArg (if stdenv.hostPlatform.isAarch64 then "ARM aarch64" else "x86-64")}*) ;;
      *) echo "ERROR: built for the wrong architecture (wanted ${stdenv.hostPlatform.system})" >&2; exit 1 ;;
    esac
  '';

  passthru = { inherit libssq; };

  meta = {
    description = "gbe_fork api_regular (libsteam_api.so) built from source for ${stdenv.hostPlatform.system} — offline Steam entitlement shim";
    homepage = "https://github.com/Detanup01/gbe_fork";
    license = lib.licenses.lgpl3Only;
    platforms = lib.platforms.linux;
  };
})
