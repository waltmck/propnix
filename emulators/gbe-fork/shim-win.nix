# emulators/gbe-fork/shim-win.nix — the WINDOWS twin of ./shim.nix: gbe_fork's `api_regular` target as a PE
# (`steam_api64.dll`) for a Windows process architecture upstream publishes no prebuilt for. Instantiated
# per target through `winPkgs.<target>` (lib/default.nix) with the target's lib/win-toolchain.nix record;
# its libraries come from ./win-deps.nix, built static for the same target.
#
# WHY. The x64 and x86 PEs are upstream's prebuilt release artifacts (./default.nix, `winPrebuilt`). A
# NATIVE ARM64 Windows process — Unity's ARM64 player under wine on aarch64, lib/modules/unity-player.nix
# — loads ARM64 DLLs only, and upstream's premake knows an ARM64 platform but no release ships one. The
# shim is loaded INTO the game's process, so it must be that process's architecture; this is the one
# from-source Windows build, and that process is what it exists for.
#
# WHAT IS BUILT. The description ./shim.nix drives — premake5.lua's `api_regular` project — read for its
# `system:windows` filters instead of `not windows`: `dll/wrap.cpp` (the Linux `__wrap_*` hooks) is out,
# `crash_printer/win.cpp` is in for `linux.cpp`, libs/detours stays out (api_regular removes it; the
# Detours calls in dll/base.cpp are under EMU_EXPERIMENTAL_BUILD), the Windows defines and system
# libraries of `common_link_win` are used, and the link is `-static` — upstream's own MinGW rule, so the
# DLL carries its C++ runtime rather than importing one. Every deviation from what premake would emit is
# at its site below.
#
# THE PIN IS NOT HERE. `src`, `version` and the vendored libssq tarball are threaded from ./default.nix's
# one pin, so this flavour can never implement a different Steamworks surface than the Linux shims and the
# prebuilt PEs do.
#
# THE ACCEPTANCE GATE is an EXPORT DIFF against upstream's prebuilt x64 `steam_api64.dll`: the set of
# exported names must be identical. A shim that loads but lacks an entry point is worse than no shim —
# the game's SteamAPI init throws instead of failing cleanly (./shim.nix has the precedent) — and the
# prebuilt is the authority on what one release exports. Two more checks: the COFF machine is the
# target's (lib/pe-check.py), and every import is a Windows system DLL (a dependency that slipped in
# shared would be a DLL no game directory holds).
{
  lib,
  stdenvNoCC,
  python3,
  protobuf, # the host's: protoc runs on the build machine; the generated code links ./win-deps.nix's runtime
  toolchain,
  target,
  winDeps,
  winPrebuilt,
  src,
  version,
  libssq,
}:
stdenvNoCC.mkDerivation {
  pname = "gbe-fork-shim-${target}";
  inherit version src;

  nativeBuildInputs = toolchain.nativeBuildInputs ++ [
    protobuf
    python3
  ];
  strictDeps = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    tar xf ${libssq}
    ssq="$PWD/libssq"

    # ── generated protobuf ── the three invocations ./shim.nix explains, into premake's `proto_gen/win`.
    mkdir -p proto_gen/win/tf2
    protoc dll/gc_steam/steammessages.proto -I./dll/gc_steam --cpp_out=proto_gen/win
    protoc dll/gc_tf2/*.proto -I./dll/gc_steam -I./dll/gc_tf2 --cpp_out=proto_gen/win/tf2
    protoc dll/net.proto -I./dll/ --cpp_out=proto_gen/win

    # Windows resolves includes case-insensitively and the sources spell SDK headers as the SDK does
    # (`DbgHelp.h`, `WinSock2.h`); mingw-w64 ships them lowercase and the sandbox's filesystem is exact.
    # `_inc` maps every bare header name the sources use that the compiler's own search path has only
    # under another spelling onto that file. Project headers carry a path and are exact as written.
    mapfile -t sysincs < <(${toolchain.cxx} -E -x c++ -v - </dev/null 2>&1 \
      | sed -n '/^#include <...> search starts here:/,/^End of search list\./p' | grep '^ ' | sed 's/^ //')
    mkdir -p _inc
    grep -rhoE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"][^>"]+[>"]' dll helpers crash_printer libs sdk \
      | sed -E 's/.*[<"]([^>"]+)[>"].*/\1/' | sort -u | while read -r h; do
      case "$h" in */*) continue ;; esac
      for d in "''${sysincs[@]}"; do [ -e "$d/$h" ] && continue 2; done
      for d in "''${sysincs[@]}"; do
        m=$(find -H "$d" -maxdepth 1 -iname "$h" -print -quit)   # -H: the toolchain's include dirs are symlinks
        [ -n "$m" ] && { ln -s "$m" "_inc/$h"; echo "include spelling: $h -> $m"; break; }
      done
    done

    includes=(
      -I_inc -Idll -Iproto_gen/win -Ilibs -Ilibs/utfcpp -Ihelpers -Icrash_printer -Isdk
      -Ioverlay_experimental -I"$ssq/include"
      -I${winDeps.curl}/include -I${winDeps.protobuf}/include -I${winDeps.abseil}/include
      -I${winDeps.zlib}/include -I${winDeps.mbedtls}/include -I${winDeps.opus}/include
      -I${winDeps.portaudio}/include
    )
    # `common_emu_defines` + the release and Windows filters + the MinGW-on-Windows define
    # (_CRT_DECLARE_NONSTDC_NAMES: `_S_IFDIR` for base.cpp). CURL_STATICLIB is upstream's and is REQUIRED
    # here: without it curl.h declares every entry point dllimport and the static archive cannot satisfy it.
    defines=(
      -DUTF_CPP_CPLUSPLUS=201703L -DCURL_STATICLIB -DCONTROLLER_SUPPORT
      -DEMU_BUILD_STRING=release_${version}
      -DNDEBUG -DEMU_RELEASE_BUILD
      -D_CRT_SECURE_NO_WARNINGS -D_CRT_DECLARE_NONSTDC_NAMES
    )
    # optimize"On"→-O2, symbols"Off"→no -g, the gmake buildoptions→-fno-jump-tables -Wno-switch, and
    # -fno-char8_t on C++ only. No -fPIC (PE code is position-independent by construction) and no
    # -fvisibility (an ELF notion; a PE exports what is declared dllexport, which is STEAM_API_EXPORTS'
    # job — dll/dll/common_includes.h defines it).
    common=( -O2 -fno-jump-tables -Wno-switch )
    cxxflags=( -std=c++17 -fno-char8_t "''${common[@]}" )
    cflags=( -std=gnu17 "''${common[@]}" )

    # ── the api_regular file set (premake `common_files`, system:windows) ── dll/wrap.cpp removed,
    # libs/detours/** removed (`removefiles { detours_files }`), crash_printer/win.cpp. The VERSIONINFO
    # resource (resources/win/api/64/resources.rc, premake's `winrsrc` option) is not compiled in: it is
    # release metadata — a file version and copyright string mimicking Valve's — that nothing reads.
    mapfile -t src_cxx < <(
      {
        find dll -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' \) ! -path dll/wrap.cpp
        find proto_gen/win -type f -name '*.cc'
        find libs -path libs/detours -prune -o -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.cxx' \) -print
        echo crash_printer/win.cpp
        echo helpers/common_helpers.cpp
        echo helpers/dbg_log.cpp
        find helpers/common_helpers helpers/dbg_log -type f \( -name '*.cpp' -o -name '*.cc' \)
      } | sort -u
    )
    mapfile -t src_c < <( find libs -path libs/detours -prune -o -type f -name '*.c' -print | sort -u )
    # libssq is an independent library: gbe's -D/-I do not apply, but its own private headers live in src/.
    mapfile -t src_ssq < <( find "$ssq/src" -type f -name '*.c' | sort -u )
    echo "gbe_fork (${target}): ''${#src_cxx[@]} C++ + ''${#src_c[@]} C + ''${#src_ssq[@]} libssq translation units"

    mkdir -p _obj
    : > _obj/.cmds
    # The object name keeps the source's extension — ./shim.nix has the same-stem race this avoids.
    objof() { echo "_obj/$(echo "''${1#/}" | tr '/' '_' | tr '.' '_').o"; }
    for s in "''${src_cxx[@]}"; do
      printf '%s %s %s %s -c %q -o %q\n' "${toolchain.cxx}" "''${cxxflags[*]}" "''${defines[*]}" "''${includes[*]}" "$s" "$(objof "$s")" >> _obj/.cmds
    done
    for s in "''${src_c[@]}"; do
      printf '%s %s %s %s -c %q -o %q\n' "${toolchain.cc}" "''${cflags[*]}" "''${defines[*]}" "''${includes[*]}" "$s" "$(objof "$s")" >> _obj/.cmds
    done
    for s in "''${src_ssq[@]}"; do
      printf '%s %s -I%q -I%q -c %q -o %q\n' "${toolchain.cc}" "''${cflags[*]}" "$ssq/include" "$ssq/src" "$s" "$(objof "$s")" >> _obj/.cmds
    done
    xargs -d '\n' -P "''${NIX_BUILD_CORES:-1}" -n 1 sh -c 'eval "$1" || { echo "FAILED: $1" >&2; exit 255; }' sh < _obj/.cmds

    # ── link ── `-static` (the MinGW-on-Windows linkoption) and `linkgroups "On"` → --start-group. The
    # gmake `--exclude-libs,ALL` is an ELF notion with no COFF counterpart (lld's PE driver rejects it,
    # and a PE exports only what is declared dllexport). `common_link_win` names the Windows libraries;
    # `deps_link` the static dependencies, SDL3 dropped as in ./shim.nix (api_regular has no SDL
    # reference). ole32, setupapi, uuid,
    # shell32, user32 and advapi32 are named here though premake does not list them: on Visual Studio they
    # arrive through the project's default library list and portaudio's `#pragma comment(lib)`, which a
    # mingw link has no equivalent of; pthread is mingw's winpthreads, which abseil's thread identity
    # reaches through mingw's pthread.h and which `-static` folds in like every other library. protobuf
    # and abseil are linked as archives by path, every archive of both prefixes — ./shim.nix has why no
    # hand-picked list.
    ${toolchain.cxx} -shared -static -o steam_api64.dll _obj/*.o \
      -Wl,--start-group \
        ${winDeps.protobuf}/lib/*.a ${winDeps.abseil}/lib/*.a \
        -L${winDeps.curl}/lib -lcurl \
        -L${winDeps.mbedtls}/lib -lmbedtls -lmbedx509 -lmbedcrypto \
        -L${winDeps.zlib}/lib -lz \
        -L${winDeps.opus}/lib -lopus \
        -L${winDeps.portaudio}/lib -lportaudio \
        -lws2_32 -liphlpapi -lwldap32 -lwinmm -lbcrypt -ldbghelp -lntdll -lxinput -lgdi32 -ldwmapi -lopengl32 \
        -lole32 -lsetupapi -luuid -lshell32 -luser32 -ladvapi32 -lpthread \
      -Wl,--end-group

    runHook postBuild
  '';

  # The BASENAME is contractual (the game's import table names `steam_api64.dll`), as it is for the Linux
  # shims' SONAME; the consumer (lib/modules/steam-emu.nix) places the file where its process resolves it.
  installPhase = ''
    runHook preInstall
    install -Dm444 steam_api64.dll "$out/lib/steam_api64.dll"
    # LGPL notices travel with the binary: the upstream source's own files, for the revision built.
    install -Dm444 -t "$out/share/doc/gbe_fork" LICENSE CHANGELOG.md CREDITS.md README.md
    runHook postInstall
  '';

  # The three gates, in `postInstall` for the reason ./shim.nix gives (an installCheck never runs for a
  # foreign target). Import names are compared case-insensitively: the loader does, and link libraries
  # spell them differently from one toolchain to the next.
  postInstall = ''
    dll="$out/lib/steam_api64.dll"
    ${toolchain.checkPe} "$dll"

    llvm-readobj --coff-imports "$dll" | awk '/^ *Name:/ { print tolower($2) }' | sort -u > imports.txt
    echo "imports: $(tr '\n' ' ' < imports.txt)"
    bad=$(grep -vE '^(advapi32|bcrypt|crypt32|dbghelp|dwmapi|gdi32|iphlpapi|kernel32|msvcrt|ntdll|ole32|oleaut32|opengl32|secur32|setupapi|shell32|ucrtbase|user32|winmm|wldap32|ws2_32|xinput[0-9_]*|api-ms-win-crt-[a-z0-9-]+)\.dll$' imports.txt || true)
    [ -z "$bad" ] || { echo "propnix: the shim imports non-system DLLs — a dependency was linked shared:"; echo "$bad"; exit 1; }

    llvm-readobj --coff-exports "$dll" | awk '/^ *Name:/ { print $2 }' | sort -u > ours.txt
    llvm-readobj --coff-exports ${winPrebuilt}/share/gbe_fork/win/x64/steam_api64.dll \
      | awk '/^ *Name:/ { print $2 }' | sort -u > theirs.txt
    if ! diff -u theirs.txt ours.txt > exports.diff; then
      echo "propnix: the ${target} shim's export table differs from upstream's prebuilt x64 one:"
      cat exports.diff
      exit 1
    fi
    echo "exports: $(wc -l < ours.txt) names, identical to the prebuilt x64 release"
  '';

  dontStrip = true; # a PE; the host strip would not understand it, and lld already omits what -g would add

  meta = {
    description = "gbe_fork api_regular (steam_api64.dll) built from source for ${target} — offline Steam entitlement shim";
    homepage = "https://github.com/Detanup01/gbe_fork";
    license = lib.licenses.lgpl3Only;
    platforms = lib.platforms.linux;
  };
}
