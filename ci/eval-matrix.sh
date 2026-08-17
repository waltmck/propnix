#!/usr/bin/env bash
# ci/eval-matrix.sh — force every pinned (game × fetcher × emulatedPlatform) combo of the flake's
# `ci.<system>` eval matrix (lib/tests/eval-matrix.nix), ONE `nix eval` PROCESS PER TARGET: an in-eval
# infinite recursion aborts the whole evaluator (tryEval cannot catch it), so per-process isolation is
# what keeps one blown combo from masking the rest — and makes the failing combo identifiable by name.
#
# Pure eval only (nothing is built or fetched); meta.broken titles still evaluate (the ci scope is
# instantiated with allowBroken). Usage, from the repo root:
#
#   ci/eval-matrix.sh <system> [jobs]      # e.g. ci/eval-matrix.sh aarch64-linux 4
#
# Needs nix (flakes enabled) + jq. Exits non-zero if any target fails, after printing every failure's
# full nix error. Writes a summary table to $GITHUB_STEP_SUMMARY when set.
set -euo pipefail

system=${1:?usage: ci/eval-matrix.sh <system> [jobs]}
jobs=${2:-4}

# A healthy target evals in seconds; the cap only exists so a pathological eval (runaway recursion that
# allocates instead of overflowing) surfaces as its own FAIL instead of eating the job timeout.
timeout_secs=900

outdir=$(mktemp -d)
trap 'rm -rf "$outdir"' INT TERM EXIT

echo "enumerating pinned (game × fetcher × emulatedPlatform) targets for ${system}…"
if ! names_json=$(nix eval --json ".#ci.${system}.names"); then
  echo "ERROR: target enumeration failed — the nix error above names the culprit (a game whose" >&2
  echo "fetchInfo no longer evaluates); no per-target results are possible until it is fixed." >&2
  exit 1
fi
mapfile -t names < <(jq -r '.[]' <<<"$names_json")
if [[ ${#names[@]} -eq 0 ]]; then
  echo "ERROR: the ${system} eval matrix enumerated zero targets — the matrix wiring itself is broken" >&2
  exit 1
fi
echo "${#names[@]} targets"

# One isolated evaluator per target. Never returns non-zero itself — pass/fail lands in the .res file
# (xargs must drain the whole list; aggregation decides the exit code).
run_one() {
  local name=$1
  local slug=${name//\//_}
  local rc=0
  timeout -k 15 "$TIMEOUT_SECS" \
    nix eval --raw ".#ci.${SYSTEM}.targets.\"${name}\"" >"$OUTDIR/$slug.out" 2>"$OUTDIR/$slug.log" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo ok >"$OUTDIR/$slug.res"
    echo "ok   ${name}"
  elif [[ $rc -eq 124 || $rc -eq 137 ]]; then
    echo "fail (timeout after ${TIMEOUT_SECS}s)" >"$OUTDIR/$slug.res"
    echo "FAIL ${name} (timeout)"
  else
    echo fail >"$OUTDIR/$slug.res"
    echo "FAIL ${name}"
  fi
}
export -f run_one
export SYSTEM=$system OUTDIR=$outdir TIMEOUT_SECS=$timeout_secs

# `|| true`: if a child dies by signal or fails to spawn, xargs exits 125/126 and stops dispatching —
# aggregation below must still run (undispatched targets show up as "never completed"), or set -e plus
# the EXIT trap would destroy every log before anything is reported.
# shellcheck disable=SC2016 # $1 is for the child bash, not this shell
printf '%s\n' "${names[@]}" | xargs -d '\n' -n1 -P "$jobs" bash -c 'run_one "$1"' _ || true

fails=()
for name in "${names[@]}"; do
  status=$(cat "$outdir/${name//\//_}.res" 2>/dev/null || echo "fail (evaluator never completed — killed or not dispatched)")
  [[ $status == ok ]] || fails+=("$name"$'\t'"$status")
done

echo
echo "== eval matrix (${system}): $((${#names[@]} - ${#fails[@]}))/${#names[@]} targets evaluated =="

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  {
    echo "### eval matrix — ${system}: $((${#names[@]} - ${#fails[@]}))/${#names[@]} ok"
    echo
    echo "| target (game/fetcher/platform) | result |"
    echo "|---|---|"
    for name in "${names[@]}"; do
      echo "| \`${name}\` | $(cat "$outdir/${name//\//_}.res" 2>/dev/null || echo "fail (never completed)") |"
    done
  } >>"$GITHUB_STEP_SUMMARY"
fi

if [[ ${#fails[@]} -gt 0 ]]; then
  for entry in "${fails[@]}"; do
    name=${entry%%$'\t'*}
    status=${entry#*$'\t'}
    echo
    echo "--- FAIL ${name} [${status}] ---"
    cat "$outdir/${name//\//_}.log" 2>/dev/null || echo "(no log — the evaluator was never dispatched or was killed before writing one)"
  done
  exit 1
fi
