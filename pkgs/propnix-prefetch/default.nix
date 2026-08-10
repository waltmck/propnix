# propnix-prefetch — self-contained Rust package (Cargo). Warms the ZFS ARC / page cache for given paths
# via chunked posix_fadvise(WILLNEED) (async dmu_prefetch on ZFS that yields to sync reads; degrades to
# readahead on generic_fadvise filesystems), parallelised with tokio. The launcher's sole cold-launch
# prefetcher (RESEARCH §19). Built with rustPlatform.buildRustPackage; deps vendored offline from
# Cargo.lock (no cargoHash to maintain).
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "propnix-prefetch";
  version = "0.1.0";
  # Only the crate inputs — exclude local build state (target/, .cargo-home/) and this file so the
  # source hash tracks the code, not stray artifacts.
  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      let
        base = baseNameOf (toString path);
      in
      !(base == "target" || base == ".cargo-home" || base == "default.nix");
  };
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = false; # no tests; skip the check phase
  meta.description = "Warm the ZFS ARC / page cache for given paths via chunked posix_fadvise(WILLNEED), tokio-parallel";
}
