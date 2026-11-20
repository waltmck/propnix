# modules/unity.nix — the `unity.*` FACTS of a Unity title, read off its pinned payload: the player's
# version string and changeset and the scripting backend, as `propnix pin` recorded them on the selected
# fetch row (`unityVersion` / `unityChangeset` / `unityScripting`; pkgs/propnix-cli/src/pin/unity.rs).
# Nothing here changes a launch. The consumers are the Mono-runtime swap (modules/unity-mono.nix, which
# derives its stream from `unity.stream`) and the native-player swap (modules/unity-player.nix, which
# selects a player by the exact `unity.version`); each checks the payload's own bytes against these at
# build time, so a row that lies is refused rather than trusted.
#
# Every option is `lastWins`, so a game module or `.apply` may state a fact the pin lacks — a
# title pinned before the facts were recorded (`propnix pin <game> --fingerprint` backfills them).
{
  lib,
  knobTypes,
}:
{ config, ... }:
let
  cfg = config;
  # The selected fetch rows: the pair the two axes resolved to, exactly what `payloads` is built from.
  # A multi-depot pair lists one row per depot; the player ships in exactly one of them.
  rows = cfg.fetchInfo.${cfg.fetcher}.${cfg.emulatedPlatform} or null;
  row = if rows == null then null else lib.findFirst (r: r ? unityVersion) null rows;
  fact = k: if row == null then null else row.${k} or null;
in
{
  options.unity = {
    version = lib.mkOption {
      type = knobTypes.lastWins;
      default = fact "unityVersion";
      defaultText = lib.literalExpression "the selected fetch row's `unityVersion`, else null";
      description = ''
        The Unity player's version string as the player itself reports it (Player.log's
        `Initialize engine version:`), e.g. "6000.0.61f1" — or with an internal-branch suffix
        ("6000.0.50f1-uum-100966-branch1"), for which no public player download exists. null: not a
        Unity title, or a row pinned before the facts were recorded.
      '';
    };
    changeset = lib.mkOption {
      type = knobTypes.lastWins;
      default = fact "unityChangeset";
      defaultText = lib.literalExpression "the selected fetch row's `unityChangeset`, else null";
      description = ''
        The 12-hex changeset beside the version string ("74a0adb02c31"), which keys Unity's own
        download URLs for that version's build-support modules.
      '';
    };
    scripting = lib.mkOption {
      type = knobTypes.lastWins;
      default = fact "unityScripting";
      defaultText = lib.literalExpression "the selected fetch row's `unityScripting`, else null";
      description = ''
        The scripting backend the build was made with: "mono" (the game's C# ships as IL and a Mono
        runtime JIT-compiles it — the one a runtime or player swap can make native) or "il2cpp" (the C#
        was compiled ahead of time into a native `GameAssembly` library, which no swap can replace).
      '';
    };
    stream = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default =
        if cfg.unity.version == null then
          null
        else
          lib.concatStringsSep "." (lib.take 2 (lib.splitString "." cfg.unity.version));
      defaultText = lib.literalExpression "`<major>.<minor>` of unity.version, else null";
      description = ''
        The release line (`<major>.<minor>`, e.g. "2022.3" or "6000.0") of `unity.version` — what the
        Mono runtime is packaged per (emulators/unity-mono). Derived, never set.
      '';
    };
  };
}
