# Fallout: New Vegas prefix setup — run by propnix-launcher (the `setupScript` tuning field) in the OUTER
# phase, BEFORE wine. Seeds Documents\My Games\FalloutNV\FalloutPrefs.ini (+ Fallout.ini) so the game does NOT
# bounce to FalloutNVLauncher.exe. We launch FalloutNV.exe directly, and the Gamebryo engine, finding NO
# FalloutPrefs.ini, SPAWNS FalloutNVLauncher.exe and EXITS (DIRECTLY diagnosed via a +file trace: it searches
# the PATH for FalloutNVLauncher.exe as its last act). A FalloutPrefs.ini that carries a [Launcher] section +
# valid [Display] makes the engine treat the profile as configured and proceed to D3D9 device creation itself.
# Idempotent: only writes files that are ABSENT, so user edits + in-game settings changes persist.
#
# Env provided by the launcher:
#   PROPNIX_SAVE_DIR, PROPNIX_APPID  — host save dir = $PROPNIX_SAVE_DIR/$PROPNIX_APPID (bound into the prefix
#                                      at Documents\My Games\FalloutNV; the saveBinds row in default.nix)
#   PROPNIX_WIDTH, PROPNIX_HEIGHT    — the compositor's primary-output mode, physical px (may be unset)
#   PROPNIX_PAYLOAD                  — the game tree (ships Fallout_default.ini + low/medium/high/VeryHigh.ini)

dir="$PROPNIX_SAVE_DIR/$PROPNIX_APPID"
mkdir -p "$dir"
prefs="$dir/FalloutPrefs.ini"
main="$dir/Fallout.ini"

# Fallout.ini: seed from the game's shipped default if absent (the engine also self-creates it, but seeding is
# harmless and deterministic).
if [ ! -e "$main" ] && [ -f "$PROPNIX_PAYLOAD/Fallout_default.ini" ]; then
  cp -f "$PROPNIX_PAYLOAD/Fallout_default.ini" "$main"
  chmod u+w "$main"
fi

# FalloutPrefs.ini: seed once (never clobber). Base = the shipped "medium" quality preset (the graphics keys
# the launcher's auto-detect would apply), then inject a valid [Display] (resolution + WINDOWED + the adapter
# name we spoof via wined3d's VideoPciVendorID, see wine-tuning.nix) and a [Launcher] section so the engine treats
# the profile as configured and does not bounce to the launcher.
if [ ! -e "$prefs" ]; then
  W="${PROPNIX_WIDTH:-1280}"
  H="${PROPNIX_HEIGHT:-720}"
  preset="$PROPNIX_PAYLOAD/medium.ini"
  tmp="$(mktemp)"
  # Copy the preset, injecting the [Display] hardware keys right after its [Display] header.
  awk -v w="$W" -v h="$H" '
    BEGIN { done = 0 }
    /^\[Display\]/ && !done {
      print
      print "iSize W=" w
      print "iSize H=" h
      print "bFull Screen=0"
      print "bBorderless=0"
      print "bTopMostWindow=0"
      print "bMaximizeWindow=0"
      print "iLocation X=5"
      print "iLocation Y=5"
      print "sD3DDevice=\"NVIDIA GeForce GTX 660\""
      print "iAdapter=0"
      print "iScreenShotIndex=0"
      print "bFXAAEnabled=0"
      print "iPresentInterval=1"
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print "[Display]"
        print "iSize W=" w
        print "iSize H=" h
        print "bFull Screen=0"
        print "sD3DDevice=\"NVIDIA GeForce GTX 660\""
        print "iAdapter=0"
      }
    }
  ' "$preset" > "$tmp"
  # A [Launcher] section is what a launcher-written profile carries; its presence marks the profile "configured".
  {
    printf '\n[Launcher]\n'
    printf 'bEnableFileSelection=1\n'
    printf 'uLastAspectRatio=3\n'
    printf 'bShowMainMenuMovie=0\n'
    printf 'bShowUpdateWarning=0\n'
  } >> "$tmp"
  mv "$tmp" "$prefs"
  chmod u+w "$prefs"
fi
