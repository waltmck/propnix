#!/usr/bin/env bash
# ci/unity-player-check.sh — verify every row of emulators/unity-player against what Unity actually
# serves, instead of assuming it. A pure gate (no credentials, one API call and one HEAD per row), wired
# into eval.yml next to the cache audit; the scheduled unity-player-verify.yml does the full download.
#
# For each `versions` row the package declares, three things must hold:
#   1. Unity's release API knows the version, its `shortRevision` is the row's changeset, and the
#      `windows-mono` module it lists is the URL the package fetches (the API is the authority on where a
#      release's module lives; the package reconstructs the URL from the changeset).
#   2. The CDN serves that URL (HTTP 200) with a Content-Length equal to the row's `downloadSize`, which
#      is also what the API reports — a silently re-published module (same URL, new bytes) shows up here
#      as a size change before a user's build fails its hash.
#   3. The row is well-formed: a 12-hex changeset, an SRI sha256 hash, an integer size.
# Any failure names the version and what to do. Exit 1 on the first failing row.
set -euo pipefail

api=https://services.api.unity.com/unity/editor/release/v1/releases
work=$(mktemp -d)
trap 'rm -rf "$work"' INT TERM EXIT

die() { echo "unity-player-check: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."
rows=$(nix eval --json '.#unityPlayer.versions') || die "could not evaluate emulators/unity-player's versions table"
n=$(jq 'length' <<<"$rows")
[ "$n" -gt 0 ] || die "the versions table is empty"

jq -r 'to_entries[] | "\(.key)\t\(.value.changeset)\t\(.value.windowsMono)\t\(.value.downloadSize)"' <<<"$rows" |
while IFS=$'\t' read -r version changeset hash size; do
  # 3. well-formed
  [[ "$changeset" =~ ^[0-9a-f]{12}$ ]] || die "$version: changeset '$changeset' is not 12 hex digits"
  [[ "$hash" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || die "$version: windowsMono '$hash' is not an SRI sha256 hash"
  [[ "$size" =~ ^[0-9]+$ ]] || die "$version: downloadSize '$size' is not an integer"
  expected_url="https://download.unity3d.com/download_unity/$changeset/MacEditorTargetInstaller/UnitySetup-Windows-Mono-Support-for-Editor-$version.pkg"

  # 1. the release API
  curl -sSf --max-time 60 "$api?version=$version" -o "$work/release.json" \
    || die "$version: the Unity release API did not answer for this version — Unity no longer lists it; pin the module to a mirror or drop the player for that version"
  release=$(jq -c --arg v "$version" '[.results[] | select(.version == $v)] | first // empty' "$work/release.json")
  [ -n "$release" ] || die "$version: the release API has no release of exactly this version (results: $(jq -r '[.results[].version] | join(", ")' "$work/release.json"))"
  got_rev=$(jq -r '.shortRevision' <<<"$release")
  [ "$got_rev" = "$changeset" ] || die "$version: the release API says changeset $got_rev, the row says $changeset — fix the row"
  module=$(jq -c '[.. | objects | select(.id? == "windows-mono")] | first // empty' <<<"$release")
  [ -n "$module" ] || die "$version: the release API lists no windows-mono module for this version — the player cannot be fetched; drop the row"
  got_url=$(jq -r '.url' <<<"$module")
  [ "$got_url" = "$expected_url" ] || die "$version: the API's module URL is $got_url, the package would fetch $expected_url — the URL formula no longer holds for this release"
  api_size=$(jq -r '.downloadSize.value // .downloadSize' <<<"$module")
  [ "$api_size" = "$size" ] || die "$version: the release API reports a $api_size-byte module, the row says $size — Unity re-published it; re-prefetch the hash and update the row"

  # 2. the CDN
  curl -sSI --max-time 60 "$expected_url" -o "$work/head.txt" || die "$version: the CDN did not answer a HEAD for $expected_url"
  status=$(awk 'toupper($1) ~ /^HTTP\// { s=$2 } END { print s }' "$work/head.txt")
  [ "$status" = "200" ] || die "$version: the CDN answers HTTP $status for $expected_url — Unity no longer serves this module; pin it to a mirror or drop the player for that version"
  length=$(awk 'tolower($1) == "content-length:" { gsub("\r", "", $2); l=$2 } END { print l }' "$work/head.txt")
  [ "$length" = "$size" ] || die "$version: the CDN serves $length bytes, the row says $size — the module changed under its URL; re-prefetch the hash and update the row"

  echo "unity-player-check: $version ($changeset): API and CDN agree ($size bytes)"
done
echo "unity-player-check: OK — $n row(s) verified"
