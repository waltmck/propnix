# propnix-cli — the `propnix` CLI. Two command groups:
#   * `propnix cred …` manages the account credentials the payload fetchers consume;
#   * `propnix pin …` recomputes the `outputHash` pins in pkgs/games/*/versions.json by STREAMING the
#     payload, so a re-pin costs O(1) disk instead of a full copy of the game. Refreshing the obvious way
#     needs free disk equal to the title — hundreds of GB for a modern AAA game, impossible on a CI runner.
#
# A Rust crate built with rustPlatform.buildRustPackage; deps vendored offline from Cargo.lock. One
# sibling path-dep, propnix-steam-cred (the stored Steam credential's wire formats — kept as its own crate
# so the tar/protobuf/JWT decoders are testable in isolation). Arch-independent (runs on both hosts).
#
# TLS. Two clients end up in the binary:
#   * reqwest — Steam's CM control plane AND all bulk chunk traffic (pin/engine.rs) — resolves trust
#     through rustls-platform-verifier, i.e. the SYSTEM CA store. That is a deliberate choice: one trust
#     source for every request the tool makes. It means SSL_CERT_FILE must be sane, which the wrapper below
#     guarantees at runtime (note a build sandbox pre-sets the sentinel /no-cert-file.crt, which must be
#     treated as "unset"), and which `env.SSL_CERT_FILE` guarantees at BUILD time — `doCheck` runs the
#     engine's loopback-server tests, and reqwest cannot even CONSTRUCT a client without roots to load.
#   * ureq — the OAuth exchanges and the metadata calls (build lists, manifests, appinfo) — carries bundled
#     webpki roots and needs nothing from the host.
#
# Runtime: it shells out to `xdg-open` (best-effort browser open) and `sudo`/`install`/`rm` (only to write
# the system store `/var/lib/propnix`); those are host tools, deliberately not pinned.
{
  lib,
  rustPlatform,
  makeWrapper,
  depotdownloader,
  gnutar,

  cacert,
}:
let
  # Build source = this crate dir + the sibling path-dep, mirroring propnix-launcher's layout. Exclude
  # local build state so the hash tracks the code.
  crates = [
    "propnix-cli"
    "propnix-steam-cred"
  ];
in
rustPlatform.buildRustPackage {
  pname = "propnix-cli";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    name = "propnix-cli-src";
    src = ../.; # pkgs/
    filter =
      path: _type:
      let
        rel = lib.removePrefix (toString ../. + "/") (toString path);
        top = lib.head (lib.splitString "/" rel);
      in
      builtins.elem top crates && !(builtins.elem (baseNameOf path) [ "target" ".cargo-home" ]);
  };
  sourceRoot = "propnix-cli-src/propnix-cli";
  cargoLock.lockFile = ./Cargo.lock;

  # The engine's tests build a reqwest client, which cannot be constructed without trust roots to load —
  # and a build sandbox has none. Same bundle the runtime wrapper points at.
  env.SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  # ARMv8 AES intrinsics for the Steam chunk decryptor — see .cargo/config.toml for why this is a `--cfg`
  # rather than a cargo feature, and why it is safe on every target. Set here too because a build sandbox
  # need not honour the in-tree cargo config, and this must not silently regress to software AES.
  RUSTFLAGS = "--cfg aes_armv8";

  # Offline tests: NAR serialization against vectors taken from `nix hash path`, the versions.json
  # rewriter, the chunk engine (queue discipline, requeue-on-failure, read-ahead window, stall liveness —
  # driven against a LOOPBACK http server, so the real reqwest path runs with no external network), the
  # host scorer, the concurrency governor, the chunk containers, and the Steam manifest/credential
  # decoders. No external network and no credentials, so this stays on and the package is a real CI gate.
  doCheck = true;

  nativeBuildInputs = [ makeWrapper ];
  # `propnix cred add steam` drives DepotDownloader (the interactive Steam Guard login) and `tar` (to capture
  # its account.config). It is ONLY used to obtain the token — the depot download itself is this crate's own
  # (pin/engine.rs). PIN it anyway: the .NET isolated-storage path is part of the on-disk layout that
  # `pin::steam::credentials_from_store` later reads back out of the stored tar, so a version bump that moved
  # that path would strand every credential already captured.
  # (`xdg-open`/`sudo`/`install`/`rm` stay unpinned host tools — see the header of the GOG login path.)
  postInstall = ''
    wrapProgram $out/bin/propnix \
      --prefix PATH : ${lib.makeBinPath [ depotdownloader gnutar ]} \
      --run ${lib.escapeShellArg ''
        # Point reqwest's platform verifier at a CA bundle, but only when nothing real is configured.
        # `--set-default` is not enough: a Nix BUILD sandbox pre-sets SSL_CERT_FILE to the sentinel
        # /no-cert-file.crt (deliberately, to stop builders trusting anything), which would win and leave
        # reqwest with "No CA certificates were loaded from the system". A genuine user override — a
        # corporate proxy bundle, say — is still respected.
        if [ -z "''${SSL_CERT_FILE:-}" ] || [ "$SSL_CERT_FILE" = /no-cert-file.crt ]; then
          export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
        fi
      ''}
  '';

  meta.description = "propnix CLI: credential management and O(1)-disk content-pin refresh (propnix cred / propnix pin)";
  meta.mainProgram = "propnix";
}
