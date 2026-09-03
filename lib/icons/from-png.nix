# icons/from-png.nix — mkAppIcon: turn a single high-resolution raster icon (a PNG, typically shipped in
# the game's own data at far higher fidelity than the exe's PE resources) into the freedesktop hicolor
# icon theme + the splash PNG, via the shared pipeline (icons/pipeline.sh: autocrop + recentre + emit).
# Laid out identically to from-pe.nix / from-unity.nix, so it is a drop-in icon source for the builders.
#
# iconName is the reverse-DNS id (org.propnix.<appid>) so `Icon=<iconName>` in the .desktop resolves.
{
  runCommandLocal,
  imagemagick,
}:
{
  src, # a raster image path (PNG etc.), usually "${payload}/…/icon.png"
  iconName, # freedesktop icon name, e.g. "org.propnix.factorio"
}:
runCommandLocal "propnix-icon-${iconName}"
  {
    nativeBuildInputs = [ imagemagick ];
    meta.description = "freedesktop hicolor icon theme + splash png, autocropped & recentred from a raster source";
  }
  ''
    set -euo pipefail
    source ${./pipeline.sh}
    propnix_icon_theme "${src}" "${iconName}" "$out"
  ''
