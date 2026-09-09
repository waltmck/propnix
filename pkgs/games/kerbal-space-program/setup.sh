# Kerbal Space Program display setup — run by propnix-launcher (the `setupScript` tuning field) in the
# OUTER phase, BEFORE wine. It maintains the three DISPLAY keys in KSP's own `settings.cfg` so the game
# starts FULLSCREEN at the compositor's real mode. Failure aborts the launch (the mkSetupScript wrapper
# supplies `set -euo pipefail`).
#
# WHY settings.cfg AND NOT `presets.unity.fullscreen`. KSP is Unity 2019.4.18f1 and its UnityPlayer.dll
# does carry the pref the preset writes (`Screenmanager Fullscreen mode`, alongside `Screenmanager
# Resolution {Width,Height}` / `Resolution Use Native` — checked with `strings`, so the preset's
# `…_h3630240806` value name would be a LIVE key here, unlike cities-skylines where it is the wrong one).
# It would still be inert: KSP does not leave the screen mode to the engine. Its own GameSettings layer
# owns `SCREEN_RESOLUTION_WIDTH` / `SCREEN_RESOLUTION_HEIGHT` / `FULLSCREEN` in settings.cfg and re-applies
# them over whatever Unity started with — the same reason the preset's own header gives for setting a
# persisted pref rather than passing `-screen-fullscreen`, one level further up. So the game's file is the
# only lever that sticks, and it is also the file the in-game Settings screen writes.
#
# WHY EVERY LAUNCH. Shipped default is a 1280x720 WINDOW (KSP writes settings.cfg itself on first run —
# the GOG payload contains no settings.cfg at all), and the in-game Settings screen can put it back. Same
# discipline as don't-starve's `[graphics] fullscreen`, homeworld-rm's `w`/`h`/`fullscreen` and skyrim-se's
# `iSize`: the compositor's mode is the source of truth, asserted on every launch so it also self-heals
# across a monitor or resolution change. `.apply { setupScript = null; }` is the revert if a user would
# rather drive the display from the in-game menu (top-level, not `wine.setupScript` — see default.nix).
#
# WHERE THE FILE LIVES. `$PROPNIX_STATE/gamedir/settings.cfg` — that is the UPPER of the persistent
# game-dir overlay in wine-tuning.nix, i.e. the exact host path the game's own writes to
# `C:\game\settings.cfg` land in. No extra mount row is needed, and no seeding race exists: the overlay
# row's `createIfNotExist` makes the upper during mount-table resolution, which the launcher runs BEFORE
# this script. If that row ever stops being an overlay rooted at $PROPNIX_STATE/gamedir, this path moves
# with it.
#
# FILE FORMAT. KSP's settings.cfg is a ConfigNode, not an INI (so no ini-lib.sh): CRLF, `//` comments, a
# flat run of `KEY = value` at the top, then nested `NAME { … }` blocks (INPUT_DEVICES, the key bindings,
# …) that reuse short names. The editor below therefore only ever rewrites an assignment at BRACE DEPTH 0,
# so a same-named key inside a binding block can never be hit.
#
# Env provided by the launcher:
#   PROPNIX_STATE                 — the app state dir; the game-dir overlay's upper lives here
#   PROPNIX_WIDTH, PROPNIX_HEIGHT — the compositor's primary-output mode, physical px (may be UNSET if the
#                                   launcher could not read the display)

cfg="$PROPNIX_STATE/gamedir/settings.cfg"
mkdir -p "$(dirname "$cfg")"

# cfg_set FILE KEY VALUE — replace the depth-0 `KEY = …` assignment in place, or append one if absent.
# CRLF in and out, to match what KSP writes.
cfg_set() {
    local f="$1" key="$2" val="$3" tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v val="$val" '
    BEGIN { ORS = "\r\n"; depth = 0; done = 0 }
    { sub(/\r$/, "") }                       # normalize CRLF: strip CR, ORS puts it back
    {
      line = $0
      if (!done && depth == 0 && line !~ /^[ \t]*\/\// && index(line, "=")) {
        k = line; sub(/=.*/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
        if (k == key) { print key " = " val; done = 1; next }
      }
      # track nesting AFTER the match so a `{`/`}` line is never itself an assignment
      depth += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
      print
    }
    END { if (!done) print key " = " val }
  ' "$f" > "$tmp"
    mv "$tmp" "$f"
}

# Fresh state dir — the game has not written its settings.cfg yet (it does that AFTER wine, with
# fullscreen OFF), so seed the keys we care about and let KSP merge in every other default when it
# rewrites the file. Same TIMING argument as don't-starve's setup.sh; without it the FIRST launch would
# always be a 1280x720 window.
#
# SETTINGS_FILE_VERSION IS PART OF THE SEED, and that is MEASURED rather than tidiness. A seed carrying
# only the three display keys is DISCARDED: KSP's settings loader treats a file with no (or a
# non-matching) SETTINGS_FILE_VERSION as stale, falls back to its built-in defaults and immediately
# rewrites the whole file — verified on a fresh state dir, where a 4-line seed of FULLSCREEN=True /
# 3840x2160 came back as the full 2360-line file at KSP's own `1280x720, FULLSCREEN = False`. With the
# version line present the loader accepts the file and keeps what it reads.
#
# 1.3.0 is the value THIS PINNED BUILD writes (KSP 1.12.5.03190; it is the settings-FORMAT version, not
# the game version, and is stable across KSP 1.12.x). It is only ever used on a fresh state dir, and the
# failure mode if a payload bump ever changes it is the benign one this branch exists to avoid: KSP
# regenerates its defaults and the FIRST launch is windowed, after which the cfg_set path above takes
# over. So a stale value costs one windowed launch, never a broken settings file.
if [ ! -e "$cfg" ]; then
  {
    printf '// Seeded by propnix; KSP fills in the rest on first write.\r\n'
    printf 'SETTINGS_FILE_VERSION = 1.3.0\r\n'
  } > "$cfg"
fi

cfg_set "$cfg" FULLSCREEN True

# No display facts → leave the resolution alone (better KSP's own default, or a stale-but-valid mode, than
# a half-written one that pins the game to nothing). Same call skyrim-se's and homeworld-rm's setup.sh make.
if [ -n "${PROPNIX_WIDTH:-}" ] && [ -n "${PROPNIX_HEIGHT:-}" ]; then
  cfg_set "$cfg" SCREEN_RESOLUTION_WIDTH "$PROPNIX_WIDTH"
  cfg_set "$cfg" SCREEN_RESOLUTION_HEIGHT "$PROPNIX_HEIGHT"
fi
