# Factorio prefix setup — run by propnix-launcher (the `setupScript` option) in the OUTER phase, BEFORE the
# game's view is assembled. It maintains Factorio's config.ini, which is where Factorio keeps settings that
# have no registry equivalent (it is cross-platform, so a `userReg` entry would have no effect):
#
#   1. `[other] cache-prototype-data=true`, `[graphics] cache-sprite-atlas=true`,
#      `[graphics] cache-sprite-atlas-count=1` — the startup-time caches. Factorio otherwise re-derives the
#      prototype data and rebuilds every sprite atlas on each launch; with these on it writes
#      `data-cache.dat` (~8 MB) and `atlas-cache.dat` (~1.4 GB with Space Age) into its write-data dir and
#      reuses them. Both keys ship commented-out and default to false, so this is opt-in per install.
#      MEASURED on the aarch64 build: both files appear during load and are written IN PLACE (no
#      `.tmp` + rename), which is what lets the cache dir be redirected by bind rather than by overlay.
#   2. `[other] check-updates=false` — so the on-launch update check never runs. This is not merely a
#      preference: the payload is a READ-ONLY Nix store path, so Factorio's updater can never apply an
#      update anyway — with it enabled, launching pops an "automatic updates / log in to download" dialog
#      and makes a network request against an immutable install. Only the GOG build HAS this option (the
#      string is absent from both Steam binaries — Wube compiles the updater out where Steam does the
#      updating), and setting it on a build that does not support it is harmless: VERIFIED on the Steam
#      aarch64 build, which reached "Factorio initialised" with the key present and preserved it in the
#      file rather than rejecting the config.
#
# config.ini lives at %APPDATA%\Factorio\config\config.ini on Windows and ~/.factorio/config/config.ini on
# Linux (config-path.cfg: `use-system-read-write-data-directories=true`), and the game's `saveBinds` row
# binds that dir to $PROPNIX_SAVE_DIR/$PROPNIX_APPID — so on the HOST it is the same path either way,
# whichever platform is selected. Failure aborts the launch (the mkSetupScript wrapper supplies
# `set -euo pipefail`).
#
# TIMING: this runs before the game, so on a truly fresh save dir config.ini does not exist yet (Factorio
# writes it on first launch). Doing nothing would leave that FIRST launch on the stock defaults — the
# update dialog, and a full atlas rebuild. So we SEED one.
#
# The seed must be STRUCTURALLY VALID or Factorio rejects it with a "configuration file has invalid
# contents — reset it?" dialog. A bare `[other]` section is NOT enough (VERIFIED: rejected + logged
# "Resetting config"). The minimum Factorio accepts is the `[path]` section with its runtime-magic
# read/write tokens (how it resolves its data dirs) plus our own keys. VERIFIED on a fresh save dir: this
# seed is accepted (no reset dialog), the game reaches "Factorio initialised", and no update/TLS check
# runs. Factorio fills in every remaining default and keeps our values when it later rewrites the file (on
# clean exit), after which the `ini_set` calls below maintain them. The `; version=N` line is a comment
# Factorio regenerates — not a hard pin (a version bump just migrates).
#
# Env provided by the launcher:
#   PROPNIX_SAVE_DIR, PROPNIX_APPID  — host save dir = $PROPNIX_SAVE_DIR/$PROPNIX_APPID

# `ini_set` comes from the shared ini-lib.sh (mkSetupScript withIniLib), tuned to Factorio's config.ini
# format: bare `key=value` assignments, and Factorio ships commented defaults (e.g. `; check-updates=true`)
# that must never be mistaken for the active assignment — INI_SKIP_COMMENTS adds the active key alongside,
# keeping the shipped comment block intact.
INI_SEP="="
INI_SKIP_COMMENTS=1

cfg="$PROPNIX_SAVE_DIR/$PROPNIX_APPID/config/config.ini"
mkdir -p "$(dirname "$cfg")"

if [ ! -f "$cfg" ]; then
  # Fresh save dir — seed a minimal VALID config with everything already set (see TIMING above). Written
  # LF: Factorio reads either convention, and it rewrites the file in its own on first clean exit.
  {
    printf '; version=13\n'
    printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=__PATH__system-write-data__\n\n'
    printf '[other]\ncheck-updates=false\ncache-prototype-data=true\n\n'
    printf '[graphics]\ncache-sprite-atlas=true\ncache-sprite-atlas-count=1\n'
  } > "$cfg"
  exit 0
fi

# PRESERVE THE FILE'S OWN LINE ENDINGS. The Windows build writes CRLF and the Linux build writes LF
# (MEASURED: 0 CRs in 3030 lines), and both read either — so sniff rather than assume. Hardcoding CRLF here
# rewrote every line of a Linux-written config on each launch, and the two platforms share one save dir.
if head -c 4096 "$cfg" | grep -q "$(printf '\r')"; then
  INI_CRLF=1
else
  INI_CRLF=0
fi

ini_set "$cfg" other "check-updates" "false"
ini_set "$cfg" other "cache-prototype-data" "true"
ini_set "$cfg" graphics "cache-sprite-atlas" "true"
ini_set "$cfg" graphics "cache-sprite-atlas-count" "1"
