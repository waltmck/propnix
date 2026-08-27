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
  lib,
  runCommand,
  gnutar,
  coreutils,
  findutils,
}:
{
  payload, # a derivation or store path: the read-only tree the overlay's `lower` points at
  name ? "skeleton",
  # Payload-relative file paths whose metacopy stub must be EXECUTABLE (mode 0755) — so the merged overlay
  # file is +x while its data still comes from the (0444) store `payload` via the metacopy redirect (zero
  # copy). This is how a Steam depot's 0444 executable is made runnable without re-emitting its data: box64
  # and native exec both require +x on the ELF they load. Default [] → every stub keeps the writable-by-owner
  # 0644 truncate default (fine for read/dlopen; the outer overlay is read-only regardless). Must be
  # owner-writable so propnix-mount can stamp the metacopy/redirect xattrs at runtime (setxattr needs write).
  #
  # An entry NOT present in this payload is SKIPPED, not an error: one skeleton is built per game tree
  # (builders/thin.nix), and an executable naturally lives in only one of them — the base payload's engine
  # binary is absent from an additive DLC tree, and a DLC that ships its own complete build of the game
  # carries a copy the base tree's skeleton must not claim. thin.nix asserts separately that every declared
  # executable exists in at least ONE tree, so a typo is still a build failure rather than a 0444 exec.
  executables ? [ ],
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
