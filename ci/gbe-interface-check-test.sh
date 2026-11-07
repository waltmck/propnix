#!/usr/bin/env bash
# ci/gbe-interface-check-test.sh — exercise every verdict of ci/gbe-interface-check.sh against stubs: an
# oracle that answers from a fixture, a shim map handed in as JSON, and fixture versions.json trees. No
# nix, no network, no credentials: bash + jq. It guards the GATE itself — a check that cannot fail, or
# that fails for the wrong reason, is the silent-success failure mode this repo has already met once
# (ci/cache-audit.sh's history) — and it is the only place the failure paths are ever run on purpose.
#
# Usage: ci/gbe-interface-check-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' INT TERM EXIT

# ── the stub oracle package ─────────────────────────────────────────────────────────────────────────
mkdir -p "$work/oracle/bin" "$work/oracle/share/gbe-interface-oracle"
grep -v '^[[:space:]]*#' "$here/../pkgs/propnix-cli/steam-api-interface-patterns.txt" | grep . \
  >"$work/oracle/share/gbe-interface-oracle/patterns.txt"
cat >"$work/oracle/bin/gbe-interface-oracle" <<'STUB'
#!/usr/bin/env bash
# Verdicts from $STUB_VERDICTS ("<rev><TAB><verdict>" lines); anything else is exit73, like an unknown
# family. Exit 1 unless every revision is served — the real oracle's contract.
rc=0
for r in "$@"; do
  v=$(awk -F'\t' -v r="$r" '$1 == r { print $2; exit }' "$STUB_VERDICTS")
  [ -n "$v" ] || v=exit73
  [ "$v" = served ] || rc=1
  printf '%s\t%s\n' "$r" "$v"
done
exit $rc
STUB
chmod +x "$work/oracle/bin/gbe-interface-oracle"
printf 'SteamFoo003\tserved\nSteamFoo005\tserved\nSteamBar002\tnull\n' >"$work/verdicts"
echo '{"good":{"x86_64-linux":{"enable":true,"neverRequested":[]}}}' >"$work/map-default.json"

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────────
row() { # <id> <fingerprint-json> → one Steam row
  printf '{"appId":%s,"depotId":%s1,"manifestId":"42","outputHash":"x","pname":"p","steamApiInterfaces":%s}' "$1" "$1" "$2"
}
game() { # <games-dir> <name> <rows-json (x86_64-linux)> [dlc-json]
  mkdir -p "$1/$2"
  printf '{"fetchInfo":{"steam":{"x86_64-linux":[%s]}}%s}' "$3" "${4:+,\"dlc\":$4}" >"$1/$2/versions.json"
}
run() { # <name> <expected exit> <games-dir> [map.json]
  local name=$1 want=$2 games=$3 map=${4:-$work/map-default.json} rc=0
  rm -rf "$work/repo"
  mkdir -p "$work/repo/ci" "$work/repo/pkgs/propnix-cli"
  cp "$here/gbe-interface-check.sh" "$work/repo/ci/"
  cp -r "$games" "$work/repo/pkgs/games"
  cp "$here/../pkgs/propnix-cli/steam-api-interface-patterns.txt" "$work/repo/pkgs/propnix-cli/"
  : >"$work/summary"
  STUB_VERDICTS=$work/verdicts PROPNIX_GBE_ORACLE=$work/oracle PROPNIX_SHIM_MAP=$map \
    GITHUB_ACTIONS=1 GITHUB_STEP_SUMMARY=$work/summary \
    "$work/repo/ci/gbe-interface-check.sh" x86_64-linux >"$work/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL [$name]: exit $rc, wanted $want" >&2
    cat "$work/out" >&2
    exit 1
  fi
}
expect() { # <name> <ERE> — the output must contain it
  grep -qE -- "$2" "$work/out" || {
    echo "FAIL [$1]: output lacks /$2/" >&2
    cat "$work/out" >&2
    exit 1
  }
}
refute() { # <name> <ERE> — the output must not contain it
  if grep -qE -- "$2" "$work/out"; then
    echo "FAIL [$1]: output has /$2/" >&2
    cat "$work/out" >&2
    exit 1
  fi
}

# 1. every revision served → verified (a DLC row naming nothing is verified too)
d=$work/g1 && game "$d" good "$(row 1 '["SteamFoo003","SteamFoo005"]')" "{\"pack\":$(row 2 '[]')}"
run served 0 "$d"
expect served 'good \(steam/x86_64-linux\[0\]\): 2 revision\(s\), all served'
expect served-dlc 'good \(dlc\.pack\): 0 revision\(s\), all served'
expect served-count '\(2 verified, 0 tolerated, 0 exempt, 0 unverified\)'
refute served-clean '::error|::notice'

# 2. an unserved revision → failure: ::error names game, row, revision and the shim's verdict; in the summary
d=$work/g2 && game "$d" bad "$(row 1 '["SteamFoo003","SteamFoo009"]')"
run unserved 1 "$d"
expect unserved '::error title=gbe_fork interface check — bad::steam/x86_64-linux\[0\] — .*SteamFoo009\(exit73\)'
grep -q 'SteamFoo009' "$work/summary" || { echo "FAIL [unserved]: the step summary lacks the failure" >&2; exit 1; }

# 3. a NULL vtable is a failure too, not just exit 73
d=$work/g3 && game "$d" bad "$(row 1 '["SteamBar002"]')"
run null 1 "$d"
expect null 'SteamBar002\(null\)'

# 4. declared never-requested → tolerated, exit 0, said out loud
d=$work/g4 && game "$d" tol "$(row 1 '["SteamFoo003","SteamFoo009"]')"
echo '{"tol":{"x86_64-linux":{"enable":true,"neverRequested":["SteamFoo009"]}}}' >"$work/map4.json"
run tolerated 0 "$d" "$work/map4.json"
expect tolerated 'tol \(steam/x86_64-linux\[0\]\): 2 revision\(s\); served except SteamFoo009\(exit73\), tolerated by steam\.emu\.neverRequested'
expect tolerated-count '\(0 verified, 1 tolerated, 0 exempt, 0 unverified\)'
grep -q 'SteamFoo009' "$work/summary" || { echo "FAIL [tolerated]: the step summary lacks the tolerance" >&2; exit 1; }

# 5. a tolerance the shim no longer needs → a notice to drop it, not a failure
d=$work/g5 && game "$d" tol "$(row 1 '["SteamFoo003"]')"
echo '{"tol":{"x86_64-linux":{"enable":true,"neverRequested":["SteamFoo003"]}}}' >"$work/map5.json"
run stale 0 "$d" "$work/map5.json"
expect stale '::notice .*neverRequested lists SteamFoo003, which the pinned gbe_fork now serves'

# 6. the shim disabled → exempt even with an unserved revision; the DLC row of a game disabled on every
#    platform is exempt too
d=$work/g6 && game "$d" off "$(row 1 '["SteamFoo009"]')" "{\"pack\":$(row 2 '["SteamFoo009"]')}"
echo '{"off":{"x86_64-linux":{"enable":false,"neverRequested":[]}}}' >"$work/map6.json"
run exempt 0 "$d" "$work/map6.json"
expect exempt 'off \(steam/x86_64-linux\[0\]\): exempt'
expect exempt-dlc 'off \(dlc\.pack\): exempt'
refute exempt-clean '::error'

# 6b. the shim disabled AND no fingerprint → exempt, not unverified: nothing to fingerprint either
d=$work/g6b && game "$d" off "$(row 1 null)"
run exempt-null 0 "$d" "$work/map6.json"
expect exempt-null 'off \(steam/x86_64-linux\[0\]\): exempt'
expect exempt-null-count '\(0 verified, 0 tolerated, 1 exempt, 0 unverified\)'
refute exempt-null-clean '::notice'

# 7. a game the map cannot answer for is HELD to the gate (the conservative direction)
d=$work/g7 && game "$d" unknown "$(row 1 '["SteamFoo009"]')"
run held 1 "$d"
expect held '::error .*unknown::steam/x86_64-linux\[0\]'

# 8. no fingerprint → unverified notice, exit 0
d=$work/g8 && game "$d" old "$(row 1 null)"
run unverified 0 "$d"
expect unverified '::notice .*old::steam/x86_64-linux\[0\] — no steamApiInterfaces recorded'
expect unverified-count '\(0 verified, 0 tolerated, 0 exempt, 1 unverified\)'

# 9. a malformed field → exit 1 naming the file
d=$work/g9 && game "$d" broken "$(row 1 '"oops"')"
run malformed 1 "$d"
expect malformed 'enumerating the Steam rows of pkgs/games/broken/versions\.json failed'

# 10. no versions.json at all → exit 1 (never a vacuous pass)
d=$work/g10 && mkdir -p "$d"
run empty 1 "$d"
expect empty 'no Steam rows found'

# 11. the scanner's pattern list drifted from the pinned generator's → failure, though every row is served
d=$work/g11 && game "$d" good "$(row 1 '["SteamFoo003"]')"
sed -i '$d' "$work/oracle/share/gbe-interface-oracle/patterns.txt" # upstream "lost" a family our copy has
run drift 1 "$d"
expect drift '::error title=gbe_fork interface check — propnix-cli::steam-api-interface-patterns\.txt — the scanner.s pattern list has drifted'

echo "gbe-interface-check-test: all 12 scenarios behave"
