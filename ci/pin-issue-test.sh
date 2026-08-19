#!/usr/bin/env bash
# ci/pin-issue-test.sh — exercise every transition of the pin-issue lifecycle against a STUB `gh`.
#
# The GitHub interactions are the one part of the automation that cannot be tried locally for real, so they
# get tested against a fake instead. The stub records every invocation and serves canned responses, which
# lets us assert the things that actually matter and are otherwise invisible until they misfire in
# production:
#
#   * a game with no open issue gets exactly one CREATE;
#   * a game whose upstream target is unchanged gets NO writes at all (otherwise the weekly run would
#     notify everyone about a months-old lag every Monday);
#   * a game whose target moved gets an EDIT, not a second issue;
#   * a BLOCKED check — one that resolved no upstream target at all — still opens an issue, still says
#     why, and still settles into `unchanged` week after week instead of notifying;
#   * closing is a close with `--reason completed`, and closing a game with no open issue is a no-op;
#   * `gh issue reopen` is NEVER invoked, and the lookup NEVER goes through the search index.
#
# Usage: ci/pin-issue-test.sh      (needs bash, jq; no network, no credentials, no gh)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' INT TERM EXIT
log="$work/calls"
: > "$log"

# ── the stub ────────────────────────────────────────────────────────────────────────────────────────
# $work/open.json is the canned "open issues" list; $work/body is the canned body of issue 42.
cat > "$work/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$LOGFILE"
case "$1" in
  api)
    # Every lookup must come through here (the REST list resource), never `gh issue list`.
    # The label-less fallback query gets its own fixture so the two paths are distinguishable.
    if [[ "$*" == *"labels="* ]]; then cat "$WORKDIR/open.json"
    elif [ -f "$WORKDIR/open-all.json" ]; then cat "$WORKDIR/open-all.json"
    else cat "$WORKDIR/open.json"; fi ;;
  label) exit 0 ;;
  issue)
    case "${2:-}" in
      view)   cat "$WORKDIR/body" ;;
      create) echo "https://github.test/o/r/issues/99" ;;
      edit|comment|close) exit 0 ;;
      list)   echo "STUB-FAIL: pin-issue.sh must not use 'gh issue list' (it routes through the search index)" >&2; exit 1 ;;
      *)      exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$work/gh"
export PATH="$work:$PATH" LOGFILE="$log" WORKDIR="$work" GH_REPO="o/r"

cat > "$work/check.json" <<'EOF'
{ "game": "factorio", "upToDate": false, "blocked": false, "detail": null,
  "frozen": false, "pinnedTo": null, "policyReason": null,
  "changes": [ { "where": "fetchInfo.gog.x86_64-windows[0]", "pname": "factorio-win",
                 "key": "buildId", "from": "111", "to": "222", "version": "2.1.15" } ] }
EOF

# What `propnix pin <game> --check` prints just before exiting 4: no upstream target could be resolved,
# so `.changes` is empty and the story lives in `.detail`.
cat > "$work/blocked.json" <<'EOF'
{ "game": "factorio", "upToDate": false, "blocked": true,
  "detail": "factorio: upstream could not be resolved: refusing to hash: build 599 is no longer listed for 1238653230/windows (aged out or delisted)",
  "frozen": false, "pinnedTo": null, "policyReason": null, "changes": [] }
EOF

fail() { printf 'pin-issue-test: FAIL — %s\n' "$*" >&2; exit 1; }
calls() { grep -c "$1" "$log" || true; }
reset() { : > "$log"; }

# ── 1. no open issue -> exactly one create ──────────────────────────────────────────────────────────
echo '[]' > "$work/open.json"; : > "$work/body"; reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/check.json" 2>/dev/null)
[ "$out" = opened ] || fail "expected 'opened', got '$out'"
[ "$(calls 'issue create')" = 1 ] || fail "expected exactly one 'issue create'"
[ "$(calls 'issue edit')" = 0 ] || fail "must not edit when creating"
echo "  ok  1. no open issue -> create"

# ── 2. open issue, SAME target -> no writes at all ──────────────────────────────────────────────────
cat > "$work/open.json" <<'EOF'
[{"number":42,"body":"<!-- propnix-pin: game=factorio target=222 -->\nold body"}]
EOF
printf '<!-- propnix-pin: game=factorio target=222 -->\nold body\n' > "$work/body"; reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/check.json" 2>/dev/null)
[ "$out" = unchanged ] || fail "expected 'unchanged', got '$out'"
[ "$(calls 'issue create')" = 0 ] || fail "must not create a duplicate"
[ "$(calls 'issue edit')" = 0 ] || fail "must not rewrite the body when the target is unchanged"
[ "$(calls 'issue comment')" = 0 ] || fail "must not comment when nothing changed"
echo "  ok  2. same target -> no writes (no weekly notification spam)"

# ── 3. open issue, target MOVED -> edit, never a second issue ───────────────────────────────────────
printf '<!-- propnix-pin: game=factorio target=111 -->\nold body\n' > "$work/body"
cat > "$work/open.json" <<'EOF'
[{"number":42,"body":"<!-- propnix-pin: game=factorio target=111 -->\nold body"}]
EOF
reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/check.json" 2>/dev/null)
[ "$out" = edited ] || fail "expected 'edited', got '$out'"
[ "$(calls 'issue edit 42')" = 1 ] || fail "expected an edit of issue 42"
[ "$(calls 'issue create')" = 0 ] || fail "must NOT open a second issue when one is already open"
echo "  ok  3. target moved -> edit in place"

# ── 4. close with no open issue -> no-op ────────────────────────────────────────────────────────────
echo '[]' > "$work/open.json"; reset
out=$("$here/pin-issue.sh" close-if-open factorio 2>/dev/null)
[ "$out" = none ] || fail "expected 'none', got '$out'"
[ "$(calls 'issue close')" = 0 ] || fail "must not close anything when nothing is open"
echo "  ok  4. nothing open -> no-op"

# ── 5. close an open issue ──────────────────────────────────────────────────────────────────────────
cat > "$work/open.json" <<'EOF'
[{"number":42,"body":"<!-- propnix-pin: game=factorio target=222 -->\nb"}]
EOF
reset
out=$("$here/pin-issue.sh" close-if-open factorio "2.1.15" "refreshed in #7" 2>/dev/null)
[ "$out" = closed ] || fail "expected 'closed', got '$out'"
grep -q 'issue close 42 --reason completed' "$log" || fail "close must pass --reason completed"
grep -q '2.1.15' "$log" || fail "the closing comment should name the version reached"
grep -q 'refreshed in #7' "$log" || fail "the extra note should reach the closing comment"
grep -q 'newest upstream version' "$log" || fail "the default flavor should say 'newest upstream version'"
echo "  ok  5. open issue -> closed, with the version and note"

# ── 6. a HELD game closes with a true sentence, not "newest upstream" ───────────────────────────────
reset
out=$("$here/pin-issue.sh" close-if-open factorio "gog=2.0.77" "" held 2>/dev/null)
[ "$out" = closed ] || fail "expected 'closed', got '$out'"
grep -q 'pinned version' "$log" || fail "a held game must close as 'at its pinned version'"
grep -q 'newest upstream version' "$log" \
  && fail "a version-held game is NOT at the newest upstream version; that claim is false"
echo "  ok  6. held game closes without claiming it is at the newest version"

# ── 7. list-open reports the games, and skips PRs and unrelated issues ──────────────────────────────
cat > "$work/open.json" <<'EOF'
[{"number":1,"body":"<!-- propnix-pin: game=factorio target=1 -->"},
 {"number":2,"body":"<!-- propnix-pin: game=no-mans-sky target=2 -->"},
 {"number":3,"body":"an unrelated issue"},
 {"number":4,"body":null},
 {"number":5,"body":"<!-- propnix-pin: game=x target=3 -->","pull_request":{"url":"u"}}]
EOF
got=$("$here/pin-issue.sh" list-open | tr '\n' ' ')
[ "$got" = "factorio no-mans-sky " ] || fail "list-open gave '$got'"
echo "  ok  7. list-open skips PRs, null bodies and unrelated issues"

# ── 8. a PAGINATED response (gh --paginate --slurp gives an array OF ARRAYS) is flattened ───────────
# Without the flatten branch every page after the first would be invisible, so a game whose issue landed
# on page 2 would get a duplicate opened every week.
cat > "$work/open.json" <<'EOF'
[[{"number":1,"body":"<!-- propnix-pin: game=factorio target=1 -->"}],
 [{"number":2,"body":"<!-- propnix-pin: game=no-mans-sky target=2 -->"},
  {"number":3,"body":"<!-- propnix-pin: game=stellaris target=3 -->","pull_request":{"url":"u"}}]]
EOF
got=$("$here/pin-issue.sh" list-open | tr '\n' ' ')
[ "$got" = "factorio no-mans-sky " ] || fail "paginated list-open gave '$got'"
# …and the lookup path sees page 2 too, so no duplicate is opened for a game whose issue is there.
printf '<!-- propnix-pin: game=no-mans-sky target=2 -->\n' > "$work/body"; reset
sed 's/factorio/no-mans-sky/g' "$work/check.json" > "$work/nms.json"
out=$("$here/pin-issue.sh" open-or-edit no-mans-sky "$work/nms.json" 2>/dev/null)
[ "$out" = edited ] || fail "expected the paginated lookup to find #2 and edit it, got '$out'"
[ "$(calls 'issue create')" = 0 ] || fail "a page-2 issue must not spawn a duplicate every week"
echo "  ok  8. paginated (array-of-arrays) responses are flattened"

# ── 9. the label was removed by hand -> found via the label-less fallback, no duplicate ─────────────
echo '[]' > "$work/open.json"
cat > "$work/open-all.json" <<'EOF'
[{"number":42,"body":"<!-- propnix-pin: game=factorio target=111 -->\nold body"}]
EOF
printf '<!-- propnix-pin: game=factorio target=111 -->\nold\n' > "$work/body"; reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/check.json" 2>/dev/null)
[ "$out" = edited ] || fail "expected the label-less fallback to find #42 and edit it, got '$out'"
[ "$(calls 'issue create')" = 0 ] || fail "a delabelled issue must not spawn a duplicate every week"
echo "  ok  9. label removed -> found anyway, no duplicate"

# ── 10. a plurality is collapsed onto the oldest, not left to persist ───────────────────────────────
cat > "$work/open.json" <<'EOF'
[{"number":77,"body":"<!-- propnix-pin: game=factorio target=111 -->"},
 {"number":42,"body":"<!-- propnix-pin: game=factorio target=111 -->"}]
EOF
rm -f "$work/open-all.json"; reset
out=$("$here/pin-issue.sh" close-if-open factorio "2.1.15" 2>/dev/null)
[ "$out" = closed ] || fail "expected 'closed', got '$out'"
grep -q 'issue close 77 --reason duplicate --duplicate-of 42' "$log" \
  || fail "the newer duplicate should be closed as a duplicate of the oldest; log: $(cat "$log")"
grep -q 'issue close 42 --reason completed' "$log" || fail "the oldest issue should be the one resolved"
echo "  ok  10. plurality collapsed onto the oldest"

# ── 11. a BLOCKED check still opens an issue, and says why ──────────────────────────────────────────
# The regression: a check that itself exits 4 used to produce an EMPTY check.json, on which this script
# died under `set -e` — taking the whole issues step, and every step after it, down with it.
echo '[]' > "$work/open.json"; : > "$work/body"; reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/blocked.json" 2>/dev/null)
[ "$out" = opened ] || fail "a blocked check must still open an issue, got '$out'"
body=$("$here/pin-issue.sh" render factorio "$work/blocked.json")
grep -q 'target=blocked' <<<"$body" || fail "a blocked check has no ids, so the marker target is 'blocked'"
grep -q 'aged out or delisted' <<<"$body" || fail "the body must carry the tool's own explanation"
grep -q '^| pin | field |' <<<"$body" && fail "there is nothing to tabulate for a blocked check"
grep -q 'could not be resolved at all' <<<"$body" || fail "the body must say WHY there is no table"
grep -q 'How to update it' <<<"$body" || fail "the how-to-fix instructions must still be there"
echo "  ok  11. blocked check -> opened, with the detail and no empty table"

# ── 12. …and stays 'unchanged' week after week rather than notifying ────────────────────────────────
cat > "$work/open.json" <<'EOF'
[{"number":42,"body":"<!-- propnix-pin: game=factorio target=blocked -->\nold body"}]
EOF
printf '<!-- propnix-pin: game=factorio target=blocked -->\nold body\n' > "$work/body"; reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/blocked.json" 2>/dev/null)
[ "$out" = unchanged ] || fail "a game blocked again next week must not notify, got '$out'"
[ "$(calls 'issue comment')" = 0 ] || fail "must not comment when it is blocked for the same reason"
echo "  ok  12. still blocked -> unchanged, no notification"

# ── 13. …and edits exactly when it later gains a real target ────────────────────────────────────────
reset
out=$("$here/pin-issue.sh" open-or-edit factorio "$work/check.json" 2>/dev/null)
[ "$out" = edited ] || fail "blocked -> real target must edit the existing issue, got '$out'"
[ "$(calls 'issue create')" = 0 ] || fail "must not open a second issue when the block clears"
[ "$(calls 'issue comment 42')" = 1 ] || fail "the reader should be told the target moved"
echo "  ok  13. block clears -> edited in place (blocked -> the real ids)"

# ── 14. a detail containing a markdown fence cannot break out of the body ───────────────────────────
# Fencing it with backticks could be closed by a detail that contains ``` — and the tool's messages
# quote upstream text. A 4-space indented block has no terminator to forge.
PIN_DETAIL=$'trouble:\n```\nnot a fence\n```\nmore' \
  "$here/pin-issue.sh" render factorio "$work/check.json" > "$work/fenced.md"
grep -q '^    not a fence$' "$work/fenced.md" || fail "the detail should be a 4-space indented block"
grep -q '^    ```$' "$work/fenced.md" \
  || fail "the detail's own backticks must be indented too, so they close nothing"
# Every bare fence in the body must belong to the how-to sections, never to the detail.
[ "$(grep -c '^```' "$work/fenced.md")" = "$(grep -c '^```' <("$here/pin-issue.sh" render factorio "$work/check.json"))" ] \
  || fail "the detail introduced a top-level markdown fence"
echo "  ok  14. a detail with backticks stays inside its block"

# ── 15. the update command no longer redirects over its own input ───────────────────────────────────
# `propnix pin <game> > .../versions.json` truncated the file the tool was about to READ.
body=$("$here/pin-issue.sh" render factorio "$work/check.json")
grep -q 'propnix pin factorio' <<<"$body" || fail "the body must show the update command"
grep -E 'propnix pin [a-z-]+ *>' <<<"$body" \
  && fail "the update command must not redirect over versions.json — the tool writes it in place"
echo "  ok  15. the documented update command writes in place"

# ── 16. structural invariants ───────────────────────────────────────────────────────────────────────
grep -q 'issue reopen' "$log" && fail "gh issue reopen was invoked"
# Only NON-COMMENT lines count: both banned strings appear in prose that explains why they are banned.
# `grep -n` prefixes each hit with "N:", so the comment filter has to allow for that prefix — matching
# on a bare ^# silently passes everything, which is exactly the bug this comment exists to prevent.
noncomment() { grep -n "$1" "$2" | grep -v ':[[:space:]]*#' || true; }
[ -z "$(noncomment 'issue reopen' "$here/pin-issue.sh")" ] \
  || fail "pin-issue.sh contains a reopen path: $(noncomment 'issue reopen' "$here/pin-issue.sh")"
[ -z "$(noncomment 'gh issue list' "$here/pin-issue.sh")" ] \
  || fail "pin-issue.sh uses 'gh issue list', which routes through the eventually-consistent search index"
grep -q 'state=open' "$here/pin-issue.sh" || fail "the lookup must constrain to state=open"
echo "  ok  16. no reopen path, no search-index lookup, state=open enforced"

echo "pin-issue-test: all 16 transitions OK"
