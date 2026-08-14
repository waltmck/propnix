# mkStoreSkeleton — build the STRUCTURE of a data-only overlay metadata layer for a ROOT-OWNED Nix store
# tree, so an unprivileged overlay can do writable CoW over it without copying data. For every regular file
# in `payload` it emits a user-owned SPARSE stub sized to the original (size metadata, zero data blocks);
# directories are mirrored; symlinks are preserved. The tree is packed into a reproducible SPARSE tar.
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
  runCommand,
  gnutar,
  coreutils,
  findutils,
}:
{
  payload, # a derivation or store path: the read-only tree the overlay's `lower` points at
  name ? "skeleton",
}:
runCommand "${name}-overlay-skeleton.tar"
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
    cd ${payload}
    # Mirror the tree; a sparse stub sized to the original per regular file. Symlinks kept verbatim
    # (metadata only); directories recreated. (No xattrs here — propnix-mount sets them post-extraction.)
    find . -mindepth 1 -print0 | while IFS= read -r -d "" p; do
      rel="''${p#./}"
      if [ -L "$p" ]; then
        mkdir -p "$tree/$(dirname "$rel")"
        cp -P "$p" "$tree/$rel"
      elif [ -d "$p" ]; then
        mkdir -p "$tree/$rel"
      elif [ -f "$p" ]; then
        mkdir -p "$tree/$(dirname "$rel")"
        truncate -s "$(stat -c%s "$p")" "$tree/$rel"          # sparse: size metadata, zero data blocks
      fi
    done
    # Reproducible, sparse tar (extraction uses --no-same-owner, so owner 0 is fine).
    tar --sparse --sort=name --owner=0 --group=0 --numeric-owner --mtime='@1' \
        -cf "$out" -C "$tree" .
  ''
