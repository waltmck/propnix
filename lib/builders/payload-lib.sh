# builders/payload-lib.sh — payload-tree lookup for setup scripts (prepended UNCONDITIONALLY by
# mkSetupScript, unlike the opt-in ini-lib.sh). It is the shell half of the `PROPNIX_PAYLOADS` contract:
# the launcher hands every setup script the FULL list of game-content trees, and these three functions are
# how a script reads a shipped asset without knowing which tree it landed in.
#
# WHY IT EXISTS. `PROPNIX_PAYLOAD` is the HEAD tree only, and the head is not chosen for a setup script's
# benefit — it is the launch cwd / icon+exe source (wine's `drive_c/game` root; `icon.auto` runs wrestool on
# `${head}/${exe}`, so a head without the exe is a hard build failure). A multi-depot game therefore routinely
# ships the asset a setup script wants in a NON-head depot: Skyrim SE's Low/Medium/High/Ultra.ini quality
# presets live in Steam depot 489832 while the exe (and thus the head) is 489833, so `$PROPNIX_PAYLOAD/High.ini`
# simply does not exist on that arm — a silent quality regression that only surfaces as the setup script's own
# "preset not found" abort. Searching the whole list fixes it for every game at once, with no per-game
# knowledge of the depot layout.
#
# ORDER IS MOUNT PRIORITY. `PROPNIX_PAYLOADS` is ':'-separated, highest priority FIRST — the same order the
# launcher unions those trees into the game dir. So the FIRST hit is the file the game itself will open, which
# is the only answer a setup script can seed a config from without contradicting the running game. (':' is
# safe as the separator for the same reason overlayfs `lowerdir` and `LD_LIBRARY_PATH` use it: a Nix store
# path cannot contain one.)
#
# BACKWARDS COMPATIBLE: `PROPNIX_PAYLOAD` is untouched and still points at the head, so every setup script
# written against it keeps working verbatim; these helpers fall back to it when `PROPNIX_PAYLOADS` is unset
# (a config baked before the field existed, or a hand-run script).

# payload_trees — print the payload trees, one per line, highest mount priority first.
payload_trees() {
    local list="${PROPNIX_PAYLOADS:-${PROPNIX_PAYLOAD:-}}" t
    local -a trees=()
    [ -n "$list" ] || return 0
    # `read -ra` splits on IFS with NO pathname expansion — unlike `for t in $list`, which would glob a tree
    # whose store-path NAME contains `?` (a legal store-name character).
    IFS=':' read -ra trees <<<"$list"
    for t in "${trees[@]}"; do
        [ -n "$t" ] && printf '%s\n' "$t"
    done
    return 0
}

# payload_find REL — print the absolute path of the game-dir-relative REL in the HIGHEST-PRIORITY tree that
# has it; return 1 (silently) when no tree does. For an OPTIONAL asset: `if p="$(payload_find x)"; then …`.
payload_find() {
    local rel="$1" t
    while IFS= read -r t; do
        [ -e "$t/$rel" ] || continue
        printf '%s\n' "$t/$rel"
        return 0
    done < <(payload_trees)
    return 1
}

# payload_require REL — payload_find, but a miss is a PACKAGING BUG: diagnose it on stderr (naming every
# tree searched, which is what makes a wrong/incomplete depot pin obvious) and return 1. Under the wrapper's
# `set -euo pipefail` the intended call site — `preset="$(payload_require "$cap.ini")"` — then aborts the
# script, and a non-zero setup script aborts the launch. NB assign to a PRE-DECLARED variable: `local
# p="$(payload_require …)"` would swallow the failure in `local`'s own exit status.
payload_require() {
    local rel="$1" hit
    if hit="$(payload_find "$rel")"; then
        printf '%s\n' "$hit"
        return 0
    fi
    {
        printf 'propnix setup: %s is in none of this build'"'"'s payload trees:\n' "$rel"
        payload_trees | sed 's/^/  /'
    } >&2
    return 1
}
