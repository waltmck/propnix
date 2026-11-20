# emulators/unity-player — Unity's own NATIVE ARM64 Windows player, per Unity version: `UnityPlayer.dll`,
# the `WindowsPlayer.exe` stub and the crash handler, extracted from the editor's "Windows Build Support
# (Mono)" module as Unity publishes it for each release. lib/modules/unity-player.nix puts it in place of a
# title's x64 player, so on aarch64 the whole process runs as native ARM64 under wine — the engine, the Mono
# runtime (ours, emulators/unity-mono) and the game's IL, with no x86 code left to emulate.
#
# WHAT UNITY PUBLISHES. For every editor release the download CDN carries the macOS target-support installer
#   https://download.unity3d.com/download_unity/<changeset>/MacEditorTargetInstaller/UnitySetup-Windows-Mono-Support-for-Editor-<version>.pkg
# an xar archive whose `TargetSupport.pkg.tmp/Payload` (gzip-compressed cpio) holds, under `Variations/`,
# the player binaries the editor copies into a build — `win64_player_nondevelopment_mono`,
# `win_arm64_player_nondevelopment_mono`, their `development` siblings. The ARM64 variation is a complete
# player for the Mono scripting backend: UnityPlayer.dll, the WindowsPlayer.exe stub (which derives
# `<name>_Data` from its own filename, so renaming it to the game's exe name is the whole integration),
# UnityCrashHandler64.exe and an ARM64 Mono runtime, all IMAGE_FILE_MACHINE_ARM64 without CHPE metadata.
# Unity added this player in 2023.1; earlier streams have no row to add. The release API maps a version to
# its changeset: https://services.api.unity.com/unity/editor/release/v1/releases?version=<version>.
#
# EVERY ROW IS VERIFIED, NOT ASSUMED: ci/unity-player-check.sh asks the release API for each version and
# HEADs the module URL on every CI run, and the scheduled workflow downloads and extracts each module
# against the same checks this derivation runs, so a module Unity re-publishes or withdraws is found
# before a user's build does.
#
# LICENSING AND CACHE POLICY. The module is Unity's proprietary binary. Each machine downloads it for
# itself (`allowSubstitutes = false`, as for every game payload), the derivations are unfree binary
# native code, and nothing here is ever pushed to the cache: ci/cache-audit.sh exempts unfree, and
# .github/workflows/cachix.yml names no attribute of this file.
#
# ADDING A VERSION. `propnix pin <game> --fingerprint` records a title's `unityVersion` and
# `unityChangeset`; look the version up on the release API, `nix-prefetch-url` the module URL (the hash
# below is the module's), and add the row. A row must be the title's EXACT release: a player loads only
# data whose per-type layout hashes match its own classes, and those drift between 6000.0.x patch
# releases, so a Unity-internal branch build (Silksong's `6000.0.50f1-uum-100966-branch1`) has no row to
# add until Unity publishes a module for it (docs/research/unity-arm64-player.md).
{
  lib,
  stdenvNoCC,
  fetchurl,
  xar,
  cpio,
  gzip,
  binutils, # `strings -el`: the player's UTF-16 version string
  python3,
}:
let
  # Hand-maintained: one row per Unity version a packaged title pins. `windowsMono` is the module's hash.
  versions = {
    "6000.0.61f1" = {
      changeset = "74a0adb02c31";
      windowsMono = "sha256-eQ+uwEnymAd5Yiz2R21tFtFbPYYbpL7WfHz8gj8eU4g=";
      # The module's size as the release API reports it; the CI check compares the CDN's Content-Length.
      downloadSize = 309040054;
    };
  };

  # The process platforms a native player exists for, and which `Variations/` entry serves each. A
  # desktop-Linux ARM64 player would be a second row here, with a module of its own.
  targets = {
    "aarch64-windows" = {
      variation = "win_arm64_player";
      machineHex = 43620; # IMAGE_FILE_MACHINE_ARM64
    };
  };
  variants = [
    "nondevelopment"
    "development"
  ];

  peCheck = builtins.path {
    path = ../../lib/pe-check.py;
    name = "pe-check.py";
  };

  moduleFor =
    version: row:
    (fetchurl {
      url = "https://download.unity3d.com/download_unity/${row.changeset}/MacEditorTargetInstaller/UnitySetup-Windows-Mono-Support-for-Editor-${version}.pkg";
      hash = row.windowsMono;
    }).overrideAttrs
      (old: {
        allowSubstitutes = false;
        preferLocalBuild = true;
        meta = (old.meta or { }) // {
          license = lib.licenses.unfree;
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        };
      });

  mkPlayer =
    version: row: target: t: variant:
    let
      variation = "${t.variation}_${variant}_mono";
    in
    stdenvNoCC.mkDerivation {
      pname = "unity-player-${target}-${variant}";
      inherit version;
      src = moduleFor version row;
      dontUnpack = true;
      nativeBuildInputs = [
        xar
        cpio
        gzip
        binutils
        python3
      ];
      inherit variation;
      expectedVersion = "${version} (${row.changeset})";

      # The installer's layout is not assumed: `Payload` is located wherever xar put it, and the cpio
      # pattern extracts the one variation.
      buildPhase = ''
        runHook preBuild
        xar -xf "$src"
        payload=$(find . -type f -name Payload | head -1)
        [ -n "$payload" ] || { echo "propnix: no Payload inside the module (xar layout changed?)"; find . -maxdepth 2; exit 1; }
        mkdir payload
        gzip -dc "$payload" | ( cd payload && cpio -idm --quiet "*/Variations/$variation/*" )
        var=$(find payload -type d -path "*/Variations/$variation" | head -1)
        [ -n "$var" ] || { echo "propnix: the module has no Variations/$variation:"; find payload -maxdepth 3 -type d -path '*/Variations/*'; exit 1; }
        runHook postBuild
      '';

      # The three PEs the module places beside a build, plus the module's own ARM64 Mono runtime under
      # `shipped-mono/` — the A/B reference for emulators/unity-mono's build of the same stream
      # (`unity.player.runtime = null`), never the default.
      installPhase = ''
        runHook preInstall
        install -Dm444 -t "$out" "$var/UnityPlayer.dll" "$var/WindowsPlayer.exe" "$var/UnityCrashHandler64.exe"
        install -Dm444 "$var/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll" "$out/shipped-mono/mono-2.0-bdwgc.dll"
        runHook postInstall
      '';

      # The two facts a consumer relies on, checked here rather than at a title's build: every PE is the
      # target's machine (and not an ARM64EC image, which no native process loads), and the player
      # reports exactly the version and changeset of its row — a row whose hash was taken from another
      # release's module would otherwise pair a game with a player it was not built for.
      postInstall = ''
        python3 ${peCheck} ${toString t.machineHex} 0 "$out"/*.dll "$out"/*.exe "$out"/shipped-mono/*.dll
        strings -el "$out/UnityPlayer.dll" > utf16.txt
        got=$(grep -oE -m1 '^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+[^ ]* \([0-9a-f]{12}\)' utf16.txt || true)
        [ "$got" = "$expectedVersion" ] || {
          echo "propnix: the module's player reports '$got', the row says '$expectedVersion'"; exit 1; }
        echo "propnix: Unity player $got, ${target} ${variant}"
      '';

      passthru = {
        inherit version target variant;
        inherit (row) changeset;
      };
      meta = {
        description = "Unity ${version} native ${target} player (${variant}, Mono scripting backend)";
        homepage = "https://unity.com/releases/editor/archive";
        license = lib.licenses.unfree;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        platforms = lib.platforms.linux;
      };
    };

  players = lib.mapAttrs (
    target: t:
    lib.mapAttrs (version: row: lib.genAttrs variants (mkPlayer version row target t)) versions
  ) targets;
in
players
// {
  inherit versions targets variants;
  # The module's lookup, with a legible miss: the player for a title's pinned version, or what to add.
  for =
    {
      version,
      target,
      variant ? "nondevelopment",
    }:
    players.${target}.${version}.${variant} or (throw (
      if !(targets ? ${target}) then
        "propnix: no native Unity player exists for ${target} (emulators/unity-player packages: ${lib.concatStringsSep ", " (lib.attrNames targets)})"
      else if !(versions ? ${version}) then
        "propnix: Unity ${version} has no native player row — add it to emulators/unity-player/default.nix (versions: ${lib.concatStringsSep ", " (lib.attrNames versions)}); the header has the recipe"
      else
        "propnix: unknown Unity player variant '${variant}' (one of: ${lib.concatStringsSep ", " variants})"
    ));
}
