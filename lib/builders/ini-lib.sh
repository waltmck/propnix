# builders/ini-lib.sh — the shared INI editor for game setup scripts (prepended by mkSetupScript when
# `withIniLib = true`). One awk program, parameterized on the three axes the per-game copies differed on;
# a game sets the shell vars once at the top of its setup.sh (defaults match plain LF `key=val` files):
#
#   INI_SEP           the "key<SEP>value" separator to WRITE (default "=";  Klei writes " = ")
#   INI_CRLF          1 = the file is CRLF (strip CR before matching, write CRLF back; default 0)
#   INI_SKIP_COMMENTS 1 = never treat a `;`-comment line as the key assignment (default 0)
#
# ini_set FILE SECTION KEY VALUE — set KEY in [SECTION] (case-insensitive on both), replacing an existing
# assignment in place, appending to the section if the key is absent, or appending a new section if absent.
ini_set() {
    local f="$1" sec="$2" key="$3" val="$4" tmp
    tmp="$(mktemp)"
    awk -v sec="$sec" -v key="$key" -v val="$val" \
        -v sep="${INI_SEP:-=}" -v crlf="${INI_CRLF:-0}" -v skipcomments="${INI_SKIP_COMMENTS:-0}" '
    function flush() { if (insec && !done) { print key sep val; done = 1 } }
    BEGIN { if (crlf) ORS = "\r\n"; insec = 0; done = 0; seen = 0 }
    { if (crlf) sub(/\r$/, "") }   # normalize CRLF: strip CR before matching, ORS puts it back
    /^[ \t]*\[/ {
      flush()
      h = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", h)
      insec = (tolower(h) == tolower(sec)); if (insec) seen = 1
      print; next
    }
    {
      if (insec && !done) {
        line = $0
        # only match an ACTIVE assignment for this key (a `;`-comment line never is, when the rule is on)
        if (!(skipcomments && line ~ /^[ \t]*;/)) {
          k = line; sub(/=.*/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
          if (tolower(k) == tolower(key)) { print key sep val; done = 1; next }
        }
      }
      print
    }
    END { flush(); if (!seen) { print ""; print "[" sec "]"; print key sep val } }
  ' "$f" > "$tmp"
    mv "$tmp" "$f"
}
