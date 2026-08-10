# extract-pe-icon — pull the application icon out of a Windows PE (.exe) and lay it out as a freedesktop
# hicolor icon theme, so a DE finds it natively via $XDG_DATA_DIRS once the app is installed on a profile.
#
# Windows exes carry their icon as a PE resource (a group-icon referencing several raster sizes). We use
# icoutils: `wrestool` extracts the group-icon into a .ico, `icotool` explodes it into per-size PNGs, and
# we install each at its true size under `share/icons/hicolor/<W>x<H>/apps/<iconName>.png`. Also drops a
# convenience `$out/icon.png` (the largest size) for the launcher splash to load directly.
#
# iconName is the reverse-DNS id (org.propnix.<appid>) so `Icon=<iconName>` in the .desktop resolves.
{
  runCommand,
  icoutils,
}:
{
  payload, # a derivation (the game tree); the exe lives at ${payload}/${exe}
  exe, # executable holding the icon resource, relative to payload
  iconName, # freedesktop icon name, e.g. "org.propnix.hollow-knight"
}:
runCommand "propnix-icon-${iconName}"
  {
    nativeBuildInputs = [ icoutils ];
    meta.description = "freedesktop hicolor icon theme extracted from ${exe}'s PE resources";
  }
  ''
    set -euo pipefail
    work="$TMPDIR/icon-work"
    mkdir -p "$work"

    # Extract the PE group-icon (resource type 14) into a .ico, then explode to per-size PNGs.
    wrestool -x -t 14 "${payload}/${exe}" -o "$work/icon.ico"
    ( cd "$work" && icotool -x icon.ico )

    installed=0
    largest=""
    largest_px=0
    for png in "$work"/*.png; do
      [ -e "$png" ] || continue
      # icotool names files like  icon_<index>_<W>x<H>x<depth>.png  — take the first WxH.
      dims="$(basename "$png" | grep -oE '[0-9]+x[0-9]+' | head -1 || true)"
      [ -n "$dims" ] || continue
      install -Dm444 "$png" "$out/share/icons/hicolor/$dims/apps/${iconName}.png"
      installed=$((installed + 1))
      w="''${dims%x*}"
      if [ "$w" -gt "$largest_px" ]; then
        largest_px="$w"
        largest="$png"
      fi
    done

    [ "$installed" -gt 0 ] || {
      echo "propnix: no icon could be extracted from ${exe}" >&2
      exit 1
    }
    # Largest size, for the launcher splash (Image::from_file). Kept under share/ and namespaced by icon
    # name so it never pollutes the package/profile root and never collides between installed games; it is
    # NOT part of the freedesktop theme (that's the hicolor tree above).
    install -Dm444 "$largest" "$out/share/propnix/${iconName}.png"
    echo "propnix: extracted $installed icon size(s); largest ''${largest_px}px"
  ''
