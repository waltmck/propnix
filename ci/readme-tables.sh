#!/usr/bin/env bash
# ci/readme-tables.sh [--write] — hold the README's two supported-games tables to the RESOLVER.
#
# Those tables are the front page's answer to "will this run on my machine, and which store do I need",
# and every cell in them is already computed by code: Table 1 is (runnable platforms × the resolved
# default) per host, Table 2 is the pinned `fetchInfo` matrix. Written by hand they rot silently and
# invisibly — a reader cannot tell a stale cell from a true one, and the repo carried both failure modes
# at once: five packaged games missing outright (cities-skylines, civilization-6, repo, space-engineers,
# victoria-3) and two rows claiming an `i386-windows` default that no longer had a pin behind it.
#
#   (default)  regenerate both tables and diff them against README.md; exit 1 on any difference.
#   --write    rewrite README.md in place. This is the intended way to add a game to the tables.
#
# HAND-WRITTEN NOTES SURVIVE. A cell the resolver reduces to "—" may carry a human explanation of WHY
# ("— *(needs a 32-bit GL stack)*"), which no generator can reconstruct; when the generated cell is bare
# "—" and the existing one starts with "—", the existing text is kept.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

write=0
[ "${1:-}" = "--write" ] && write=1

die() {
  echo "readme-tables: $*" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ── ground truth, straight out of the scope ─────────────────────────────────────────────────────────
# Pinned pairs only: `fetchInfo` is GENERATED over every platform, so an unpinned slot is present but
# null — reading its attribute names instead would report every game as available everywhere.
cat >"$tmp/truth.nix" <<'EOF'
let
  # The repo root comes in through the environment: this expression is evaluated from a temp file,
  # where a relative `./.` would resolve next to the temp file rather than the checkout.
  root = builtins.getEnv "PROPNIX_ROOT";
  flake = builtins.getFlake root;
  nixpkgs = flake.inputs.nixpkgs;
  lib = nixpkgs.lib;
  scopeFor =
    system:
    import (root + "/lib") {
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowBroken = true;
        };
      };
      config = { };
    };
  per =
    system:
    let
      s = scopeFor system;
    in
    lib.genAttrs (builtins.attrNames s.games) (
      n:
      let
        g = s.${n};
        pinned = f: builtins.attrNames (lib.filterAttrs (_: pin: pin != null) g.config.fetchInfo.${f});
        plats = lib.unique (lib.concatMap pinned (builtins.attrNames g.config.fetchInfo));
      in
      {
        default = g.config.emulatedPlatform;
        broken = g.meta.broken;
        runnable = builtins.filter (p: s.strategy.runnable p system) plats;
        byFetcher = lib.genAttrs (builtins.attrNames g.config.fetchInfo) pinned;
      }
    );
in
{
  aarch64-linux = per "aarch64-linux";
  x86_64-linux = per "x86_64-linux";
}
EOF
PROPNIX_ROOT="$PWD" nix eval --impure --json -f "$tmp/truth.nix" >"$tmp/truth.json" 2>"$tmp/err" ||
  die "could not evaluate the scope:
$(cat "$tmp/err")"

# ── the two tables, exactly as the README spells them ───────────────────────────────────────────────
# Table 1 cell: the host's runnable platforms, DEFAULT first and bold, the rest alphabetical; a game
# refused on that host (meta.broken) collapses to "—". Table 2 cell: that fetcher's pinned platforms.
# The root object is passed to each def EXPLICITLY: inside `[ $games[] | … ]` the implicit `.` is the
# game name, so a def reaching for `.[$h]` would try to index a string.
jq -r --arg h1 aarch64-linux --arg h2 x86_64-linux '
  def cell($D; $h; $g): $D[$h][$g] as $e
    | if $e.broken then "—"
      else $e.default as $d
        | ([$e.runnable[] | select(. != $d)] | sort) as $rest
        | "**\($d)**" + (if ($rest | length) > 0 then ", " + ($rest | join(", ")) else "" end)
      end;
  . as $D | ($D[$h1] | keys)[]
  | "| `\(.)` | \(cell($D; $h1; .)) | \(cell($D; $h2; .)) |"
' "$tmp/truth.json" >"$tmp/t1" || die "generating Table 1 failed"

jq -r --arg h1 aarch64-linux '
  def cell($D; $g; $f): ($D[$ARGS.named.h1][$g].byFetcher[$f] // []) | sort
    | if length > 0 then join(", ") else "—" end;
  . as $D | ($D[$h1] | keys)[]
  | "| `\(.)` | \(cell($D; .; "gog")) | \(cell($D; .; "steam")) |"
' "$tmp/truth.json" >"$tmp/t2" || die "generating Table 2 failed"

[ -s "$tmp/t1" ] && [ -s "$tmp/t2" ] || die "generated an empty table — refusing to compare or write"

python3 - "$tmp/t1" "$tmp/t2" "$write" <<'PY'
import re, sys

t1 = open(sys.argv[1]).read().rstrip("\n").split("\n")
t2 = open(sys.argv[2]).read().rstrip("\n").split("\n")
write = sys.argv[3] == "1"
lines = open("README.md").read().split("\n")

def span(after):
    """The contiguous run of `| `game` |` rows following the given heading."""
    h = next(i for i, l in enumerate(lines) if l.startswith(after))
    s = next(i for i, l in enumerate(lines[h:], h) if re.match(r"^\| `[a-z0-9-]+` \|", l))
    e = s
    while e < len(lines) and re.match(r"^\| `[a-z0-9-]+` \|", lines[e]):
        e += 1
    return s, e

def keep_notes(gen, cur):
    """A generated bare '—' keeps whatever human annotation the existing cell carried."""
    by_game = {}
    for row in cur:
        by_game[row.split("`")[1]] = row
    out = []
    for row in gen:
        game = row.split("`")[1]
        old = by_game.get(game)
        if old:
            g_cells = row.split(" | ")
            o_cells = old.split(" | ")
            if len(g_cells) == len(o_cells):
                for i, c in enumerate(g_cells):
                    if c.strip() in ("—", "— |") and o_cells[i].lstrip().startswith("—"):
                        g_cells[i] = o_cells[i]
                row = " | ".join(g_cells)
        out.append(row)
    return out

s1, e1 = span("### Table 1")
s2, e2 = span("### Table 2")
new1 = keep_notes(t1, lines[s1:e1])
new2 = keep_notes(t2, lines[s2:e2])

if lines[s1:e1] == new1 and lines[s2:e2] == new2:
    print(f"   OK — both README tables match the resolver ({len(t1)} games)")
    sys.exit(0)

if write:
    # One pass over the ORIGINAL list, so the second span's indices stay valid however much the
    # first table grew or shrank.
    out = lines[:s1] + new1 + lines[e1:s2] + new2 + lines[e2:]
    open("README.md", "w").write("\n".join(out))
    print(f"   README.md rewritten ({len(t1)} games)")
    sys.exit(0)

import difflib
print("== README supported-games tables are STALE ==", file=sys.stderr)
for name, cur, new in (("Table 1", lines[s1:e1], new1), ("Table 2", lines[s2:e2], new2)):
    d = list(difflib.unified_diff(cur, new, fromfile=f"README {name}", tofile=f"resolver {name}", lineterm=""))
    if d:
        print("\n".join(d), file=sys.stderr)
print("\nRun `ci/readme-tables.sh --write` to regenerate them.", file=sys.stderr)
sys.exit(1)
PY
