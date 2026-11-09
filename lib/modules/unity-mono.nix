# The `unity.mono.*` namespace: a Windows Unity title whose scripting backend is Mono declares the Unity
# STREAM its player was built from, and on an aarch64 host under wine the stream's ARM64EC runtime
# (emulators/unity-mono) is unioned over the payload at the runtime's path, replacing the shipped x64
# `mono-2.0-bdwgc.dll` the player loads by name. Everything else in the payload stays as shipped.
#
# The runtime goes in as an `extraLowers` tree (lib/builders/unity-mono-tree.nix, which also checks the
# declaration against the payload's actual player at build time) — the mechanism steam-emu's settings tree
# uses, so no copy of the game is made and the replacement composes with DLC and the other extra lowers.
# It does NOT compose with `maskFiles`: a whiteout cannot sit in a multi-lower game dir (the maskFiles
# option docs); a title that masks a file keeps the shipped runtime until its mask is expressed otherwise.
#
# Active only where the runtime applies: a wine backend on an aarch64 host. Thin backends run the Linux
# build's own runtime, and x86_64 hosts run the shipped x64 runtime natively.
{
  lib,
  stdenv,
  mkUnityMonoTree,
}:
{ config, ... }:
let
  cfg = config;
  um = cfg.unity.mono;
  active = um.enable && um.stream != null && cfg.backend == "wine" && stdenv.hostPlatform.isAarch64;
in
{
  options.unity.mono = {
    stream = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "6000.0";
      description = ''
        The Unity stream (`<major>.<minor>` of the player's version string, e.g. "2022.3" or "6000.0")
        this title's player was built from. On an aarch64 host under wine, the stream's ARM64EC Mono
        runtime from emulators/unity-mono replaces the shipped x64 runtime in the game dir; the build
        refuses a declaration the player's own version string contradicts. null (the default): the
        shipped runtime runs under the emulator. Only Mono players apply — an IL2CPP build has no
        runtime to replace.
      '';
    };
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether a declared stream's ARM64EC runtime is used. `false` keeps the shipped x64 runtime under
        the emulator with the declaration in place — the A/B switch (`.apply { unity.mono.enable = false; }`).
      '';
    };
    playerPath = lib.mkOption {
      type = lib.types.str;
      default = "UnityPlayer.dll";
      description = "Game-dir-relative path of the Unity player, the version-string and entry-point source for the build-time check.";
    };
    runtimePath = lib.mkOption {
      type = lib.types.str;
      default = "MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll";
      description = "Game-dir-relative path of the Mono runtime the player loads; the ARM64EC build is placed at exactly this path.";
    };
  };

  config = lib.mkIf active {
    extraLowers = [
      (mkUnityMonoTree {
        inherit (cfg) pname payloads;
        inherit (um)
          stream
          playerPath
          runtimePath
          ;
      })
    ];
  };
}
