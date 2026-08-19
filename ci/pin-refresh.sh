#!/usr/bin/env bash
# ci/pin-refresh.sh — refresh every game's pin, recording per-game outcomes for the caller to act on.
#
# TWO PHASES, RUN SEPARATELY, and the split is the point:
#
#   check   ANONYMOUS. Asks both stores what the newest build is — GOG's build list is GOG's own, and the
#           Steam side reads api.steamcmd.net, a THIRD-PARTY appinfo mirror (Valve publishes no
#           unauthenticated appinfo endpoint; the credential-free alternative would be an anonymous CM
#           PICS session, which is the fallback if that mirror ever dies). Neither needs a credential.
#           A bad mirror is bounded: the never-move-backwards guard rejects a rollback, and Steam itself
#           issues the manifest request codes, so a fabricated manifest id simply fails to download.
#           The overwhelmingly common "nothing changed" week ends here, so the caller never has to put a
#           credential on disk at all.
#   repin   Needs the account. Streams the payload for each game `check` marked `pending` and rewrites its
#           versions.json.
#
# Per-game outcomes:
#   frozen      versions.json declares `pin.freeze` — deliberately held, so NOT an issue and NOT a failure
#   up-to-date  nothing to do
#   pending     upstream moved; awaiting the credentialed phase
#   updated     rewritten and validated; the caller puts it in a PR
#   blocked     the tool exited 4 — a human must act: no credential, the account does not own it (or one of
#               its DLC), the pinned build has aged out of the store's list, or a construct the tool
#               refuses to guess at. NOT a failure: the caller opens an issue.
#   failed      any other non-zero exit — a real bug, and the only outcome that fails the run
#
# All-or-nothing per game is enforced INSIDE `propnix pin` (base payloads and every DLC together, or
# nothing is written), so this script never reasons about partial state: it either gets a complete new
# versions.json on stdout or a non-zero exit and leaves the file alone.
#
# Usage, from the repo root:
#   ci/pin-refresh.sh check <outdir> [system]
#   ci/pin-refresh.sh repin <outdir> [system]
# Writes <outdir>/<game>.check.json, <outdir>/summary.json, <outdir>/pending, and a table to
# $GITHUB_STEP_SUMMARY.
set -euo pipefail

# An explicit check rather than ${1:?...}: brace/bracket characters inside a :? message are parsed as a
# brace expansion and glob range, which mangles the very message meant to help.
usage() {
  echo "usage: $0 {check|repin} <outdir> [system]" >&2
  exit 2
}
phase=${1:-}
outdir=${2:-}
system=${3:-x86_64-linux}
[ -n "$phase" ] && [ -n "$outdir" ] || usage
mkdir -p "$outdir"
results="$outdir/summary.json"
[ -f "$results" ] || printf '[]' > "$results"

# Replace any existing entry for the game, so `repin` supersedes what `check` recorded.
record() { # game status detail [version]
  jq --arg g "$1" --arg s "$2" --arg d "$3" --arg v "${4:-}" \
     'map(select(.game != $g)) + [{game:$g, status:$s, detail:$d, version:$v}]' "$results" > "$results.new"
  mv "$results.new" "$results"
}
# Keep the TAIL, not the head: the tool writes progress to the same stream, so the thing worth reading —
# the error — is at the END. `cut -c1-N` reliably kept the progress spam and dropped the reason.
#
# BOTH \n and \r: the percentage counter redraws itself with a carriage return, so a detail that keeps
# its CRs mangles the step-summary markdown table and the issue body it is pasted into.
#
# The `sed` drops any UTF-8 continuation bytes the byte-wise cut left stranded at the front. The messages
# are full of em-dashes, so without it a truncated detail routinely starts with a replacement character in
# the step summary and the issue body. LC_ALL=C is load-bearing: in a UTF-8 locale that byte range is not
# a valid collation range and sed refuses the expression outright.
trim() { tr '\n\r' '  ' | tail -c "${1:-400}" | LC_ALL=C sed 's/^[\x80-\xBF]*//'; }

phase_check() {
  printf '[]' > "$results"
  : > "$outdir/pending"
  local games
  games=$(propnix games --repo .)
  echo "considering: $(echo "$games" | tr '\n' ' ')" >&2
  for game in $games; do
    local check="$outdir/$game.check.json"
    set +e
    propnix pin "$game" --check --repo . > "$check" 2> "$outdir/$game.check.err"
    local rc=$?
    set -e
    local detail
    detail=$(trim 400 < "$outdir/$game.check.err")
    case $rc in
      0) : ;;
      # Exit 4 = a human must act. Reachable anonymously: a pinned build that has aged out of the store's
      # (paginated) list, a withdrawn manifest, a delisted title. Recording this as `failed` would redden
      # the run every week and never file the issue that says what to do.
      4)
        record "$game" blocked "$detail"; echo "  $game: BLOCKED — $detail" >&2
        # The tool prints a stub report before exiting 4, so this is belt-and-braces for an OLDER binary
        # (substituted from the cache) that predates that. An empty check.json is not a cosmetic problem:
        # `ci/pin-issue.sh` dies on one under `set -e`, taking every later step of the workflow with it.
        [ -s "$check" ] || jq -n --arg g "$game" --arg d "$detail" \
          '{game:$g, upToDate:false, blocked:true, detail:$d, frozen:false,
            pinnedTo:null, policyReason:null, changes:[]}' > "$check"
        continue ;;
      *) record "$game" failed "$detail"; echo "  $game: CHECK FAILED — $detail" >&2; continue ;;
    esac
    if [ "$(jq -r '.frozen' "$check")" = "true" ]; then
      record "$game" frozen "$(jq -r '.policyReason // ""' "$check")"
      echo "  $game: frozen — $(jq -r '.policyReason // "no reason recorded"' "$check")" >&2
    elif [ "$(jq -r '.upToDate' "$check")" = "true" ]; then
      local pinned
      pinned=$(jq -r '.pinnedTo // ""' "$check")
      record "$game" up-to-date "${pinned:+held at pinned version $pinned}" "$pinned"
      echo "  $game: up to date${pinned:+ (pinned to $pinned)}" >&2
    else
      local version
      version=$(jq -r '[.changes[].version // empty] | first // ""' "$check")
      record "$game" pending "upstream moved" "$version"
      echo "$game" >> "$outdir/pending"
      echo "  $game: upstream moved${version:+ to $version}" >&2
    fi
  done
  echo "pending: $(tr '\n' ' ' < "$outdir/pending")" >&2
}

phase_repin() {
  if [ ! -s "$outdir/pending" ]; then
    echo "nothing moved; no payload to re-hash" >&2
    return 0
  fi
  while read -r game; do
    [ -n "$game" ] || continue
    local version new detail rc target
    version=$(jq -r --arg g "$game" '.[] | select(.game == $g) | .version' "$results")
    echo "  $game: recomputing${version:+ for $version}" >&2
    new="$outdir/$game.versions.json"
    set +e
    # `--stdout` keeps the validate-then-swap flow below: the tool writes versions.json IN PLACE by
    # default, and we want the eval gate to run before the file moves.
    propnix pin "$game" --stdout --repo . > "$new" 2> "$outdir/$game.pin.err"
    rc=$?
    set -e
    detail=$(trim 600 < "$outdir/$game.pin.err")
    case $rc in
      0) : ;;
      4) record "$game" blocked "$detail" "$version"; echo "  $game: BLOCKED — $detail" >&2; continue ;;
      *) record "$game" failed "$detail"; echo "  $game: FAILED — $detail" >&2; continue ;;
    esac

    target="pkgs/games/$game/versions.json"
    cp "$target" "$new.orig"
    cp "$new" "$target"
    # Validate by PURE EVAL before letting it near a commit: catches a malformed pin (an unknown key, a bad
    # SRI, a coerced JSON type) without downloading anything. Eval is host-independent, so naming a system
    # here costs nothing even when it is not the runner's.
    #
    # Through `ci.<system>.games`, NOT `legacyPackages`: that scope is instantiated with allowBroken, and
    # forcing a `meta.broken` package's drvPath throws. Validating through legacyPackages therefore
    # reverted such a game's rewrite and recorded it `failed` every single week, forever, for a mark that
    # says nothing about whether the PIN is well formed. Brokenness is not dropped — only this gate is
    # taught to look past it.
    if ! nix eval --raw ".#ci.$system.games.$game.drvPath" > /dev/null 2> "$outdir/$game.eval.err"; then
      cp "$new.orig" "$target"
      record "$game" failed "the rewritten versions.json does not evaluate: $(trim 400 < "$outdir/$game.eval.err")"
      echo "  $game: FAILED eval — reverted" >&2
      continue
    fi
    record "$game" updated "$(git diff --stat -- "$target" | tail -1)" "$version"
    echo "  $game: updated${version:+ to $version}" >&2
  done < "$outdir/pending"
}

case "$phase" in
  check) phase_check ;;
  repin) phase_repin ;;
  *) usage ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Pin refresh ($phase)"
    echo
    echo "| game | outcome | version | detail |"
    echo "|---|---|---|---|"
    # NB: this repo is public, so the summary is world-readable. `detail` is the tool's own message, which
    # redacts signed URLs and never carries a token, and it is truncated here regardless.
    jq -r '.[] | "| \(.game) | \(.status) | \(.version // "") | \(.detail // "" | .[0:160]) |"' "$results"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# REPORT a failure; do not fail the run HERE.
#
# One CDN 500 on one title used to exit 1 from this script, which — with the workflow's default step
# gating — skipped every later step: the issues, the close sweeps, the commits and the PR. So a single
# transient failure discarded every OTHER game's validated rewrite. The failures are recorded in
# summary.json and printed here; the workflow asserts on them in a FINAL step, after the work that must
# not be lost has already landed. (`blocked` was never a failure: it is a human's job and gets an issue.)
if [ "$(jq -r '[.[] | select(.status == "failed")] | length' "$results")" != "0" ]; then
  echo "pin-refresh: one or more games failed unexpectedly (the run asserts on this at the end)" >&2
  jq -r '.[] | select(.status == "failed") | "  \(.game): \(.detail)"' "$results" >&2
fi
