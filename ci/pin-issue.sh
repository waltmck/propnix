#!/usr/bin/env bash
# pin-issue.sh — the issue lifecycle for a game whose pin has fallen behind upstream.
#
# Exactly ONE open issue per game, ever:
#   open-or-edit  opens an issue if there is no open one for this game, otherwise EDITS the existing one —
#                 and only when the upstream target actually moved, so a game that stays out of date for
#                 months does not generate a notification every week.
#   close-if-open closes it once the game reaches the newest upstream version.
#
# A CLOSED issue is NEVER reopened. That invariant lives in exactly one place: `find_open` only ever asks
# for `--state open`, and this script never calls `gh issue reopen`. So a game that regresses later gets a
# NEW issue, which is what was asked for — and is also the honest representation, since the second lag is
# a different event from the first.
#
# Identity is a hidden marker in the body rather than the title, so a human may retitle an issue freely:
#   <!-- propnix-pin: game=<game> target=<deduped, sorted, comma-joined new ids> -->
# Lookup goes through the REST issues LIST resource via `gh api`, and filters the marker locally.
#
# It deliberately does NOT use `gh issue list`. That looks like the immediately-consistent path but is not:
# cli/cli v2.96.0 pkg/cmd/issue/list/list.go:235 dispatches to searchIssues() whenever Search **or Labels**
# or Milestone or IssueType is set, so even `--label` goes through the eventually-consistent GraphQL search
# index. A lookup miss is exactly how a duplicate issue gets opened, so the lookup must not touch search at
# all.
#
# Usage:
#   ci/pin-issue.sh open-or-edit <game> <check.json>   # check.json = `propnix pin <game> --check` output
#   ci/pin-issue.sh close-if-open <game> [reached-version] [extra-note] [newest|held|gone]
#   ci/pin-issue.sh render <game> <check.json>         # preview the body; touches nothing
#   ci/pin-issue.sh list-open                          # one line per game that has an open issue
#
# Requires: gh (authenticated via GH_TOKEN), jq. GH_REPO may name the repo when not run from a checkout.
set -euo pipefail

LABEL="${PROPNIX_PIN_LABEL:-pin-outdated}"
MARKER_PREFIX="<!-- propnix-pin: game="

die() { printf 'pin-issue: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "$1 is required"; }
need gh
need jq

# ONE scratch dir with ONE top-level trap. A `trap … EXIT` set inside a function is script-global, not
# function-scoped, so the previous per-command trap silently replaced whatever the script had (and left
# temp files behind for any path that did not set it).
work=$(mktemp -d)
trap 'rm -rf "$work"' INT TERM EXIT

# The label must exist before `gh issue create --label` is used, or the create fails. `--force` makes this
# idempotent (it updates colour/description if the label is already there).
ensure_label() {
  gh label create "$LABEL" \
    --color D93F0B \
    --description "A pinned game version has fallen behind upstream" \
    --force >/dev/null
}

# The number of the single open issue for this game, or empty. `state=open` in the query is also what
# makes "never reopen" fall out for free: a closed issue is never even a candidate.
find_open() {
  local game=$1 nums first extra
  nums=$(matching "$game")
  [ -z "$nums" ] && return 0
  first=$(printf '%s\n' "$nums" | head -1)
  # A plurality should be impossible, but if one ever exists (a race, or a hand-created issue carrying the
  # marker) it would otherwise persist forever, since we only ever look at .[0]. Collapse the extras onto
  # the oldest so the invariant is restored rather than merely reported.
  extra=$(printf '%s\n' "$nums" | tail -n +2)
  if [ -n "$extra" ]; then
    echo "pin-issue: $game has more than one open issue; collapsing onto #$first" >&2
    while read -r n; do
      [ -n "$n" ] || continue
      gh issue close "$n" --reason duplicate --duplicate-of "$first" \
        --comment "Duplicate of #$first, which is the tracking issue for this pin." >&2 || true
    done <<< "$extra"
  fi
  printf '%s' "$first"
}

# Every OPEN issue carrying our label, as a flat JSON array. The REST issues resource also returns pull
# requests, so those are dropped — this repo labels its update PRs too, and a PR must never be mistaken
# for a drift issue.
open_pin_issues() {
  local query=$1 # "&labels=…" or ""
  gh api --paginate --slurp \
      "repos/{owner}/{repo}/issues?state=open${query}&per_page=100" \
    | jq 'if (type == "array") and ((.[0]? | type) == "array") then flatten(1) else . end
          | map(select(has("pull_request") | not))'
}

# Issues carrying OUR marker for this game, oldest first. The label is only a server-side prefilter, so if
# the labelled query finds nothing we retry WITHOUT it: someone removing the label by hand would otherwise
# make the issue permanently invisible to us, and we would open a fresh duplicate every single week.
matching() {
  local game=$1 out
  out=$(open_pin_issues "&labels=$LABEL" \
        | jq -r --arg m "${MARKER_PREFIX}${game} " \
            'map(select(.body != null and (.body | contains($m)))) | sort_by(.number) | .[].number')
  if [ -z "$out" ]; then
    out=$(open_pin_issues "" \
          | jq -r --arg m "${MARKER_PREFIX}${game} " \
              'map(select(.body != null and (.body | contains($m)))) | sort_by(.number) | .[].number')
    [ -n "$out" ] && echo "pin-issue: found an issue for $game with the $LABEL label missing" >&2
  fi
  printf '%s' "$out"
}

# Every game with an open issue, one per line. ONE API call, so a caller can intersect it with a set of
# games instead of asking about each in turn.
#
# KNOWN LIMITATION, deliberately not fixed here: this asks only for LABELLED issues, so an issue whose
# label a human removed is invisible to it — and therefore to the sweep intersections in
# auto-update.yml, which close issues for games that are now current or no longer exist. `open-or-edit`
# still finds such an issue (`matching` retries without the label), so it is never duplicated, and the
# per-game path in pin-issues.yml still closes it on the next push that touches the game. Dropping the
# label prefilter here would turn one API call into a full unpaginated scan of every open issue on every
# sweep, which is the trade this comment records rather than makes silently.
list_open() {
  open_pin_issues "&labels=$LABEL" \
    | jq -r '.[] | .body // "" | capture("<!-- propnix-pin: game=(?<g>[^ ]+) ") | .g' \
    | sort -u
}

# The `target=` recorded in an existing issue's marker, so we can tell whether upstream moved again.
existing_target() {
  local num=$1
  gh issue view "$num" --json body --jq '.body' \
    | sed -n 's/.*<!-- propnix-pin: game=[^ ]* target=\(.*\) -->.*/\1/p' | head -1
}

# A stable identity for "which upstream version we are pointing at": every change's new id, sorted.
#
# A check that ended BLOCKED resolved no ids at all, so it falls back to the literal `blocked`. That is
# what keeps a game blocked week after week reporting `unchanged` (no notification spam) while still
# producing an `edited` the moment it gains a real target.
target_of() {
  local t
  t=$(jq -r '[(.changes // [])[].to] | unique | join(",")' "$1")
  printf '%s' "${t:-blocked}"
}

# Indent a block by four spaces: a markdown code block that CANNOT be broken out of. Fencing it with
# backticks could be, by a detail string that happens to contain ``` — and the tool's messages quote
# upstream text. Carriage returns become newlines FIRST, so every line really is indented: a renderer
# that treats a lone CR as a break would otherwise let the text after it escape the block.
indent4() { tr '\r' '\n' | sed 's/^/    /'; }

render_body() {
  local game=$1 json=$2 target=$3
  local newest changes
  newest=$(jq -r '[(.changes // [])[].version // empty] | first // ""' "$json")
  changes=$(jq -r '(.changes // []) | length' "$json")

  printf '%s%s target=%s -->\n\n' "$MARKER_PREFIX" "$game" "$target"
  printf 'The pin for **%s** has fallen behind upstream' "$game"
  [ -n "$newest" ] && printf ' (newest upstream version: **%s**)' "$newest"
  printf '.\n\n'
  printf 'The weekly job could not refresh it automatically. Anyone who owns it can produce the new pin in\n'
  printf 'a couple of commands; **no disk space for the game is needed**, because the hash is computed by\n'
  printf 'streaming.\n\n'
  # The tool's own message, verbatim — an expired credential and an unowned title are different problems
  # and guessing between them wastes the reader's time.
  local detail=${PIN_DETAIL:-}
  [ -n "$detail" ] || detail=$(jq -r '.detail // ""' "$json")
  if [ -n "$detail" ]; then
    printf 'What the updater reported:\n\n'
    printf '%s\n' "$detail" | indent4
    printf '\n'
  fi

  if [ "$changes" != "0" ]; then
    printf '### What changed upstream\n\n'
    printf '| pin | field | from | to | version |\n|---|---|---|---|---|\n'
    jq -r '.changes[] | "| `\(.where)` | `\(.key)` | `\(.from)` | `\(.to)` | \(.version // "—") |"' "$json"
    printf '\n'
  else
    # A BLOCKED check resolved nothing, so there is no before/after to tabulate — the explanation above
    # is the whole story. Rendering an empty table would read as "nothing changed", which is the
    # opposite of the truth.
    printf '### What changed upstream\n\n'
    printf 'Upstream could not be resolved at all, so there is nothing to tabulate — see the message\n'
    printf 'above. The instructions below still apply once the underlying problem is dealt with.\n\n'
  fi

  cat <<EOF
### How to update it

\`\`\`sh
cd /path/to/propnix          # or: git clone https://github.com/${GH_REPO:-OWNER/REPO}.git
git switch -c update-${game}
propnix pin ${game}          # rewrites pkgs/games/${game}/versions.json in place
\`\`\`

First time only, if you have no credential stored for this store yet:

\`\`\`sh
propnix cred add gog        # or: propnix cred add steam
\`\`\`

That resolves the newest build on the release branch this game is already pinned to, streams the payload
to recompute every hash, and rewrites only the values that changed. It is **all-or-nothing**: the base
game and every DLC move together, or nothing is written — moving a base game without its DLC is exactly
the mismatch that breaks at runtime.

Sanity-check and open a PR:

\`\`\`sh
git diff                        # buildId/manifestId, version, outputHash (+ depsBuildId on some GOG titles)
nix eval .#${game}.drvPath      # cheap: catches a malformed pin without downloading anything
git commit -am 'pkgs/games/${game}: update pin'
gh pr create --fill
\`\`\`

<details><summary>If something looks wrong</summary>

\`propnix pin ${game} --recompute\` keeps the currently pinned version and recomputes only its
\`outputHash\` — use it when you suspect the recorded hash rather than the version.
\`propnix pin ${game} --check\` reports what upstream has, and needs no credential at all.

</details>

---
*Opened automatically. This issue is edited in place when upstream moves again, and closed once the pin
catches up. It is never reopened — a later regression gets a fresh issue.*
EOF
}

cmd_open_or_edit() {
  local game=${1:?game} json=${2:?check.json}
  [ -s "$json" ] || die "$json is empty"
  if [ "$(jq -r '.upToDate' "$json")" = "true" ]; then
    die "$game is up to date; nothing to open an issue about"
  fi
  local target body num
  target=$(target_of "$json")
  ensure_label
  num=$(find_open "$game")
  body="$work/body.md"
  render_body "$game" "$json" "$target" > "$body"

  if [ -z "$num" ]; then
    gh issue create \
      --title "$game: pin is behind upstream" \
      --body-file "$body" \
      --label "$LABEL" >&2
    echo "opened"
    return
  fi
  if [ "$(existing_target "$num")" = "$target" ]; then
    # Same upstream target as last time. Touching the issue would only generate notifications.
    echo "unchanged"
    return
  fi
  gh issue edit "$num" --body-file "$body" >&2
  gh issue comment "$num" --body "Upstream moved again; the details above now point at \`$target\`." >&2
  echo "edited"
}

# close-if-open <game> [reached-version] [extra-note] [flavor]
#
# `flavor` says WHY it is resolved, because "now at the newest upstream version" is false for a
# version-HELD game (pin-issues.yml closes those too, and they are at a pinned version on purpose):
#   newest  (default) the pin caught up with upstream
#   held    the pin reached the version its `pin.version` policy names
#   gone    the game no longer exists — pass an empty version and let the note explain
cmd_close_if_open() {
  local game=${1:?game} reached=${2:-} note=${3:-} flavor=${4:-newest}
  local num
  num=$(find_open "$game")
  if [ -z "$num" ]; then
    echo "none"
    return
  fi
  local msg
  case "$flavor" in
    held) msg="\`$game\` is now at its pinned version" ;;
    gone) msg="\`$game\` is no longer tracked" ;;
    *)    msg="\`$game\` is now pinned to the newest upstream version" ;;
  esac
  [ -n "$reached" ] && msg="$msg (**$reached**)"
  msg="$msg, so this is resolved."
  [ -n "$note" ] && msg="$msg

$note"
  msg="$msg

If it falls behind again a **new** issue will be opened — this one is not reopened, because the next lag
is a different event from this one."
  gh issue close "$num" --reason completed --comment "$msg" >&2
  echo "closed"
}

case "${1:-}" in
  open-or-edit) shift; cmd_open_or_edit "$@" ;;
  close-if-open) shift; cmd_close_if_open "$@" ;;
  # Print the issue body without touching GitHub — for previewing and for testing this script.
  render) shift; render_body "${1:?game}" "${2:?check.json}" "$(target_of "${2}")" ;;
  list-open) list_open ;;
  *) die "usage: $0 {open-or-edit <game> <check.json>|close-if-open <game> [version] [note] [newest|held|gone]|render <game> <check.json>|list-open}" ;;
esac
