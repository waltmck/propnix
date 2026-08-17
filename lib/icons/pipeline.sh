# icons/pipeline.sh — the SHARED raster-icon pipeline (sourced by from-png.nix and from-unity.nix; a shell
# lib rather than a Nix function because from-unity discovers its source PNG at BUILD time with `find`,
# while from-png gets it at eval — a pure-Nix core cannot serve both).
#
# propnix_icon_theme SRC ICON_NAME OUT:
#   * AUTOCROP — trim the fully-transparent border (`-trim`) so asymmetric padding can't push the glyph
#     off-centre (visible on real game icons, e.g. Factorio's upper-left 1024px gear).
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
    magick "$src" -alpha on -trim +repage \
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
