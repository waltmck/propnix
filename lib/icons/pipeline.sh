# icons/pipeline.sh — the SHARED raster-icon pipeline (sourced by from-png.nix and from-unity.nix; a shell
# lib rather than a Nix function because from-unity discovers its source PNG at BUILD time with `find`,
# while from-png gets it at eval — a pure-Nix core cannot serve both).
#
# propnix_icon_theme SRC ICON_NAME OUT:
#   * PICK ONE FRAME — a source may be MULTI-FRAME (a Windows .ico bundles every size the game ships,
#     e.g. Civ V's Civ5Icon.ico: sixteen frames from 16² to a 256² PNG). ImageMagick would then write one
#     numbered output per frame and no `$master` at all, so the rest of the pipeline fails on a missing
#     file. Select the LARGEST frame by area rather than trusting frame order, which no format fixes.
#   * RE-CENTRE + margin — fit the trimmed glyph into a 512² canvas CENTRED with ~10% breathing room
#     (glyph resized to 460 on its longer side; `-resize` without `!` preserves aspect ratio, so a
#     non-square glyph is letterboxed, never stretched).
#   * Emit the standard freedesktop hicolor sizes (proportional down-scales of the centred master, so the
#     margin/centre is preserved at every size) + the largest master at share/propnix/<ICON_NAME>.png for
#     the launcher splash (namespaced — never collides between installed games; NOT part of the theme).
# Requires `magick` (imagemagick) on PATH.
propnix_icon_theme() {
    local src="$1" iconName="$2" out="$3"
    local master="$TMPDIR/propnix-icon-master.png"

    # `identify` prints one line per frame; take the index of the biggest. A single-frame source yields
    # index 0, i.e. the same `src[0]` this always used implicitly — so nothing changes for a plain PNG.
    local frame
    frame=$(magick identify -format '%w %h %s\n' "$src" \
        | awk '{ a = $1 * $2; if (a > best) { best = a; idx = $3 } } END { print idx + 0 }')
    echo "propnix: icon source $src — using frame $frame"

    magick "$src[$frame]" -alpha on -trim +repage \
        -background none -gravity center \
        -resize 460x460 -extent 512x512 \
        "$master"

    local s
    for s in 16 32 48 64 128 256 512; do
        magick "$master" -resize "${s}x${s}" "$TMPDIR/propnix-icon-$s.png"
        install -Dm444 "$TMPDIR/propnix-icon-$s.png" "$out/share/icons/hicolor/${s}x${s}/apps/$iconName.png"
    done
    install -Dm444 "$master" "$out/share/propnix/$iconName.png"
    echo "propnix: built centred hicolor theme (16-512px) + splash png from $src"
}
