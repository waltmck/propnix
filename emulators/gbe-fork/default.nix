# emulators/gbe-fork — the offline Steam-entitlement shim, assembled PER-ABI for every platform this host
# can serve. `steam-emu` picks the arm matching the payload's `emulatedPlatform`, because the library is
# loaded INTO the game's own process and must therefore be that process's architecture.
#
# THE WHOLE PACKAGE IS THIS FILE plus two builds it calls out to, and that is deliberate — read the
# closure note below before folding them in. What it produces:
#
#   linuxShims.{aarch64,x64,x86}   from source (./shim.nix), one instantiation per Linux ABI
#   winPrebuilt                    steam_api(64).dll + the SteamStub patcher, from the pinned release
#   steamStubProxy                 a tiny from-source PE for SteamStub-wrapped exes (./steamstub-proxy.nix)
#
# The Linux shims are BUILT FROM SOURCE, one instantiation per ABI:
#
#   * the HOST's own arch      — an ordinary native build.
#   * every other Linux ABI    — a CROSS build (`pkgsCross.gnu64` / `.gnu32` /
#                                `.aarch64-multiplatform`), so the compiler runs natively and produces
#                                foreign code. NOT a native foreign instantiation
#                                (`pkgsX86.callPackage`): that would be an x86_64 BUILD, which qemu binfmt
#                                on an aarch64 host turns into a slow success rather than an honest
#                                failure. Nobody should have to trust a binary cache to get these bytes —
#                                cross-compiling keeps them locally reproducible.
#
# i686 IS INCLUDED IN THAT RULE, on every host. It is tempting to special-case it on an x86_64 builder,
# where `pkgsi686Linux` would be a native build with a fully-populated upstream cache — but that is the
# cache making the decision, and the requirement here is that the bytes stay buildable when the cache is
# gone. `pkgsCross.gnu32` gets there with a natively-running compiler on BOTH hosts; the only thing the
# x86_64 builder needs is the check-phase normalization below, not a different package set.
#
# The WINDOWS PE shims are upstream's PREBUILT release artifacts, pinned to the SAME tag as the source so a
# game's two flavours can never disagree about which Steamworks surface they implement. A from-source mingw
# build of the Windows file set was written and then REMOVED: its only consumer was a patch answering
# Valve's pre-SteamStub `STEAM_DRM_IPC` handshake for Civ V, and that title turned out to be unrunnable for
# an unrelated reason (a CEG-stripped executable — see pkgs/games/civilization-5), leaving ~400 lines of
# mingw protobuf/curl/mbedtls plumbing with nothing to serve. `git log` has it if a title ever needs
# patched Windows bytes.
#
# WHY NOT ONE DERIVATION CONTAINING EVERYTHING. It would cost every steam.emu game the whole set. The
# per-ABI attrs are LAZY and games index them directly (lib/modules/steam-emu.nix), so a wine-only title
# pulls no Linux shim and no pkgsCross bootstrap, and a title that never sets `steam.emu.steamStub` pulls
# no mingw toolchain at all. The symlinkJoin at the bottom is the "everything" view — build it with
# `nix build .#gbeFork` for CI and cachix — but nothing in a game's closure points at it.
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

  # The i686 cross set, with the THREE test suites nixpkgs runs only here switched off.
  #
  # `doCheck` on a cross build follows `buildPlatform.canExecute hostPlatform`, and an x86_64 builder CAN
  # execute i686 — so `pkgsCross.gnu32` is the one cross target whose dependencies run their test suites,
  # and only when built from an x86_64 host. From this aarch64 host the very same packages have
  # `doCheck = false`, which is why the aarch64 CI leg builds this chain green while the x86_64 leg died
  # in cross-`sqlite`'s suite (`libgcc_s.so.1 must be installed for pthread_exit to work`), taking
  # dbus/libjack2/portaudio and the shim with it.
  #
  # Turning them off makes x86_64 behave like every other builder rather than inventing a policy: these
  # are upstream test suites for libraries we merely consume, in a configuration nixpkgs itself exercises
  # by accident. All three are listed rather than one, because the two that never ran are unproven, not
  # known-good. Re-derive the list after a nixpkgs bump with:
  #   nix eval --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).pkgsCross.gnu32.<pkg>.doCheck'
  # Conditioned on the exact predicate that turns the checks ON, so the two can never disagree — and so
  # the builders where nothing runs keep byte-identical outputs. That second part is not cosmetic:
  # `appendOverlays` re-instantiates the whole fixpoint, so applying it unconditionally moved every
  # dependency hash in this shim (including build-side ones) on aarch64, for a no-op.
  gnu32Base = pkgs.pkgsCross.gnu32;
  gnu32ChecksWouldRun = gnu32Base.stdenv.buildPlatform.canExecute gnu32Base.stdenv.hostPlatform;
  gnu32 =
    if !gnu32ChecksWouldRun then
      gnu32Base
    else
      gnu32Base.appendOverlays [
        (
          _: prev:
          # The i686 SIDE ONLY. An overlay reaches `buildPackages` as well, where these are the ordinary
          # native packages Hydra already built and tested — overriding them there rebuilds the native
          # world instead (native python3 links sqlite, so sphinx/meson/gobject-introspection/rustc/
          # fontforge follow: 291 derivations, measured, against 11 for the cross chain alone).
          lib.optionalAttrs (prev.stdenv.hostPlatform.system == "i686-linux") (
            lib.genAttrs [ "sqlite" "dbus" "mbedtls" ] (
              n:
              prev.${n}.overrideAttrs (_: {
                doCheck = false;
              })
            )
          )
        )
      ];

  # One shim per Linux ABI. `pkgsCross.*` is instantiated FROM this host's pkgs, so the cross toolchain is
  # host-native; the ABI whose name matches the host resolves to the plain (non-cross) build.
  crossFor =
    system:
    if system == stdenv.hostPlatform.system then
      pkgs
    else if system == "i686-linux" then
      gnu32
    else if system == "x86_64-linux" then
      pkgs.pkgsCross.gnu64
    else
      pkgs.pkgsCross.aarch64-multiplatform;
  shimFor = system: (crossFor system).callPackage ./shim.nix { };

  # Every ABI, as LAZY attrs. Consumers index this directly (lib/modules/steam-emu.nix) so a game pulls
  # only the shim its own payload will load — indexing the assembled tree below would make every
  # steam.emu game force all of them, i.e. a full pkgsCross bootstrap on this host.
  #
  # `x86` is the 32-bit Linux ABI, and it is not hypothetical: Aspyr's Civ V Linux build is a 32-bit x86
  # ELF, which is the whole reason emulators/fex-linux exists. Keys match the Windows side's x64/x86
  # naming so both flavours of a game read the same way.
  linuxShims = {
    "aarch64" = shimFor "aarch64-linux";
    "x64" = shimFor "x86_64-linux";
    "x86" = shimFor "i686-linux";
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
    inherit
      version
      linuxShims
      winPrebuilt
      ;
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
