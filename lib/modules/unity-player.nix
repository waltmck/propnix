# The `unity.player.*` namespace: a Windows Unity title's NATIVE ARM64 platform. On an aarch64 host the
# `aarch64-windows` platform runs the title on Unity's own ARM64 player of the pinned release
# (emulators/unity-player) with emulators/unity-mono's plain-ARM64 Mono runtime, over the same store
# build as `x86_64-windows`: the whole process — engine, runtime, the game's IL — is native ARM64 under
# wine, with no x86 code to emulate. The shape mirrors `steam.emu.*`: an enable, the package, the paths,
# and an `active` readout.
#
# THE PLATFORM IS THE SWITCH. This module PINS the pair: for every fetcher whose `x86_64-windows` rows
# record a Mono player version emulators/unity-player packages (`unityVersion`/`unityScripting`, as
# `propnix pin` writes them), the same rows are pinned under `aarch64-windows` — the payload is the x64
# build, which is what the ARM64 player reads. The game then ranks that platform in `platformPreference`
# like any other (the ratchet asks for a ranking the moment a second platform is pinned), the resolver
# selects it where the host can run it (`runnable`, lib/strategy.nix: an aarch64 host), and everything
# platform-keyed follows from `emulatedPlatform` alone: the wine defaults bind the ARM64 Galaxy stub, the
# backend hands wine the ARM64 DXVK/vkd3d, and modules/steam-emu.nix places the ARM64 gbe_fork where the
# player resolves plugins (`winPkgs.<platform>`, lib/win-toolchain.nix). The A/B is
# `.apply { emulatedPlatform = "x86_64-windows"; }`: the x64 player under FEX with the ARM64EC runtime.
#
# WHAT MAKES IT POSSIBLE. A Unity game's own code is IL. The native code in a Mono-backend Windows build
# is the player (UnityPlayer.dll + the WindowsPlayer.exe stub), the runtime, and whatever native plugins
# the title vendors. Unity publishes the ARM64 player for every release that has one, and it reads the
# same `<name>_Data` (assets, Managed/ IL) an x64 build was made from — the stub derives the data
# directory from its own filename. The ARM64 player resolves native plugins from `<Data>/Plugins/ARM64/`,
# never from the x64 directory the title ships, so the title's x64 plugins are simply absent; what a
# title needs there is declared per title (`plugins`).
#
# The player goes in as an `extraLowers` tree (lib/builders/unity-player-tree.nix), which checks the
# pinned facts against the payload's player and the packaged player at build time and places the files
# above the payload in the game dir. A desktop-Linux ARM64 player, should Unity ship one, is a second
# entry in `nativeOf` and a second emulators/unity-player target, with no change elsewhere.
{
  lib,
  knobTypes, # lastWins leaves, as `steam.emu.*`: a game's definition and an `.apply` override merge last-wins
  fetchers, # the fetcher registry: which fetchers the pair is pinned for
  winPkgs, # the per-target Windows package set (lib/default.nix): the native platform's unityMono
  unityPlayer, # emulators/unity-player
  mkUnityPlayerTree,
}:
{ config, ... }:
let
  cfg = config;
  up = cfg.unity.player;
  # The native platform a content platform's rows serve, where a player exists for it.
  nativeOf = {
    "x86_64-windows" = "aarch64-windows";
  };
  platform = cfg.emulatedPlatform;
  isNative = lib.elem platform (lib.attrValues nativeOf);
  # The pair pins: for each fetcher, the rows of a content platform whose recorded player version is
  # packaged, under its native platform. Reads only other fetch rows and the package set — never the axes,
  # which resolve FROM the matrix (modules/app-options.nix) — and `enable`, which a game must therefore
  # state unconditionally.
  packagedRow =
    r: (r.unityScripting or null) == "mono" && unityPlayer.versions ? ${r.unityVersion or ""};
  pairPins = lib.genAttrs (lib.attrNames fetchers) (
    f:
    lib.mapAttrs' (
      content: native:
      let
        rows = cfg.fetchInfo.${f}.${content};
      in
      lib.nameValuePair native (
        lib.mkIf (
          up.enable && rows != null && lib.any packagedRow rows && unityPlayer.targets ? ${native}
        ) (lib.mkDefault rows)
      )
    ) nativeOf
  );
  active =
    up.enable
    && isNative
    && cfg.backend == "wine"
    && cfg.unity.scripting == "mono"
    && up.version != null;
  stream = cfg.unity.stream;
  # Our runtime for the title's stream, built for the native platform — null where the stream is not
  # packaged for it, in which case the module's own ARM64 runtime serves (the tree says which).
  ourRuntime =
    let
      um = (winPkgs.${platform} or { }).unityMono or null;
    in
    if um != null && stream != null && um.streams ? ${stream} then um.streams.${stream} else null;
in
{
  options.unity.player = {
    enable = lib.mkOption {
      type = knobTypes.lastWins;
      default = true;
      description = ''
        Whether the title's native ARM64 platform is offered: pins `aarch64-windows` from the
        `x86_64-windows` rows whose player version emulators/unity-player packages, and serves it with the
        native player. `false` removes the pair (a title that must not run native). Must not depend on
        the axes — it decides what the fetch matrix contains.
      '';
    };
    variant = lib.mkOption {
      type = knobTypes.lastWins;
      default = "nondevelopment";
      description = "Which player build: `nondevelopment` (the release player) or `development` (the debugging-enabled one); `unityPlayer.for` refuses any other.";
    };
    version = lib.mkOption {
      type = knobTypes.lastWins;
      default = cfg.unity.version;
      defaultText = lib.literalExpression "config.unity.version";
      description = ''
        The Unity release whose player is used: the pin's `unityVersion`. Not a knob: a player loads only
        data whose per-type layout hashes match its own classes, and those drift between releases
        (docs/research/unity-arm64-player.md), so another release's player cannot serve a payload.
      '';
    };
    package = lib.mkOption {
      type = knobTypes.lastWins;
      default =
        if active then
          unityPlayer.for {
            inherit (up) version variant;
            target = platform;
          }
        else
          null;
      defaultText = lib.literalExpression "unityPlayer.for { version; target = emulatedPlatform; variant; }";
      description = "The emulators/unity-player package to use (a legible error names the row to add when the version has none).";
    };
    playerPath = lib.mkOption {
      type = knobTypes.lastWins;
      default = "UnityPlayer.dll";
      description = "Game-dir-relative path of the player library.";
    };
    crashHandlerPath = lib.mkOption {
      type = knobTypes.lastWins;
      default = "UnityCrashHandler64.exe";
      description = "Game-dir-relative path of the crash handler the player spawns.";
    };
    runtimePath = lib.mkOption {
      type = knobTypes.lastWins;
      default = cfg.unity.mono.runtimePath;
      defaultText = lib.literalExpression "config.unity.mono.runtimePath";
      description = "Game-dir-relative path of the Mono runtime the player loads; the native runtime is placed exactly there.";
    };
    dataDir = lib.mkOption {
      type = knobTypes.lastWins;
      default = "${lib.removeSuffix ".exe" (baseNameOf cfg.exe)}_Data";
      defaultText = lib.literalExpression ''"''${removeSuffix ".exe" (baseNameOf config.exe)}_Data"'';
      description = "The title's `<name>_Data` directory (game-dir-relative); native plugins go under its `Plugins/ARM64/`.";
    };
    runtime = lib.mkOption {
      type = knobTypes.lastWins;
      default = ourRuntime;
      defaultText = lib.literalExpression "winPkgs.\${emulatedPlatform}.unityMono.streams.\${config.unity.stream}";
      description = ''
        The Mono runtime the native player loads: emulators/unity-mono's plain-ARM64 build of the title's
        stream (the default where packaged). `null` uses the runtime Unity's module ships beside the
        player — an A/B reference, not a configuration to ship.
      '';
    };
    plugins = lib.mkOption {
      type = lib.types.attrsOf knobTypes.lastWins;
      default = { };
      example = lib.literalExpression ''{ "XInputInterface64.dll" = "''${xinputInterfaceArm64}/XInputInterface64.dll"; }'';
      description = "Native ARM64 plugins placed at `<dataDir>/Plugins/ARM64/<name>` — a title's vendored x64 plugins are absent to the native player.";
    };
    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = active;
      description = "Whether the native player serves this build (the native platform is selected; derived, informational).";
    };
  };

  config = lib.mkMerge [
    { fetchInfo = pairPins; }
    (lib.mkIf active {
      extraLowers = [
        (lib.throwIf (cfg.wine.extraSystem32 != { })
          "propnix (${cfg.pname}): the native ARM64 platform is selected, but `wine.extraSystem32` stages x64 DLLs — a native ARM64 process cannot load them. Drop the staging or select the x86_64-windows platform."
          (mkUnityPlayerTree {
            inherit (cfg) pname payloads exe;
            inherit (up)
              playerPath
              crashHandlerPath
              runtimePath
              dataDir
              runtime
              plugins
              version
              ;
            player = up.package;
            changeset = cfg.unity.changeset;
          })
        )
      ];
    })
  ];
}
