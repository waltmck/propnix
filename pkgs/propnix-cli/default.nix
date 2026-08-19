# propnix-cli — the `propnix` CLI. Two command groups:
#   * `propnix cred …` manages the account credentials the payload fetchers consume;
#   * `propnix pin …` recomputes the `outputHash` pins in pkgs/games/*/versions.json by STREAMING the
#     payload, so a re-pin costs O(1) disk instead of a full copy of the game. Refreshing the obvious way
#     needs free disk equal to the title — hundreds of GB for a modern AAA game, impossible on a CI runner.
#
# A standalone Rust crate (no GTK, no sibling path-deps), built with rustPlatform.buildRustPackage; deps
# vendored offline from Cargo.lock. Arch-independent (runs on both hosts).
#
# TLS. Two clients end up in the binary and get their roots differently:
#   * ureq — the OAuth exchanges plus ALL bulk pin traffic (manifests and content chunks) — carries
#     bundled webpki roots and needs nothing from the host.
#   * reqwest, pulled in by steam-vent for Steam's CM control plane, resolves trust through
#     rustls-platform-verifier, which reads the SYSTEM store — absent inside a Nix sandbox. It honours
#     SSL_CERT_FILE, so the wrapper supplies one when nothing real is configured (note a build sandbox
#     pre-sets the sentinel /no-cert-file.crt, which must be treated as "unset"). That is the only reason
#     cacert is in the runtime closure.
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

  # Pure offline tests: NAR serialization against vectors taken from `nix hash path`, the versions.json
  # rewriter, the ordered prefetcher, the Steam manifest/credential decoders, and `extract_code`. No
  # network, no credentials — so this stays on and the package is a meaningful CI gate.
  doCheck = true;

  nativeBuildInputs = [ makeWrapper ];
  # `propnix cred add steam` drives DepotDownloader (the interactive Steam Guard login) and `tar` (to capture
  # its account.config). PIN DepotDownloader — this MUST be the SAME package `fetchSteamDepot` uses, so the
  # .NET isolated-storage path where account.config lands is identical at `cred add` and at fetch time.
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
