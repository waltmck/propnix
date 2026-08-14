# mk-app-icon — turn a single high-resolution raster icon (a PNG, typically shipped in the game's own data
# at far higher fidelity than the .exe's PE resources) into a freedesktop hicolor icon theme + the splash
# PNG, laid out IDENTICALLY to extract-pe-icon.nix so it is a drop-in source for makeAppWine's icon plumbing.
#
# Two corrections over just copying the source, both visible on real game icons (e.g. Factorio's 1024px gear,
# which sits in the upper-left of its canvas with big transparent margins):
#   * AUTOCROP — trim the fully-transparent border (`-trim`) so asymmetric padding can't push the glyph
#     off-centre.
#   * RE-CENTRE + margin — fit the trimmed glyph into a square canvas centred (`-gravity center -extent`),
#     with a small uniform breathing margin, so every emitted size is perfectly centred and square.
#
# iconName is the reverse-DNS id (org.propnix.<appid>) so `Icon=<iconName>` in the .desktop resolves.
{
  runCommand,
  imagemagick,
}:
{
  src, # a raster image path (PNG etc.), usually "${payload}/…/icon.png"
  iconName, # freedesktop icon name, e.g. "org.propnix.factorio"
}:
runCommand "propnix-icon-${iconName}"
  {
    nativeBuildInputs = [ imagemagick ];
    meta.description = "freedesktop hicolor icon theme + splash png, autocropped & recentred from a raster source";
  }
  ''
    set -euo pipefail

    # Master: trim transparent border, then fit into a 512² canvas CENTRED with ~10% breathing room
    # (glyph resized to 460 on its longer side, padded to 512 square). `-background none` keeps alpha; the
    # `-resize WxH` (no `!`) preserves aspect ratio, so a non-square glyph is letterboxed, never stretched.
    master="$TMPDIR/master.png"
    magick "${src}" -alpha on -trim +repage \
      -background none -gravity center \
      -resize 460x460 -extent 512x512 \
      "$master"

    # Standard freedesktop hicolor sizes. Each is a proportional down-scale of the centred master, so the
    # margin/centre is preserved at every size.
    for s in 16 32 48 64 128 256 512; do
      magick "$master" -resize "''${s}x''${s}" "$TMPDIR/i-$s.png"
      install -Dm444 "$TMPDIR/i-$s.png" "$out/share/icons/hicolor/''${s}x''${s}/apps/${iconName}.png"
    done

    # Largest size for the launcher splash (Image::from_file). Namespaced under share/propnix/ (NOT part of
    # the hicolor theme) so it never collides between installed games — identical layout to extract-pe-icon.
    install -Dm444 "$master" "$out/share/propnix/${iconName}.png"
    echo "propnix: built centred hicolor theme (16–512px) + splash png from ${src}"
  ''
