# Factorio prefix setup — run by propnix-launcher (the `setupScript` tuning field) in the OUTER phase, BEFORE
# wine. Ensures `[other] check-updates=false` in Factorio's config.ini so the on-launch update check is OFF by
# default. This is not merely a preference: the game payload is a READ-ONLY Nix store path, so Factorio's
# updater can never apply an update anyway — with it enabled, launching pops an "automatic updates / log in to
# download" dialog (and makes a network request) against an immutable install. We SEED a valid config.ini with
# the key already off when none exists yet (covers the first launch on a fresh save dir), and otherwise edit
# the key in place (idempotent), preserving all other user config. See TIMING below.
#
# Factorio is cross-platform and keeps this setting in config.ini (NOT the Windows registry — a `userReg`
# entry would have no effect). config.ini lives at %APPDATA%\Factorio\config\config.ini (config-path.cfg:
# `config-path=__PATH__system-write-data__/config`, use-system-read-write-data-directories=true), and the
# save mount binds %APPDATA%\Factorio → $PROPNIX_SAVE_DIR/$PROPNIX_APPID (see tuning.nix), so on the host it
# is $PROPNIX_SAVE_DIR/$PROPNIX_APPID/config/config.ini. Failure aborts the launch (the wrapper in default.nix
# supplies `set -euo pipefail`).
#
# TIMING: the setupScript runs before wine, so on a truly fresh save dir config.ini does not exist yet
# (Factorio writes it on first launch, AFTER wine). If we did nothing here, that FIRST launch would run with
# Factorio's default `check-updates=true` and pop the "automatic updates / log in to download" dialog — the
# exact prompt this default exists to prevent. So we SEED config.ini when it is absent.
#
# The seed must be STRUCTURALLY VALID or Factorio rejects it with a "configuration file has invalid contents —
# reset it?" dialog. A bare `[other]` section is NOT enough (VERIFIED: rejected + logged "Resetting config").
# The minimum Factorio accepts is the `[path]` section with its runtime-magic read/write tokens (how it
# resolves its data dirs — see config-path.cfg `use-system-read-write-data-directories=true`) plus our
# `[other] check-updates=false`. VERIFIED on a fresh save dir: this seed is accepted (no reset dialog), the
# game reaches "Factorio initialised", and NO update/TLS check runs — so the prompt is gone from launch #1.
# Factorio fills in every remaining default and keeps check-updates=false when it later rewrites the file (on
# clean exit), after which the `ini_set` branch below maintains it. Written CRLF to match Factorio's format.
# The `; version=N` line is a comment Factorio regenerates — not a hard pin (a version bump just migrates).
#
# Env provided by the launcher:
#   PROPNIX_SAVE_DIR, PROPNIX_APPID  — host save dir = $PROPNIX_SAVE_DIR/$PROPNIX_APPID

cfg="$PROPNIX_SAVE_DIR/$PROPNIX_APPID/config/config.ini"
mkdir -p "$(dirname "$cfg")"
if [ ! -f "$cfg" ]; then
  # Fresh save dir — seed a minimal VALID config with the update check already off (see TIMING above).
  printf '; version=13\r\n[path]\r\nread-data=__PATH__system-read-data__\r\nwrite-data=__PATH__system-write-data__\r\n\r\n[other]\r\ncheck-updates=false\r\n' > "$cfg"
  exit 0
fi

# ini_set FILE SECTION KEY VALUE — set [SECTION] KEY=VALUE, preserving every other line: replace the key's
# value in place if present (matching an ACTIVE, non-commented line), add the key within the section if the
# section exists, or append the whole section at EOF if it doesn't. Section + key match case-insensitively
# (INI convention). A commented default (e.g. `; check-updates=true`) is left in place and the active key is
# added at the end of the section, so Factorio's shipped comment block stays intact.
#
# Factorio writes config.ini with CRLF (DOS) line endings, so the first rule strips a trailing CR before any
# matching (otherwise a header like `[other]\r` never matches `[other]`), and ORS re-emits CRLF so the file
# stays in Factorio's own format (mixed endings would be ugly; a fresh minimal seed is CRLF-consistent too).
ini_set() {
  local f="$1" sec="$2" key="$3" val="$4" tmp
  tmp="$(mktemp)"
  awk -v sec="$sec" -v key="$key" -v val="$val" '
    function flush() { if (insec && !done) { print key "=" val; done = 1 } }
    BEGIN { ORS = "\r\n"; insec = 0; done = 0; seen = 0 }
    { sub(/\r$/, "") }   # normalize: Factorio writes CRLF — strip CR before matching, ORS puts it back
    /^[ \t]*\[/ {
      flush()
      h = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", h)
      insec = (tolower(h) == tolower(sec)); if (insec) seen = 1
      print; next
    }
    {
      if (insec && !done) {
        line = $0
        # only match an ACTIVE (non-comment) assignment for this key
        if (line !~ /^[ \t]*;/) {
          k = line; sub(/=.*/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
          if (tolower(k) == tolower(key)) { print key "=" val; done = 1; next }
        }
      }
      print
    }
    END { flush(); if (!seen) { print ""; print "[" sec "]"; print key "=" val } }
  ' "$f" > "$tmp"
  mv "$tmp" "$f"
}

ini_set "$cfg" other "check-updates" "false"
