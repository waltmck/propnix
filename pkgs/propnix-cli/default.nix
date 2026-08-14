# propnix-cli — the `propnix` CLI (currently `propnix cred …`: manage the account credentials the
# credentialed game-payload fetchers consume). A standalone Rust crate (no GTK, no sibling path-deps),
# built with rustPlatform.buildRustPackage; deps vendored offline from Cargo.lock. TLS is rustls + bundled
# webpki roots (ureq), so it needs no system OpenSSL/CA — no buildInputs. Arch-independent (runs on both
# hosts). Runtime: it shells out to `xdg-open` (best-effort browser open) and `sudo`/`install`/`rm` (only
# to write the system store `/var/lib/propnix`); those are host tools, deliberately not pinned.
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "propnix-cli";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    name = "propnix-cli-src";
    src = ./.;
    filter =
      path: _type: !(builtins.elem (baseNameOf path) [ "target" ".cargo-home" ]);
  };
  cargoLock.lockFile = ./Cargo.lock;

  doCheck = true; # the only test is the pure `extract_code` unit test — cheap, no network

  meta.description = "propnix CLI: credential management (propnix cred …) for the credentialed game fetchers";
  meta.mainProgram = "propnix";
}
