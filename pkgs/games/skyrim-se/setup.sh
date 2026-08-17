# Skyrim SE prefix setup — run by propnix-launcher (the `setupScript` tuning field) in the OUTER phase, BEFORE
# wine. Seeds SkyrimPrefs.ini's display settings (we launch SkyrimSE.exe directly, bypassing
# SkyrimSELauncher.exe, which is the only thing that normally writes them) + an optional graphics quality
# preset. Failure aborts the launch (the mkSetupScript wrapper supplies `set -euo pipefail`), because a
# half-written prefs is worse than a clear error.
#
# `ini_set` comes from the shared ini-lib.sh (mkSetupScript withIniLib) at its defaults — SkyrimPrefs.ini is
# plain-LF `key=value` with no commented assignments, so no INI_* knob is set.
#
# Env provided by the launcher:
#   PROPNIX_SAVE_DIR, PROPNIX_APPID  — host save dir = $PROPNIX_SAVE_DIR/$PROPNIX_APPID (bound into the prefix
#                                      at Documents\My Games\Skyrim Special Edition GOG; the saveBinds row in
#                                      default.nix)
#   PROPNIX_WIDTH, PROPNIX_HEIGHT    — the compositor's primary-output mode, physical px (may be unset if the
#                                      launcher couldn't read the display — then iSize is left as-is)
#   PROPNIX_QUALITY                  — low|medium|high|ultra|default (validated by the launcher; may be unset)
#   PROPNIX_PAYLOAD                  — the game tree (ships Low/Medium/High/Ultra.ini quality presets at root)

prefs="$PROPNIX_SAVE_DIR/$PROPNIX_APPID/SkyrimPrefs.ini"
mkdir -p "$(dirname "$prefs")"
[ -e "$prefs" ] || : > "$prefs"

# Quality preset: low/medium/high/ultra → merge the shipped preset (Skyrim's own Low/Medium/High/Ultra.ini,
# what SkyrimSELauncher.exe's auto-detect would apply); default or unset → leave the engine baseline. The
# user picks this at runtime via PROPNIX_QUALITY, so re-apply every launch (it's their explicit choice; there
# is no in-game quality menu). The preset sets quality keys only (shadows/AA/water/grass/LOD) — never iSize.
case "${PROPNIX_QUALITY:-}" in
  low | medium | high | ultra)
    cap="$(printf '%s' "${PROPNIX_QUALITY:0:1}" | tr '[:lower:]' '[:upper:]')${PROPNIX_QUALITY:1}"
    preset="$PROPNIX_PAYLOAD/$cap.ini"
    [ -f "$preset" ] || {
      echo "skyrim-setup: quality preset not found: $preset" >&2
      exit 1
    }
    sec=""
    while IFS= read -r line; do
      line="${line%$'\r'}" # the shipped preset INIs are Windows CRLF — strip the trailing CR
      case "$line" in
        \[*\]) sec="${line#\[}"; sec="${sec%\]}" ;;
        *=*)
          [ -n "$sec" ] || continue
          k="${line%%=*}"; v="${line#*=}"
          k="$(printf '%s' "$k" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          ini_set "$prefs" "$sec" "$k" "$v"
          ;;
      esac
    done < "$preset"
    ;;
esac

# Display (load-bearing): the Creation Engine renders its backbuffer at iSize even in fullscreen (verified —
# a 100x100 iSize yields a 100x100 render), so iSize MUST equal the real display. Assert every launch so it
# self-corrects across a resolution/monitor change. If the launcher couldn't read the display, leave iSize
# untouched (better a stale value than a blank one).
if [ -n "${PROPNIX_WIDTH:-}" ] && [ -n "${PROPNIX_HEIGHT:-}" ]; then
  ini_set "$prefs" Display "iSize W" "$PROPNIX_WIDTH"
  ini_set "$prefs" Display "iSize H" "$PROPNIX_HEIGHT"
fi
ini_set "$prefs" Display "bFull Screen" "1"
ini_set "$prefs" Display "bBorderless" "0"
ini_set "$prefs" Display "bAlwaysActive" "1"

# vsync: keep the engine's vsync in agreement with DXVK. A DXVK frame cap (PROPNIX_FPS) forces DXVK's present
# to IMMEDIATE (vsync off); if the engine's iPresentInterval then insists on vsync, the two conflict. So set
# iPresentInterval=0 when a cap is requested, and 1 (vsync on) otherwise.
if [ -n "${PROPNIX_FPS:-}" ] && [ "${PROPNIX_FPS:-0}" -gt 0 ] 2>/dev/null; then
  ini_set "$prefs" Display "iPresentInterval" "0"
else
  ini_set "$prefs" Display "iPresentInterval" "1"
fi
