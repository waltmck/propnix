# mkUnityMonoTree — the game-dir tree that puts a stream's ARM64EC Unity runtime (emulators/unity-mono)
# over the payload: `<runtimePath>` (by default MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll) and
# nothing else, for lib/modules/unity-mono.nix to union into the game dir above the payloads.
#
# The tree is built per game, from the payload's own bytes, and checks the declaration it embodies:
#   1. The player's version string must begin with the declared stream. UnityPlayer.dll carries
#      `<major>.<minor>.<patch><type><n> (<hash>)` as UTF-16 from 2022.3 on and as ASCII in older
#      players (whose UTF-16 copy is `<version>_<hash>`); the anchored, hash-suffixed form is tried
#      first because the players also carry decoy version-like strings (`5.0.0a1`, `2018.3.0a1`). A runtime
#      from another stream loads and then faults inside the player — the player binds to runtime
#      internals that move between release lines — so the mismatch is refused here, not at launch.
#   2. Every `mono_*` name the player carries that the SHIPPED runtime exports must be exported by the
#      ARM64EC runtime. The intersection, not the player's list: the player also names entry points it
#      resolves optionally, which the shipped runtime does not have either.
# Both read the payload inside this derivation, never at eval, so an unpinned combo still evaluates.
{
  lib,
  runCommand,
  binutils, # `strings`, for the player's version string and the names it binds
  wine, # `winedump -j export`: the PE export reader for the shipped x64 runtime (no other tool needed)
  unityMono, # emulators/unity-mono (null on x86_64 hosts, where no game instantiates this)
}:
{
  pname,
  stream,
  payloads, # the game's payload store trees; the player and the shipped runtime are looked up in each
  playerPath, # game-dir-relative path of UnityPlayer.dll
  runtimePath, # game-dir-relative path of the runtime the player loads
}:
let
  known = lib.attrNames unityMono.streams;
  runtime =
    unityMono.streams.${stream}
      or (throw "propnix (${pname}): unity.mono.stream = \"${stream}\" names no packaged stream — emulators/unity-mono has ${lib.concatStringsSep ", " known}");
in
runCommand "${pname}-unity-mono-${stream}-arm64ec"
  {
    nativeBuildInputs = [
      binutils
      wine
    ];
    playerCandidates = map (p: "${p}/${playerPath}") payloads;
    runtimeCandidates = map (p: "${p}/${runtimePath}") payloads;
    inherit stream runtime runtimePath;
  }
  ''
    player=""; shipped=""
    for c in $playerCandidates; do [ -f "$c" ] && player=$c && break; done
    for c in $runtimeCandidates; do [ -f "$c" ] && shipped=$c && break; done
    [ -n "$player" ] || { echo "propnix (${pname}): no payload has ${playerPath} — not a Unity player tree? (unity.mono.playerPath)"; exit 1; }
    [ -n "$shipped" ] || { echo "propnix (${pname}): no payload has ${runtimePath} — an IL2CPP build, or the Mono runtime lives elsewhere (unity.mono.runtimePath)"; exit 1; }

    # Each strings dump to a file, then grep on the file: `strings | grep -m1` under pipefail reports the
    # SIGPIPE strings dies of as a failure.
    strings -el "$player" > utf16.txt
    strings "$player" > ascii.txt
    ver=""
    for f in utf16.txt ascii.txt; do
      ver=$(grep -oE -m1 '^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+[^ ]* \([0-9a-f]{12}\)' "$f" || true)
      [ -n "$ver" ] && break
      ver=$(grep -oE -m1 '^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+' "$f" || true)
      [ -n "$ver" ] && break
    done
    [ -n "$ver" ] || { echo "propnix (${pname}): no Unity version string in $player"; exit 1; }
    playerStream=$(printf '%s' "$ver" | cut -d. -f1-2)
    [ "$playerStream" = "$stream" ] || {
      echo "propnix (${pname}): the player is Unity $ver (stream $playerStream), but unity.mono.stream declares $stream."
      echo "         A runtime from another stream does not fit this player; declare \"$playerStream\" (packaged: ${lib.concatStringsSep ", " known})."
      exit 1
    }

    winedump -j export "$shipped" | awk '/^ *[0-9A-Fa-f]{8} +[0-9]+ +[A-Za-z_]/ { print $3 }' | sort -u > shipped.txt
    [ "$(wc -l < shipped.txt)" -ge 100 ] || { echo "propnix (${pname}): $shipped exports $(wc -l < shipped.txt) names — not a Mono runtime?"; exit 1; }
    grep -oE '^mono_[A-Za-z0-9_]+$' ascii.txt | sort -u > player.txt
    comm -12 player.txt shipped.txt > required.txt
    [ "$(wc -l < required.txt)" -ge 100 ] || { echo "propnix (${pname}): the player names only $(wc -l < required.txt) of the shipped runtime's exports — unexpected for a Mono player"; exit 1; }
    comm -23 required.txt "$runtime/exports" > missing.txt
    if [ -s missing.txt ]; then
      echo "propnix (${pname}): the ARM64EC $stream runtime lacks $(wc -l < missing.txt) entry point(s) this player ($ver) binds:"
      sed 's/^/           /' missing.txt
      exit 1
    fi
    echo "propnix (${pname}): Unity $ver, $(wc -l < required.txt) runtime entry points, all exported by the ARM64EC $stream runtime"

    mkdir -p "$out/$(dirname "$runtimePath")"
    install -m444 "$runtime/mono-2.0-bdwgc.dll" "$out/$runtimePath"
  ''
