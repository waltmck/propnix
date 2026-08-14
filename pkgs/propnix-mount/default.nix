# propnix-mount — the mount-table helper (Rust). The launcher runs the game THROUGH this: it unshares a
# private user+mount namespace, bind(2)s the declarative layered table that forms the WINEPREFIX the game
# sees, and then execs the command inside it (self-cleaning — the mounts die with the process tree). Uses
# only raw syscalls, so it has no runtime dependencies. Built like propnix-prefetch: buildRustPackage, deps
# vendored from Cargo.lock, no cargoHash.
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "propnix-mount";
  version = "0.1.0";
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
  doCheck = false;
  meta.description = "Layered bind-mount table in a private user+mount namespace + run a command inside it";
  meta.mainProgram = "propnix-mount";
}
