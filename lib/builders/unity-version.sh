# lib/builders/unity-version.sh — `unity_player_version <UnityPlayer.dll|UnityPlayer.so>` prints the version
# string a Unity player carries, in the form the pins record: `<major>.<minor>.<patch><type><n>[-suffix]`
# followed by ` (<12-hex changeset>)` where the player has the hash form, the bare version otherwise.
# Sourced by the tree builders that check a payload against its pinned facts; needs binutils' `strings`.
#
# The string is UTF-16 from 2022.3 on and ASCII in older players (whose UTF-16 copy is
# `<version>_<hash>`), so both encodings are scanned; the anchored, hash-suffixed form is tried first
# because players also carry decoy version-like strings (`5.0.0a1`, `2018.3.0a1`) ahead of the real one.
# The same order and decoy rule as `propnix pin`'s scanner (pkgs/propnix-cli/src/pin/unity.rs).
#
# Each dump goes to a file first: `strings | grep -m1` under pipefail reports the SIGPIPE strings dies
# of as a failure.
unity_player_version() {
  local f=$1 ver="" t
  strings -el "$f" > "${TMPDIR:-/tmp}/unity-version-utf16.txt"
  strings "$f" > "${TMPDIR:-/tmp}/unity-version-ascii.txt"
  for t in "${TMPDIR:-/tmp}/unity-version-utf16.txt" "${TMPDIR:-/tmp}/unity-version-ascii.txt"; do
    ver=$(grep -oE -m1 '^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+[^ ]* \([0-9a-f]{12}\)' "$t" || true)
    [ -n "$ver" ] && break
    ver=$(grep -oE -m1 '^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+' "$t" || true)
    [ -n "$ver" ] && break
  done
  printf '%s' "$ver"
}
