#!/usr/bin/env bash
# ci/gbe-interface-check.sh <system> — hold every Steam pin's recorded Steamworks-SDK fingerprint to the
# pinned gbe_fork, by ASKING THE SHIM. No credential, no payload, no network beyond substituting the
# shim's oracle (on cachix; built from source otherwise) — so it runs on every push and every pull
# request, fork PRs included (a job of .github/workflows/eval.yml), and the commit that moves a pin past
# the shim is the one that goes red, naming the game, the row and the revisions.
#
# THE QUESTION. `steamApiInterfaces` on each Steam row of versions.json is every interface-revision
# string the depot's shipped steam_api libraries name, captured by `propnix pin` at pin time (when the
# bytes are being fetched anyway, with the pinner's credential — the same trust model as the hash beside
# it). For each revision: does the pinned shim SERVE it? Asked of the shim itself — gbeFork.interfaceOracle
# dlopens the host's build of it and requests the revision the way a game would (emulators/gbe-fork/
# interface-oracle.c has why no grep over the source can stand in). "exit73" is
# report_missing_impl_and_exit (0x4155149 & 0xFF), "null" a NULL vtable: either kills the game the moment
# it asks, which is how factorio 2.1.2x presented before any of this existed.
#
# WHAT THE ANSWER MEANS. The library is a SUPERSET of the game's requests: it carries an accessor for
# every family of its SDK, and the shim skips revisions no game needed. So an unserved revision is a
# failure UNLESS the game declares in `steam.emu.neverRequested` that it never asks (its evidence lives in
# the module) — then it is reported as tolerated. A game with `steam.emu.enable = false` never loads the
# shim at all; its rows are reported exempt. Both come from one `nix eval` of the resolved configs
# (PROPNIX_SHIM_MAP=<json> overrides it); if that eval fails, every row is held to the gate, which can
# only ADD failures, never hide one.
#
# THE SCANNER IS CHECKED TOO. `propnix pin` records the fingerprint with its own copy of the generator's
# pattern list (pkgs/propnix-cli/steam-api-interface-patterns.txt). If the pinned gbe_fork's
# tools/generate_interfaces names a family that copy lacks, every fingerprint is silently incomplete — so
# that drift is a failure here, remedied by updating the file and re-running `propnix pin <game>
# --fingerprint` for every game.
#
# A row WITHOUT the field was pinned by an older propnix: reported as unverified (a notice, not a failure,
# so a backfill is not a flag day), with the one command that fixes it. Every failure is reported, none
# aborts the run; under GitHub Actions each is also an `::error` annotation and a row of the step summary.
#
# WHAT IT COVERS: interface revisions only — the thing the shim exits 73 over. The flat `SteamAPI_*` export
# surface is not fingerprinted: a game binary that imports an export the shim lacks fails at LOAD (a missing
# entry point under wine, a symbol lookup error under a Linux loader) rather than at init, and that failure
# mode is caught only by running the game.
#
# PROPNIX_GBE_ORACLE=<dir> points at another oracle package (bin/gbe-interface-oracle +
# share/gbe-interface-oracle/patterns.txt): a candidate gbe_fork release's, to see whether it would satisfy
# every pin BEFORE bumping to it. The <system> argument picks the attribute path and labels the output.
# ci/gbe-interface-check-test.sh exercises every verdict of this script against stubs.
set -uo pipefail
trap 'rm -rf "${work:-}"' INT TERM EXIT

sys=${1:-}
[ -n "$sys" ] || {
  echo "usage: ci/gbe-interface-check.sh <system>" >&2
  exit 1
}
cd "$(dirname "$0")/.." || exit 1

die() {
  echo "gbe-interface-check($sys): $*" >&2
  exit 1
}
type -P jq >/dev/null || die "jq is not on PATH"
work=$(mktemp -d) || die "mktemp failed"

oracle=${PROPNIX_GBE_ORACLE:-$(nix build --no-link --print-out-paths ".#legacyPackages.$sys.gbeFork.interfaceOracle")} ||
  die "realizing the pinned gbe_fork's interface oracle failed"
[ -x "$oracle/bin/gbe-interface-oracle" ] && [ -s "$oracle/share/gbe-interface-oracle/patterns.txt" ] ||
  die "'$oracle' is not an interface-oracle package (no bin/gbe-interface-oracle + share/gbe-interface-oracle/patterns.txt)"

failures=() unverified=() exempt=() ok=() tolerated=()
report() { # <game> <row> <reason>
  failures+=("$1	$2	$3")
  echo "gbe-interface-check($sys): $1 ($2): $3" >&2
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error title=gbe_fork interface check — $1::$2 — $3"
}
notice() { # <game> <row> <text>
  echo "  $1 ($2): $3"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::notice title=gbe_fork interface check — $1::$2 — $3"
}

# ── 1. the scanner's pattern list vs the pinned generator's ──────────────────────────────────────────
grep -v '^[[:space:]]*#' pkgs/propnix-cli/steam-api-interface-patterns.txt | grep . | sort -u >"$work/ours"
sort -u "$oracle/share/gbe-interface-oracle/patterns.txt" >"$work/theirs"
if ! cmp -s "$work/ours" "$work/theirs"; then
  report "propnix-cli" "steam-api-interface-patterns.txt" "the scanner's pattern list has drifted from the pinned gbe_fork's tools/generate_interfaces ($(diff "$work/ours" "$work/theirs" | grep -E '^[<>]' | tr '\n' ' ')) — every recorded fingerprint may be incomplete; update the file and re-run \`propnix pin <game> --fingerprint\` for every game"
fi

# ── 2. the shim map: game → platform → { enable, neverRequested } ─────────────────────────────────────
# `null` for a game or platform the eval could not answer: held to the gate.
if [ -n "${PROPNIX_SHIM_MAP:-}" ]; then
  cp "$PROPNIX_SHIM_MAP" "$work/map.json" || die "PROPNIX_SHIM_MAP: cannot read '$PROPNIX_SHIM_MAP'"
elif ! nix eval --json ".#legacyPackages.$sys.games" --apply '
    gs: builtins.mapAttrs (name: g:
      let
        r = builtins.tryEval (
          let
            plats = builtins.attrNames (g.config.fetchInfo.steam or { });
            one = p:
              let
                c = (g.apply { fetcher = "steam"; emulatedPlatform = p; }).config;
                v = { enable = c.steam.emu.enable; neverRequested = c.steam.emu.neverRequested; };
              in
              builtins.deepSeq v v;
            per = p: let e = builtins.tryEval (one p); in if e.success then e.value else null;
            all = builtins.listToAttrs (map (p: { name = p; value = per p; }) plats);
          in
          builtins.deepSeq all all
        );
      in
      if r.success then r.value else null
    ) gs' >"$work/map.json" 2>"$work/map.err"; then
  echo "gbe-interface-check($sys): WARNING: evaluating the games' steam.emu config failed; every row is held to the gate (no exemptions, no tolerances):" >&2
  tail -5 "$work/map.err" >&2
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning title=gbe_fork interface check::the steam.emu config eval failed; every row is held with no exemptions"
  echo '{}' >"$work/map.json"
fi

# ── 3. every Steam row, enumerated FIRST into a file ──────────────────────────────────────────────────
# A failure of the enumeration itself is a failure of the check: a loop fed by process substitution would
# read whatever jq managed to print before it died and exit 0 with rows silently unchecked.
# Columns: game, row, platform(s) the row belongs to (a DLC/extra row: every platform with base rows),
# fingerprint ("null" when absent). `steamApiInterfaces` must be null or an array of strings.
shopt -s nullglob # no versions.json at all must reach the empty-rows guard, not hand jq a literal glob
: >"$work/rows"
for v in pkgs/games/*/versions.json; do
  g=$(basename "$(dirname "$v")")
  jq -r --arg g "$g" '
    def fp: .steamApiInterfaces
      | if . == null then "null"
        elif type == "array" and all(type == "string") then join(" ")
        else error("steamApiInterfaces must be null or an array of strings")
        end;
    (.fetchInfo.steam // {}) as $steam
    | ([$steam | to_entries[] | select((.value // []) | length > 0) | .key] | join(",")) as $allplats
    | (($steam | to_entries[] | .key as $p | (.value // []) | to_entries[]
        | [$g, "steam/\($p)[\(.key)]", $p, (.value | fp)]),
       ((.dlc // {}) | to_entries[] | select(.value.appId != null) | [$g, "dlc.\(.key)", $allplats, (.value | fp)]),
       ((.extra // {}) | to_entries[] | select(.value.appId != null) | [$g, "extra.\(.key)", $allplats, (.value | fp)]))
    | @tsv' "$v" >>"$work/rows" || die "enumerating the Steam rows of $v failed (see jq's message above)"
done
[ -s "$work/rows" ] || die "no Steam rows found under pkgs/games — the enumeration is broken, not the tree"

# ── 4. ONE oracle run over the union of every recorded revision ──────────────────────────────────────
cut -f4 "$work/rows" | tr ' ' '\n' | grep -vx 'null' | grep . | sort -u >"$work/revs"
: >"$work/verdicts"
if [ -s "$work/revs" ]; then
  # shellcheck disable=SC2046
  "$oracle/bin/gbe-interface-oracle" $(cat "$work/revs") >"$work/verdicts"
  rc=$?
  [ $rc -eq 0 ] || [ $rc -eq 1 ] || die "the interface oracle failed to run (exit $rc) — see its stderr above"
  [ "$(wc -l <"$work/verdicts")" -eq "$(wc -l <"$work/revs")" ] ||
    die "the oracle answered for $(wc -l <"$work/verdicts") of $(wc -l <"$work/revs") revisions"
fi
verdict() { awk -F'\t' -v r="$1" '$1 == r { print $2; exit }' "$work/verdicts"; }
# For (game, platforms): "exempt" only when EVERY listed platform has the shim off, else "held"; then the
# union of those platforms' neverRequested lists. Two lines on stdout.
shim_info() { # <game> <platforms,comma-joined>
  jq -r --arg g "$1" --arg ps "$2" '
    ($ps | split(",") | map(select(. != ""))) as $plats
    | (.[$g] // {}) as $game
    | [ $plats[] | $game[.] ] as $infos
    | (if ($plats | length) > 0 and all($infos[]; . != null and .enable == false) then "exempt" else "held" end),
      ([ $infos[] | select(. != null) | .neverRequested[]? ] | unique | join(" "))' "$work/map.json"
}

while IFS=$'\t' read -r game row plats revs; do
  # Exempt before unverified: a game that never loads the shim has nothing to fingerprint either.
  { read -r state; read -r tol; } < <(shim_info "$game" "$plats")
  if [ "$state" = exempt ]; then
    exempt+=("$game	$row")
    echo "  $game ($row): exempt — steam.emu.enable is false on ${plats//,/ }, the shim is never loaded"
    continue
  fi
  if [ "$revs" = "null" ]; then
    unverified+=("$game	$row")
    notice "$game" "$row" "no steamApiInterfaces recorded — unverified; run \`propnix pin $game --fingerprint\`"
    continue
  fi
  unserved="" tolerated_here="" stale=""
  for r in $revs; do
    vd=$(verdict "$r")
    case " $tol " in *" $r "*) listed=1 ;; *) listed=0 ;; esac
    if [ "$vd" = served ]; then
      [ $listed = 1 ] && stale="$stale $r"
    elif [ $listed = 1 ]; then
      tolerated_here="$tolerated_here $r($vd)"
    else
      unserved="$unserved $r($vd)"
    fi
  done
  if [ -n "$unserved" ]; then
    report "$game" "$row" "its Steamworks SDK names revisions the pinned gbe_fork does not serve:${unserved} — at runtime that is a silent exit 73 (or a NULL vtable) the moment the game asks; bump emulators/gbe-fork, or declare a revision the game provably never requests in steam.emu.neverRequested"
    continue
  fi
  n=$(wc -w <<<"$revs")
  if [ -n "$tolerated_here" ]; then
    tolerated+=("$game	$row	${tolerated_here# }")
    echo "  $game ($row): $n revision(s); served except${tolerated_here}, tolerated by steam.emu.neverRequested"
  else
    ok+=("$game	$row")
    echo "  $game ($row): $n revision(s), all served ✓"
  fi
  [ -n "$stale" ] && notice "$game" "$row" "steam.emu.neverRequested lists${stale}, which the pinned gbe_fork now serves — the entry can go"
done <"$work/rows"

summary() {
  echo "### gbe_fork interface check ($sys)"
  echo
  if [ ${#failures[@]} -gt 0 ]; then
    echo "**${#failures[@]} failure(s)** — a pinned build asks the shim for something it cannot serve:"
    echo
    echo "| game | row | problem |"
    echo "|---|---|---|"
    for f in "${failures[@]}"; do
      IFS=$'\t' read -r g r why <<<"$f"
      echo "| \`$g\` | \`$r\` | $(printf '%s' "$why" | sed 's/|/\\|/g') |"
    done
    echo
  fi
  if [ ${#tolerated[@]} -gt 0 ]; then
    echo "${#tolerated[@]} row(s) name a revision the shim does not serve, tolerated by \`steam.emu.neverRequested\`:"
    for t in "${tolerated[@]}"; do
      IFS=$'\t' read -r g r what <<<"$t"
      echo "- \`$g\` \`$r\`: $what"
    done
    echo
  fi
  [ ${#exempt[@]} -gt 0 ] && echo "${#exempt[@]} row(s) exempt (\`steam.emu.enable = false\`, the shim is never loaded)."
  [ ${#unverified[@]} -gt 0 ] && echo "${#unverified[@]} row(s) carry no fingerprint yet (\`propnix pin <game> --fingerprint\`)."
  echo "${#ok[@]} row(s) verified against the pinned gbe_fork."
}
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && summary >>"$GITHUB_STEP_SUMMARY"

if [ ${#failures[@]} -gt 0 ]; then
  echo
  echo "gbe-interface-check($sys): ${#failures[@]} failure(s):" >&2
  for f in "${failures[@]}"; do
    IFS=$'\t' read -r g r why <<<"$f"
    echo "  $g ($r): $why" >&2
  done
  exit 1
fi
echo "gbe-interface-check($sys): every fingerprinted Steam pin is served by the pinned gbe_fork (${#ok[@]} verified, ${#tolerated[@]} tolerated, ${#exempt[@]} exempt, ${#unverified[@]} unverified)"
