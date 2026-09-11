# mkStoreSkeleton — build the STRUCTURE of a data-only overlay metadata layer for ROOT-OWNED Nix store
# tree(s), so an unprivileged overlay can do writable CoW over them without copying data. For every regular
# file in `payloads` it emits a user-owned SPARSE stub sized to the original (size metadata, zero data
# blocks); directories are mirrored; symlinks are preserved. The tree is packed into a reproducible SPARSE tar.
#
# WHY THE USER-OWNED MIRROR IS THE POINT, not just the sparseness: propnix's mount namespace maps ONLY the
# caller's own uid (`propnix-mount`: `uid_map` = "<uid> <uid> 1"), so every root-owned store file inside it
# reads as `nobody:nogroup` with the store's 0555/0444 modes. A plain overlay over such a lower cannot even
# reach copy-up — the VFS write check on the LOWER directory fails first. MEASURED on this tree (x86_64,
# Rust's two depots, `unshare --user --map-root-user --mount` + a bare `lowerdir=…,upperdir=…` overlay):
# creating a file at the merged ROOT succeeds (the upper root always exists, nothing is copied up), but
# `touch cfg/client.cfg` and appending to `cfg/keys_default.cfg` both fail EACCES against
# `dr-xr-xr-x nobody nogroup cfg`. With this skeleton stacked on top, those same writes work — the stub dirs
# are the caller's own, 0755. So "writable game dir" without a skeleton means "writable game dir ROOT only",
# which is a trap: shallow writes work and deeper ones fail obscurely.
#
# IMPORTANT: the tar carries only structure + sizes, NOT the `user.overlay.*` xattrs. The Nix build sandbox's
# filesystem does not support the `user.*` xattr namespace (`setfattr` → ENOTSUP), so the metacopy/redirect
# xattrs cannot be baked in here. propnix-mount extracts this tar into a tmpfs (which DOES support user.*)
# and then sets, per stub, `user.overlay.metacopy` + `user.overlay.redirect=/<relpath>` (the redirect is just
# the stub's own path). The result mounts as `lowerdir=<skel>::<payload>` with `userxattr`.
#
# Why sparse-AND-sized (the subtle part): overlay copy-up reads the file size from the metadata stub
# (copy_up.c gates the data copy on `if (c->stat.size)`). A 0-byte stub makes copy-up copy 0 bytes — a silent
# truncation on the first write. A stub whose size equals the original makes copy-up pull the full data from
# the store layer through the redirect. Sparse keeps the stub (and the tar) free of real data.
{
  lib,
  runCommandLocal,
  gnutar,
  coreutils,
  findutils,
}:
{
  # The read-only tree(s) the overlay's `lower` points at, HIGHEST PRIORITY FIRST — a LIST because an
  # overlay `lower` may be a colon-joined union (a multi-depot game dir, DLC trees, the steam-emu settings
  # tree), and ONE metadata layer has to span the whole stack: the skeleton is a single normal lowerdir
  # above `::`-separated data-only layers, so a path it does not stub is a path the merged tree cannot copy
  # up. Union semantics are FIRST TREE WINS, matching overlayfs' own leftmost-wins order — which also keeps
  # each stub's SIZE the size of the file that actually wins the lookup (a stub sized to a shadowed copy
  # would truncate or over-read on copy-up). A single-element list is the ordinary case.
  payloads, # list of derivations or store paths
  name ? "skeleton",
  # Payload-relative file paths whose metacopy stub must be EXECUTABLE (mode 0755) — so the merged overlay
  # file is +x while its data still comes from the (0444) store tree via the metacopy redirect (zero
  # copy). This is how a Steam depot's 0444 executable is made runnable without re-emitting its data: box64
  # and native exec both require +x on the ELF they load. Default [] → every stub keeps the writable-by-owner
  # 0644 truncate default (fine for read/dlopen; the outer overlay is read-only regardless). Must be
  # owner-writable so propnix-mount can stamp the metacopy/redirect xattrs at runtime (setxattr needs write).
  #
  # An entry NOT present in this skeleton's own tree(s) is SKIPPED, not an error: thin.nix builds one
  # skeleton PER game tree (a single-element `payloads`), and an executable naturally lives in only one of
  # them — the base payload's engine
  # binary is absent from an additive DLC tree, and a DLC that ships its own complete build of the game
  # carries a copy the base tree's skeleton must not claim. thin.nix asserts separately that every declared
  # executable exists in at least ONE tree, so a typo is still a build failure rather than a 0444 exec.
  executables ? [ ],
}:
runCommandLocal "${name}-overlay-skeleton.tar"
  {
    nativeBuildInputs = [
      gnutar
      coreutils
      findutils
    ];
  }
  ''
    set -euo pipefail
    tree="$PWD/tree"
    mkdir -p "$tree"
    # Mirror the tree(s) in PRIORITY ORDER; a sparse stub sized to the original per regular file. Symlinks
    # kept verbatim (metadata only); directories recreated. (No xattrs here — propnix-mount sets them
    # post-extraction.) A path an EARLIER tree already emitted is skipped: first tree wins, so the stub
    # mirrors the entry overlayfs will actually resolve the redirect to. An earlier non-directory also
    # hides the whole same-named directory from every later tree: e.g. high `foo` (file) masks low
    # `foo/bar`, just as overlayfs does. Checking only the exact path would later try to mkdir below the
    # file and fail the build instead of representing that masking.
    for src in ${lib.escapeShellArgs (map (p: "${p}") payloads)}; do
      ( cd "$src"
        find . -mindepth 1 -print0 | while IFS= read -r -d "" p; do
          rel="''${p#./}"
          ancestor="$rel"
          shadowed=
          while [ "$ancestor" != "." ]; do
            ancestor="$(dirname "$ancestor")"
            [ "$ancestor" != "." ] || break
            if [ -L "$tree/$ancestor" ] || { [ -e "$tree/$ancestor" ] && [ ! -d "$tree/$ancestor" ]; }; then
              shadowed=1
              break
            fi
          done
          [ -z "$shadowed" ] || continue
          if [ -e "$tree/$rel" ] || [ -L "$tree/$rel" ]; then continue; fi
          if [ -L "$p" ]; then
            mkdir -p "$tree/$(dirname "$rel")"
            cp -P "$p" "$tree/$rel"
          elif [ -d "$p" ]; then
            mkdir -p "$tree/$rel"
          elif [ -f "$p" ]; then
            mkdir -p "$tree/$(dirname "$rel")"
            truncate -s "$(stat -c%s "$p")" "$tree/$rel"      # sparse: size metadata, zero data blocks
          fi
        done )
    done
    # Mark the requested executables +x on their stub — the metacopy merged file then reports 0755 while its
    # data still resolves through the redirect to the store payload (no data copy). Kept owner-writable so the
    # runtime xattr stamp (setxattr) succeeds.
    ${lib.concatMapStrings (rel: ''
      if [ -f "$tree"/${lib.escapeShellArg rel} ]; then
        chmod 0755 "$tree"/${lib.escapeShellArg rel}
      fi
    '') executables}
    # Reproducible, sparse tar (extraction uses --no-same-owner, so owner 0 is fine).
    tar --sparse --sort=name --owner=0 --group=0 --numeric-owner --mtime='@1' \
        -cf "$out" -C "$tree" .
  ''
