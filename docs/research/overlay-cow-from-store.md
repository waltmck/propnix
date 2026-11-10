# Writable copy-on-write over the Nix store

propnix gives a game a writable view of its own install directory (and of other store-backed trees)
with an unprivileged overlayfs whose lower layers are root-owned store paths. A plain
`lowerdir=<store>,upperdir=<state>` overlay is not enough for that: inside propnix's user namespace
only the root of the merged tree is writable. The fix is a user-owned metadata skeleton stacked
above the store layers (`mkStoreSkeleton`, lib/builders/store-skeleton.nix). This document records
why the plain overlay fails, the reproduction, and what the skeleton changes.

## Why a plain overlay over the store fails

propnix's mount namespace maps only the caller's own uid (`propnix-mount`: `uid_map` =
`"<uid> <uid> 1"`). Every root-owned store file inside it therefore reads as `nobody:nogroup` with
the store's 0555/0444 modes. Creating a file below the merged root, or opening a lower file for
writing, fails the VFS write-permission check against the lower directory's owner and mode before
overlayfs ever reaches copy-up.

### Reproduction (Rust's two depots)

Measured on x86_64 with Rust's two depots as the lower layers,
`unshare --user --map-root-user --mount` and a bare `lowerdir=…,upperdir=…` overlay:

- Creating a file at the merged root succeeds: the upper root always exists and nothing is copied
  up.
- `touch cfg/client.cfg` fails with EACCES, and so does appending to `cfg/keys_default.cfg`, against

      dr-xr-xr-x nobody nogroup cfg

With the skeleton stacked on top, the same writes succeed: the skeleton's directories belong to the
caller, mode 0755.

A "writable game dir" without a skeleton is therefore a writable game-dir root only, which is a
trap: shallow writes work and deeper ones fail with errors that do not point at the cause.

## What the skeleton is

For every regular file in the lower tree(s) the skeleton holds a user-owned sparse stub sized to the
original (size metadata, no data blocks); directories are mirrored and symlinks preserved. It is
packed into a reproducible sparse tar at build time. At launch propnix-mount extracts it into a
tmpfs, sets `user.overlay.metacopy` and `user.overlay.redirect=/<relpath>` on each stub (the Nix
build sandbox's filesystem rejects the `user.*` xattr namespace with ENOTSUP, so these cannot be
baked into the tar), and mounts

    lowerdir=<skel>::<payload>,userxattr

with the store trees as data-only layers below the skeleton. Reads of unmodified files come from the
store inode through the redirect; the first write copies the file's data up from the store layer.
Writable overlay rows get a skeleton by default; `skeleton = null` opts out where nothing in the
lower is ever modified and only new files are created (the wine defaults' `drive_c/windows/temp` and
`dosdevices` rows).

The stub has to carry the original size: overlay copy-up reads the size from the metadata stub
(`copy_up.c` gates the data copy on `if (c->stat.size)`), so a 0-byte stub would truncate the file
silently on its first write. With a multi-tree lower (multi-depot game dirs, DLC trees, the
steam-emu settings tree) one skeleton spans the whole stack, first tree wins, so each stub's size is
that of the file that wins the lookup.
