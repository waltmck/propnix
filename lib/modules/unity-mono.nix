# The `unity.mono.*` namespace: for a Windows Unity title whose scripting backend is Mono, an aarch64
# host under wine unions the title's Unity stream's ARM64EC Mono runtime (emulators/unity-mono) over the
# payload at the runtime's path, replacing the shipped x64 `mono-2.0-bdwgc.dll` the player loads by name.
# Everything else in the payload stays as shipped. The stream comes from the pinned facts
# (`unity.stream`, modules/unity.nix — recorded by `propnix pin`), so a game declares nothing: a title
# whose rows carry no `unityVersion`, or an IL2CPP build, or a stream emulators/unity-mono does not
# package, keeps the shipped runtime under the emulator.
#
# The runtime goes in as an `extraLowers` tree (lib/builders/unity-mono-tree.nix, which also checks the
# pinned version against the payload's actual player at build time) — the mechanism steam-emu's settings
# tree uses, so no copy of the game is made and the replacement composes with DLC and the other extra
# lowers. It does NOT compose with `maskFiles`: a whiteout cannot sit in a multi-lower game dir (the
# maskFiles option docs); a title that masks a file keeps the shipped runtime until its mask is expressed
# otherwise.
#
# Active only where the runtime applies: the x86_64-windows platform under wine on an aarch64 host. Thin
# backends run the Linux build's own runtime, x86_64 hosts run the shipped x64 runtime natively, and the
# aarch64-windows platform (the native ARM64 player, modules/unity-player.nix) gets its ARM64 runtime
# from that module's tree.
{
  lib,
  stdenv,
  mkUnityMonoTree,
  unityMono, # emulators/unity-mono (null on x86_64 hosts)
}:
{ config, ... }:
let
  cfg = config;
  um = cfg.unity.mono;
  stream = cfg.unity.stream;
  active =
    um.enable
    && stream != null
    && cfg.unity.scripting != "il2cpp"
    && cfg.backend == "wine"
    && cfg.emulatedPlatform == "x86_64-windows"
    && stdenv.hostPlatform.isAarch64
    && unityMono != null
    && unityMono.streams ? ${stream};
in
{
  options.unity.mono = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the stream's ARM64EC runtime is used. `false` keeps the shipped x64 runtime under the
        emulator with the facts in place — the A/B switch (`.apply { unity.mono.enable = false; }`).
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
        inherit stream;
        version = cfg.unity.version;
        inherit (um) playerPath runtimePath;
      })
    ];
  };
}
