# icons/from-unity.nix — extractUnityIcon: pull the application icon out of a Unity LINUX standalone
# build. The thin/box64 sibling of from-pe.nix (a Linux ELF carries no icon resource, but a Unity player
# ships its window/app icon as a plain PNG at `<exe>_Data/Resources/UnityPlayer.png`) — the source is
# DISCOVERED AT BUILD TIME (in-builder find across the payload trees), then run through the shared
# pipeline (icons/pipeline.sh), so the output layout matches the other icon sources exactly.
#
# iconName is the reverse-DNS id (org.propnix.<appid>) so `Icon=<iconName>` in the .desktop resolves.
{
  lib,
  runCommandLocal,
  imagemagick,
}:
{
  payloads, # the game-tree derivations (thin overlay lowers); UnityPlayer.png is searched across them
  iconName, # freedesktop icon name, e.g. "org.propnix.hollow-knight"
}:
runCommandLocal "propnix-icon-${iconName}"
  {
    nativeBuildInputs = [ imagemagick ];
    meta.description = "freedesktop hicolor icon theme + splash png extracted from a Unity Linux build's UnityPlayer.png";
  }
  ''
    set -euo pipefail
    # Unity Linux builds ship the app icon at <exe>_Data/Resources/UnityPlayer.png. Find it in the tree(s).
    src=""
    for p in ${lib.concatStringsSep " " (map (p: ''"${p}"'') payloads)}; do
      src="$(find "$p" -type f -path '*_Data/Resources/UnityPlayer.png' 2>/dev/null | head -1 || true)"
      [ -n "$src" ] && break
    done
    [ -n "$src" ] || {
      echo "propnix: extract-unity-icon found no <*_Data>/Resources/UnityPlayer.png in the payload — this is" \
           "not a Unity Linux build. Set an explicit icon.png, or icon.auto = false, for this game." >&2
      exit 1
    }

    source ${./pipeline.sh}
    propnix_icon_theme "$src" "${iconName}" "$out"
  ''
