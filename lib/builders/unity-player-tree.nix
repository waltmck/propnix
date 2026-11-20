# mkUnityPlayerTree — the game-dir tree that puts Unity's native ARM64 player (emulators/unity-player)
# over a title's x64 one: the `WindowsPlayer.exe` stub under the title's exe name, `UnityPlayer.dll`, the
# crash handler, the stream's native Mono runtime (emulators/unity-mono's plain-ARM64 build, with its
# MonoPosixHelper) at the runtime's path, and the declared native plugins under `<Data>/Plugins/ARM64/`,
# for lib/modules/unity-player.nix to union into the game dir above the payloads (first wins, so each of
# these replaces the payload's file at the same path).
#
# Built per game from the payload's own bytes, and the pinned facts are checked here, not at launch:
#   1. The payload's player must report the pinned `unity.version` (and changeset, when pinned) — the
#      same check lib/builders/unity-mono-tree.nix makes, through lib/builders/unity-version.sh.
#   2. The packaged native player must report the SAME string: a module row whose hash was taken from
#      another release would pair the game with a player its assets were not built for — and the player
#      itself loads only data whose per-type layout hashes match its classes
#      (docs/research/unity-arm64-player.md), so a row is the title's exact release or nothing.
#   3. Every `mono_*` entry point the native player binds that the module's own ARM64 runtime exports
#      must be exported by the runtime that goes in — the intersection, since the player also names
#      entry points it resolves optionally. With `runtime = null` the module's own runtime goes in and
#      the check is moot.
# All three read the payload inside this derivation, never at eval, so an unpinned combo still evaluates.
{
  lib,
  runCommand,
  binutils, # `strings`
  wine, # `winedump -j export`: the PE export reader for the module's ARM64 runtime
}:
{
  pname,
  payloads, # the game's payload store trees; the shipped player is looked up in each
  exe, # the title's exe name — what the native stub is installed as
  player, # the emulators/unity-player package for the pinned version and the native target
  version, # the pinned `unity.version`, verbatim — what the payload's player must report
  changeset, # the pinned `unity.changeset`, or null
  runtime, # emulators/unity-mono's runtime for the stream and target, or null (the module's own)
  playerPath, # game-dir-relative path of UnityPlayer.dll
  crashHandlerPath, # game-dir-relative path of UnityCrashHandler64.exe
  runtimePath, # game-dir-relative path of the Mono runtime the player loads
  dataDir, # the title's `<name>_Data` directory (game-dir-relative)
  plugins, # { "<name>.dll" = <store path>; } → `<dataDir>/Plugins/ARM64/<name>.dll`
}:
runCommand "${pname}-unity-player-${player.target}"
  {
    nativeBuildInputs = [
      binutils
      wine
    ];
    playerCandidates = map (p: "${p}/${playerPath}") payloads;
    inherit
      version
      runtimePath
      player
      ;
    expected = if changeset != null then "${version} (${changeset})" else version;
    runtime = if runtime != null then "${runtime}" else "";
    pluginRows = lib.concatStringsSep "\n" (lib.mapAttrsToList (n: p: "${n}\t${p}") plugins);
  }
  ''
    source ${./unity-version.sh}
    shipped=""
    for c in $playerCandidates; do [ -f "$c" ] && shipped=$c && break; done
    [ -n "$shipped" ] || { echo "propnix (${pname}): no payload has ${playerPath} — not a Unity player tree? (unity.player.playerPath)"; exit 1; }

    ver=$(unity_player_version "$shipped")
    [ -n "$ver" ] || { echo "propnix (${pname}): no Unity version string in $shipped"; exit 1; }
    # The pin must be what the payload says — a row recording another version would select a player for
    # the wrong release.
    if [ -n "${lib.optionalString (changeset != null) "1"}" ]; then
      [ "$ver" = "$expected" ] || {
        echo "propnix (${pname}): the payload's player is Unity $ver, but the pin records $expected."
        echo "         Re-run \`propnix pin ${pname} --fingerprint\` to record what the payload actually ships."
        exit 1
      }
    else
      [ "''${ver% (*}" = "$expected" ] || {
        echo "propnix (${pname}): the payload's player is Unity $ver, but the pin records unityVersion = $expected."
        exit 1
      }
    fi
    native=$(unity_player_version "$player/UnityPlayer.dll")
    [ "$native" = "$ver" ] || { echo "propnix (${pname}): the packaged native player is Unity $native, the payload's is $ver — emulators/unity-player's row is not this release"; exit 1; }

    if [ -n "$runtime" ]; then
      winedump -j export "$player/shipped-mono/mono-2.0-bdwgc.dll" | awk '/^ *[0-9A-Fa-f]{8} +[0-9]+ +[A-Za-z_]/ { print $3 }' | sort -u > shipped.txt
      [ "$(wc -l < shipped.txt)" -ge 100 ] || { echo "propnix (${pname}): the module's runtime exports $(wc -l < shipped.txt) names — not a Mono runtime?"; exit 1; }
      strings "$player/UnityPlayer.dll" | grep -oE '^mono_[A-Za-z0-9_]+$' | sort -u > player.txt
      comm -12 player.txt shipped.txt > required.txt
      [ "$(wc -l < required.txt)" -ge 100 ] || { echo "propnix (${pname}): the native player names only $(wc -l < required.txt) of the module runtime's exports — unexpected for a Mono player"; exit 1; }
      comm -23 required.txt "$runtime/exports" > missing.txt
      if [ -s missing.txt ]; then
        echo "propnix (${pname}): our ARM64 runtime lacks $(wc -l < missing.txt) entry point(s) the native player ($ver) binds:"
        sed 's/^/           /' missing.txt
        exit 1
      fi
      runtimeDll="$runtime/mono-2.0-bdwgc.dll"
      helper="$runtime/MonoPosixHelper.dll"
      echo "propnix (${pname}): Unity $ver native player; $(wc -l < required.txt) runtime entry points, all exported by our ARM64 runtime"
    else
      runtimeDll="$player/shipped-mono/mono-2.0-bdwgc.dll"
      helper=""
      echo "propnix (${pname}): Unity $ver native player with the module's own ARM64 runtime (unity.player.runtime = null)"
    fi

    install -Dm444 "$player/WindowsPlayer.exe" "$out/"${lib.escapeShellArg exe}
    install -Dm444 "$player/UnityPlayer.dll" "$out/"${lib.escapeShellArg playerPath}
    install -Dm444 "$player/UnityCrashHandler64.exe" "$out/"${lib.escapeShellArg crashHandlerPath}
    install -Dm444 "$runtimeDll" "$out/$runtimePath"
    [ -z "$helper" ] || [ ! -f "$helper" ] || install -Dm444 "$helper" "$out/$(dirname "$runtimePath")/MonoPosixHelper.dll"
    while IFS=$'\t' read -r name src; do
      [ -n "$name" ] || continue
      install -Dm444 "$src" "$out/"${lib.escapeShellArg dataDir}"/Plugins/ARM64/$name"
    done <<< "$pluginRows"
  ''
