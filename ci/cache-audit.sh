#!/usr/bin/env bash
# ci/cache-audit.sh <system> — the standing gate for the CACHE POLICY:
#
#   every non-unfree package in the scope that upstream does not already serve must be reachable
#   from some .github/workflows/cachix.yml job, so that a fresh machine SUBSTITUTES it instead of
#   compiling it.
#
# Game packages are exempt and skipped: their payloads are credentialed and unfree, and pushing them
# would be redistribution rather than caching (the cachix workflow's header says the same).
#
# Two ways to satisfy the policy, both accepted here:
#   * cache.nixos.org already has the path — nixpkgs builds it for us (box64 is the live example), so
#     pushing a copy would buy nothing.
#   * some job in cachix.yml builds it, either NAMED in its `attrs` or reached through the closure of
#     something that is (wineMono rides along inside prefixLower). Cachix pushes every path a job
#     builds locally, not just the roots, so closure coverage is real coverage.
#
# WHY A GATE AND NOT A README LINE: the two holes this was written after — fexInterpreter on aarch64,
# galaxyStub on x86_64 — were both found by hand, months apart, and both were invisible precisely
# because the package still WORKED; it just silently compiled from source on every user's machine.
# The per-system split is the trap in particular: galaxyStub is a different derivation on each host
# and was covered on only one of them, so a check that merely asked "is this name mentioned in the
# workflow?" would have passed it. This asks per system.
#
# The expectations are READ FROM the workflow rather than restated here, so there is one list, not two.
set -uo pipefail

sys=${1:-}
[ -n "$sys" ] || {
  echo "usage: ci/cache-audit.sh <system>" >&2
  exit 1
}
cd "$(dirname "$0")/.." || exit 1
workflow=.github/workflows/cachix.yml

# `type -P`, not `command -v`: the latter would find THIS function and recurse into a bogus lookup.
yq() { local bin; bin=$(type -P yq) && "$bin" "$@" || nix run --impure nixpkgs#yq-go -- "$@"; }

# A LOCAL failure is a broken gate, never a soft skip. Only the upstream-cache HTTP query below is
# allowed to degrade, because that one depends on somebody else's uptime; an eval that does not run
# means this script cannot see what it is auditing, and reporting OK then is worse than being absent.
# NB: `die` inside `$(nixq …)` runs in a SUBSHELL, so its exit only ends that subshell — every call
# site therefore ends in `|| exit 1`, which the failed substitution's status triggers (the diagnostic
# has already been printed by then). The same trap in sharper form is `mapfile < <(cmd)`: mapfile
# itself succeeds whatever cmd did, so a failed enumeration would sail through as a clean pass.
#
# STDERR IS NEVER PART OF A RESULT. Nix writes warnings there on perfectly successful runs — a dirty
# git tree, an "(ignored) SQLite database is busy", an evaluation warning from our own modules — so
# folding it into the captured stdout with `2>&1` corrupts whatever is parsed next. It is not a
# theoretical mix-up: it yields a store path with a warning glued to its front, which then reaches
# `nix-store -q` as one argument and fails with a nonsense "path … is not in the Nix store". Each
# helper therefore sends stderr to $errlog and quotes it ONLY in a failure diagnostic.
errlog=$(mktemp)
die() {
  echo "cache-audit($sys): $*" >&2
  exit 1
}
saidwhat() { # the captured stderr, for a diagnostic; empty output stays legible
  local e
  e=$(cat "$errlog")
  printf '%s' "${e:-<no stderr>}"
}
nixq() {
  local out
  out=$(nix eval --json "$@" 2>"$errlog") || die "\`nix eval --json $*\` failed:
$(saidwhat)"
  printf '%s' "$out"
}
jqr() {
  local out
  out=$(jq -r "$@" 2>"$errlog") || die "jq -r $* failed:
$(saidwhat)"
  printf '%s' "$out"
}

# The attrs cachix.yml builds FOR THIS SYSTEM: a job step passes `system` + `attrs` to the composite
# action, either literally or through its matrix, so read both shapes and keep the ones whose system
# matches. `${{ … }}` templates are resolved against the job's own matrix include list.
mapfile -t covered < <(
  yq -o=json '.jobs' "$workflow" | jq -r --arg sys "$sys" '
    to_entries[] | .value as $job
    | ($job.steps // [])[] | select(.with != null) | .with as $w
    | ($job.strategy.matrix.include // [{}]) as $inc
    | $inc[] | . as $m
    | (if ($w.system | test("matrix\\.")) then ($m.system // "") else $w.system end) as $s
    | (if ($w.attrs  | test("matrix\\.")) then ($m.attrs  // "") else $w.attrs  end) as $a
    | select($s == $sys) | $a | split(" ")[] | select(length > 0)
  ' | sort -u
)
[ ${#covered[@]} -gt 0 ] || {
  echo "cache-audit($sys): parsed NO attrs out of $workflow — the parser is broken, not the policy" >&2
  exit 1
}
echo "== cache-audit ($sys) =="
echo "   cachix.yml builds here: ${covered[*]}"

# Every derivation the closure of those attrs would build, as .drv paths. Instantiation only — nothing
# is realized, so this is as cheap as an eval and safe to run on any host for any system.
covered_drvs=$(mktemp)
trap 'rm -f "$covered_drvs" "$errlog"' EXIT
for a in "${covered[@]}"; do
  # An attr a job NAMES but that does not evaluate here is a broken workflow entry (a typo, or an attr
  # that exists on only one system) — that is precisely the class of bug this gate exists to catch.
  d=$(nix eval --raw ".#legacyPackages.$sys.$a.drvPath" 2>"$errlog") ||
    die "$workflow builds '$a' on $sys, but it does not evaluate:
$(saidwhat)"
  nix-store -q --requisites "$d" >>"$covered_drvs" 2>"$errlog" ||
    die "could not query the closure of $a ($d):
$(saidwhat)"
done
sort -u -o "$covered_drvs" "$covered_drvs"

# Assign first, THEN split: `mapfile` reports success even when the command feeding it failed, which is
# how an empty package list would otherwise be audited to a clean pass.
games_json=$(nixq --apply 'builtins.attrNames' ".#legacyPackages.$sys.games") || exit 1
attrs_json=$(nixq --apply '
  s: let l = builtins.attrNames s; in builtins.filter (n:
    let v = builtins.tryEval (s.${n}.type or null); in v.success && v.value == "derivation") l
' ".#legacyPackages.$sys") || exit 1
mapfile -t games < <(jqr '.[]' <<<"$games_json")
mapfile -t attrs < <(jqr '.[]' <<<"$attrs_json")
[ ${#attrs[@]} -gt 0 ] || die "the scope enumerated NO derivations — the audit would pass vacuously"

gaps=() unknown=()
for a in "${attrs[@]}"; do
  printf '%s\n' "${games[@]}" | grep -qxF "$a" && continue
  info=$(nixq ".#legacyPackages.$sys.$a" --apply 'p: { out = p.outPath; drv = p.drvPath; unfree = (p.meta.unfree or false); }') || exit 1
  [ "$(jq -r .unfree <<<"$info")" = "true" ] && continue # unfree: never ours to redistribute
  hash=$(basename "$(jq -r .out <<<"$info")" | cut -d- -f1)

  code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "https://cache.nixos.org/$hash.narinfo")
  case "$code" in
    200) continue ;; # upstream serves it
    404) ;;          # ours to cache — fall through
    *)
      unknown+=("$a (cache.nixos.org said '$code')")
      continue
      ;;
  esac

  printf '%s\n' "${covered[@]}" | grep -qxF "$a" && continue
  grep -qxF "$(jq -r .drv <<<"$info")" "$covered_drvs" && continue
  gaps+=("$a")
done

# A cache.nixos.org that will not answer is an outage, not a policy violation: say so and stay green,
# because failing here would block every PR on someone else's uptime.
[ ${#unknown[@]} -gt 0 ] && printf '   WARN unverifiable (upstream cache unreachable): %s\n' "${unknown[*]}"

if [ ${#gaps[@]} -gt 0 ]; then
  cat >&2 <<EOF
== cache-audit ($sys): ${#gaps[@]} package(s) neither served by cache.nixos.org nor built by CI ==
  ${gaps[*]}
Every user building propnix on $sys compiles these from source. Add each to a job's \`attrs\` in
$workflow (matching this system), or — if it is genuinely unfree or a game payload — mark it so.
EOF
  exit 1
fi
echo "   OK — every non-unfree scope package is either upstream-cached or built by a cachix job"
