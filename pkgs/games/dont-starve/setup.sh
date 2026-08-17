# Don't Starve prefix setup — run by propnix-launcher (the `setupScript` tuning field) in the OUTER phase,
# BEFORE wine. Ensures `[graphics] fullscreen = true` in Klei's settings.ini so the game starts FULLSCREEN by
# default (its shipped default is windowed). Klei's engine keeps this in settings.ini, NOT the Windows
# registry — a `userReg` entry has NO effect (VERIFIED: user.reg carries no Klei/Don't Starve key; the value
# lives only in settings.ini `[graphics] fullscreen`). This is applied DECLARATIVELY every launch (like a
# userReg override): the setting is forced on, so it also self-heals if the game ever writes it back off.
#
# settings.ini lives in Documents\Klei\DoNotStarve (goggame savePath "{userdocs}/Klei/DoNotStarve"), which
# the saveBinds row binds → $PROPNIX_SAVE_DIR/$PROPNIX_APPID (see default.nix), so on the host it is
# $PROPNIX_SAVE_DIR/$PROPNIX_APPID/settings.ini. Failure aborts the launch (the mkSetupScript wrapper
# supplies `set -euo pipefail`).
#
# TIMING: the setupScript runs before wine, so on a truly fresh save dir settings.ini does not exist yet (the
# game writes it on first launch, AFTER wine, with fullscreen OFF). If we did nothing there, that FIRST launch
# would be windowed. So we SEED a minimal `[graphics] fullscreen = true` when the file is absent — the game
# reads it, starts fullscreen, and fills in every other default when it rewrites the file on exit; the
# `ini_set` branch then maintains the key. Written CRLF to match Klei's own settings.ini format.
#
# Env provided by the launcher:
#   PROPNIX_SAVE_DIR, PROPNIX_APPID  — host save dir = $PROPNIX_SAVE_DIR/$PROPNIX_APPID

# Klei's settings.ini dialect for the shared ini_set (ini-lib.sh, prepended by mkSetupScript): CRLF line
# endings, `key = value` with spaces around `=`, and `;`-comment lines never match as the key assignment.
INI_SEP=" = "
INI_CRLF=1
INI_SKIP_COMMENTS=1

cfg="$PROPNIX_SAVE_DIR/$PROPNIX_APPID/settings.ini"
mkdir -p "$(dirname "$cfg")"
if [ ! -f "$cfg" ]; then
  # Fresh save dir — seed a minimal settings.ini with fullscreen already on (see TIMING above). CRLF to match
  # Klei's format; the game merges in every other default on first write.
  printf '[graphics]\r\nfullscreen = true\r\n' > "$cfg"
  exit 0
fi

ini_set "$cfg" graphics "fullscreen" "true"
