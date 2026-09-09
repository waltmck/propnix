# emulators/gbe-fork — the offline Steam-entitlement shim, assembled PER-ABI for every platform this host
# can serve. `steam-emu` picks the arm matching the payload's `emulatedPlatform`, because the library is
# loaded INTO the game's own process and must therefore be that process's architecture.
#
# The Linux shims are BUILT FROM SOURCE (./shim.nix), one instantiation per ABI:
#
#   * the HOST's own arch      — an ordinary native build.
#   * the other Linux ABI      — a CROSS build (`pkgsCross.gnu64` / `pkgsCross.aarch64-multiplatform`),
#                                so the compiler runs natively and produces foreign code. NOT a native
#                                foreign instantiation (`pkgsX86.callPackage`): that would be an x86_64
#                                BUILD, which qemu binfmt on an aarch64 host turns into a slow success
#                                rather than an honest failure. Nobody should have to trust a binary cache
#                                to get these bytes — cross-compiling keeps them locally reproducible.
#
# The WINDOWS PE shims are still upstream's PREBUILT release artifacts, pinned to the SAME tag as the source
# so a game's two flavours can never disagree about which Steamworks surface they implement. Building those
# from source needs a mingw cross of the Windows file set (a different source list, `common_link_win`, and
# mingw builds of protobuf/curl/mbedtls/portaudio) and is the remaining piece of this migration — nothing in
# propnix's current platform set depends on it, since wine loads the PE and the prebuilt one works.
#
# ONE THING IS BUILT FROM SOURCE ON THE WINDOWS SIDE: `steamStubProxy` (./steamstub-proxy.nix), a tiny PE
# that stands in front of the shim for a SteamStub-wrapped exe. It is a separate, LAZY passthru — a game
# that does not set `steam.emu.steamStub` pulls neither it nor a mingw toolchain — and its whole
# justification (with the wine `+relay` measurements that establish the wrapper never asks the on-disk
# steam lib anything) lives in that file's header.
{
  lib,
  stdenv,
  stdenvNoCC,
  callPackage,
  pkgs,
  fetchurl,
  p7zip,
  symlinkJoin,
  # Cross-mingw toolchains for the SteamStub proxy (./steamstub-proxy.nix), threaded through verbatim; the
  # host leg picks which one exists. Optional so a scope that never asks for a proxy needs none of them.
  llvmMingw ? null,
  mingwGccW64 ? null,
  mingwGcc32 ? null,
  mingwThreads64 ? null,
  mingwThreads32 ? null,
}:
let
  version = "2026_07_19";

  # One shim per Linux ABI. `pkgsCross.*` is instantiated FROM this host's pkgs, so the cross toolchain is
  # host-native; the ABI whose name matches the host resolves to the plain (non-cross) build.
  crossFor =
    system:
    if system == stdenv.hostPlatform.system then
      pkgs
    else if system == "x86_64-linux" then
      pkgs.pkgsCross.gnu64
    else
      pkgs.pkgsCross.aarch64-multiplatform;
  shimFor = system: (crossFor system).callPackage ./shim.nix { };

  # Every ABI, as LAZY attrs. Consumers index this directly (lib/modules/steam-emu.nix) so a game pulls
  # only the shim its own payload will load — indexing the assembled tree below would make every
  # steam.emu game force all of them, i.e. a full pkgsCross bootstrap on this host.
  linuxShims = {
    "aarch64" = shimFor "aarch64-linux";
    "x64" = shimFor "x86_64-linux";
  };
  # …and the subset this host can actually USE, which is what the assembled tree carries. An x86_64 host
  # can never run aarch64 content (lib/strategy.nix `runnable`), so cross-building an aarch64 shim there
  # would be pure cost — the attr stays evaluable for the CI matrix, it just isn't realized.
  usableShims = lib.filterAttrs (
    arch: _: arch != "aarch64" || stdenv.hostPlatform.isAarch64
  ) linuxShims;

  # The Windows drop-in replacements a wine game loads from its own tree (steam-emu's union-replacement).
  # Import tables carry only KERNEL32/USER32/WS2_32/IPHLPAPI (static CRT) — all wine builtins, nothing for
  # the prefix to add.
  winPrebuilt = stdenvNoCC.mkDerivation {
    pname = "gbe-fork-win-prebuilt";
    inherit version;
    src = fetchurl {
      url = "https://github.com/Detanup01/gbe_fork/releases/download/release-${version}/emu-win-release.7z";
      hash = "sha256-O6hV75YiBRNqVPsyUZpGNi4MxbQvwrs2Z+TSEwfZcuU=";
    };
    nativeBuildInputs = [ p7zip ];
    dontUnpack = true;
    # Foreign-arch prebuilt PE code — keep the bytes verbatim (they are loaded by wine's PE loader, never by
    # the host loader).
    dontStrip = true;
    dontPatchELF = true;
    installPhase = ''
      runHook preInstall
      7z x -y "$src" 'release/regular/x64/steam_api64.dll' 'release/regular/x86/steam_api.dll' \
        'release/steamclient_experimental/extra_dlls/steamclient_extra_x64.dll' \
        'release/steamclient_experimental/extra_dlls/steamclient_extra_x86.dll' -owin > /dev/null
      install -Dm444 win/release/regular/x64/steam_api64.dll "$out/share/gbe_fork/win/x64/steam_api64.dll"
      install -Dm444 win/release/regular/x86/steam_api.dll "$out/share/gbe_fork/win/x86/steam_api.dll"
      # The SteamStub v3.1 in-memory patcher, from the SAME release archive so it can never disagree with
      # the shim it is staged beside. Upstream files it under the cold-client-loader tree because that is
      # how THEY deliver it (process injection); propnix loads it from a static-import DllMain instead —
      # see emulators/gbe-fork/steamstub-proxy.nix, which is the only consumer.
      install -Dm444 win/release/steamclient_experimental/extra_dlls/steamclient_extra_x64.dll \
        "$out/share/gbe_fork/win/x64/steamclient_extra_x64.dll"
      install -Dm444 win/release/steamclient_experimental/extra_dlls/steamclient_extra_x86.dll \
        "$out/share/gbe_fork/win/x86/steamclient_extra_x86.dll"
      runHook postInstall
    '';
    meta.sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
in
# The assembled tree is for DISCOVERY and CI (`nix build .#gbeFork` builds every shim this host can use in
# one command, so cachix gets them). Games never reference it — see `linuxShims` above.
symlinkJoin {
  name = "gbe-fork-${version}";
  paths = [ winPrebuilt ];
  postBuild =
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (arch: shim: ''
        mkdir -p "$out/share/gbe_fork/${arch}"
        ln -s ${shim}/lib/libsteam_api.so "$out/share/gbe_fork/${arch}/libsteam_api.so"
      '') usableShims
    )
    # LGPL notices, from the host shim's source (same revision as every ABI's).
    + ''
      mkdir -p "$out/share/doc"
      ln -s ${
        linuxShims.${if stdenv.hostPlatform.isAarch64 then "aarch64" else "x64"}
      }/share/doc/gbe_fork \
        "$out/share/doc/gbe_fork"
    '';
  passthru = {
    inherit version linuxShims winPrebuilt;
    # The SteamStub arm, as a FUNCTION (steam-emu calls it per declared `.dll` libPath). Lazy like
    # `linuxShims`: a game that never sets `steam.emu.steamStub` pulls no mingw toolchain.
    steamStubProxy = callPackage ./steamstub-proxy.nix {
      inherit
        llvmMingw
        mingwGccW64
        mingwGcc32
        mingwThreads64
        mingwThreads32
        ;
    };
    # The host's own build, for a `nix build .#gbeFork.native` smoke test.
    native = shimFor stdenv.hostPlatform.system;
  };
  meta = {
    description = "Steam API reimplementation (Goldberg emulator fork) — per-ABI offline entitlement shim: Linux built from source, Windows PE from the pinned release";
    homepage = "https://github.com/Detanup01/gbe_fork";
    license = lib.licenses.lgpl3Only;
    # The join redistributes upstream's prebuilt PE DLLs alongside the from-source Linux shims, and this
    # is what closure-level provenance tooling sees — the inner `winPrebuilt`'s own meta is invisible here.
    sourceProvenance = [
      lib.sourceTypes.fromSource
      lib.sourceTypes.binaryNativeCode
    ];
  };
}
