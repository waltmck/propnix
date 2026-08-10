# config/credentials.nix — the single-user credential model (PLAN2 §3 / §7), as documentation + helpers.
#
# propnix's credentialed fetchers (fetchGogGalaxyBuild) are FODs that need a GOG token at build time. The
# token is NEVER copied into the nix store and NEVER printed. Instead:
#
#   1. The token file (lgogdownloader's `galaxy_tokens.json`) lives in a normal directory on the host,
#      identified by an *id/path string* — a `types.str`, NEVER a `types.path` (a `types.path` would copy
#      the secret into the world-readable store; a `types.str` just names where it lives).
#
#   2. A pointer file `/propnix/credentials.toml` holds only that path:
#          credentialDir = "/var/tmp/propnix/gog"
#      It contains no secret itself — just the location. Nothing else belongs in this file.
#
#   3. `/propnix` is bind-mounted into the build sandbox for the fetch:
#          nix build --extra-sandbox-paths /propnix=/var/tmp/propnix .#hollow-knight
#      (`extra-sandbox-paths` requires a trusted user.) Point the bind at a dir holding the
#      credentials.toml + the credentialDir, readable by the build user.
#
#   MINIMAL CONTENTS (load-bearing). `extra-sandbox-paths` is an ESCAPE VALVE AROUND REPRODUCIBILITY — the
#   sandbox normally forbids host paths precisely so a build can't depend on un-pinned host state. So the
#   bind must carry ONLY authentication, and nothing that could otherwise steer a download:
#     * credentialDir must contain EXACTLY ONE file — `galaxy_tokens.json` (the OAuth token). It must NOT
#       contain lgogdownloader's `config.cfg` (download settings: language/DLC/platform/threads/…),
#       `cookies.txt`, or any other config. The gogdl fetcher reads ONLY `galaxy_tokens.json` and derives a
#       throwaway auth-config from it; every download parameter (productId/buildId/os/lang) is PINNED in
#       the package's versions.json, never taken from the host. Keeping the dir token-only makes it
#       impossible for stray host config to affect the output — the bind can only make a fetch succeed or
#       fail, never change WHAT is fetched.
#     * credentials.toml must contain ONLY `credentialDir = "…"` (the pointer). The fetcher greps just that
#       key and ignores the rest, but keep it minimal so the intent is unambiguous.
#
#   4. The nix build runs as the `nixbld` group, so the token dir + file must be `nixbld`-readable:
#          setfacl -R -m g:nixbld:rX "$credentialDir"
#          setfacl    -m g:nixbld:r  /var/tmp/propnix/credentials.toml
#
# This file is REFERENCE for now (the flake does not wire a NixOS module). A `propnix login` helper +
# a NixOS module that renders credentials.toml and sets `nix.settings.extra-sandbox-paths` are backlog.
{
  # Where the fetchers expect the pointer file inside the sandbox.
  credentialsFile = "/propnix/credentials.toml";

  # The bind argument to pass to `nix build`. LHS is the in-sandbox path; RHS is a host dir you populate.
  sandboxBind = "/propnix=/var/tmp/propnix";

  # Render the credentials.toml body. `credentialDir` is a path STRING (an id), not a secret, so producing
  # this is safe — it copies no token. Write the result to /var/tmp/propnix/credentials.toml yourself.
  mkCredentialsToml =
    { credentialDir }:
    ''
      # propnix credential pointer — NAMES the directory holding the GOG Galaxy token.
      # Contains NO secret itself; the token stays in credentialDir, never entering the nix store.
      credentialDir = "${credentialDir}"
    '';
}
