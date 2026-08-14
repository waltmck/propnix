# config/credentials.nix — the credential model (PLAN2 §3 / §7), as documentation + helpers.
#
# propnix's credentialed fetchers (fetchGogGalaxyBuild) are FODs that need a GOG token at build time. The
# token is NEVER copied into the nix store and NEVER printed. The model:
#
#   1. A credential STORE on the host (default `/var/lib/propnix`), managed by the `propnix cred` CLI:
#          propnix cred add gog          # browser login → mints + stores a token
#          propnix cred list             # accounts, grouped by type, labelled by username
#          propnix cred rm <username>
#      Layout (multi-account, multi-type):
#          /var/lib/propnix/credentials.toml                        # a pointer, not a secret
#          /var/lib/propnix/gog/<username>/galaxy_tokens.json       # one per GOG account (OAuth token)
#      Each token file is the flat `galaxy_tokens.json` (lgogdownloader/gogdl format). The store path is an
#      *id/path string* — a `types.str`, NEVER a `types.path` (a `types.path` would copy the secret into the
#      world-readable store; a `types.str` just names where it lives).
#
#   2. `credentials.toml` names the IN-SANDBOX credential root (where the store is bound, `/propnix`):
#          credentialDir = "/propnix"
#      It contains no secret — just the location. `propnix cred` writes it automatically.
#
#   3. The store is bind-mounted into the build sandbox at `/propnix` for the fetch — either by the NixOS
#      module (`services.propnix.enable`, `credentialsPath = "/var/lib/propnix"`), or manually:
#          nix build --extra-sandbox-paths /propnix=/var/lib/propnix .#hollow-knight
#      (`extra-sandbox-paths` requires a trusted Nix user.)
#
#   MINIMAL CONTENTS (load-bearing). `extra-sandbox-paths` is an ESCAPE VALVE AROUND REPRODUCIBILITY — the
#   sandbox normally forbids host paths precisely so a build can't depend on un-pinned host state. So the
#   bind must carry ONLY authentication, and nothing that could otherwise steer a download:
#     * the store holds ONLY the `credentials.toml` pointer + per-account `galaxy_tokens.json` tokens. It
#       must NOT contain lgogdownloader's `config.cfg` (download settings: language/DLC/platform/threads/…)
#       or `cookies.txt`. The fetcher reads ONLY a `galaxy_tokens.json` and derives a throwaway auth-config
#       from it; every download parameter (productId/buildId/os/lang) is PINNED in the package's
#       versions.json, never taken from the host. So the bind can only make a fetch succeed or fail, never
#       change WHAT is fetched.
#     * The fetcher tries each stored GOG account until one OWNS the pinned build (transparent multi-account).
#
#   4. nixbld access. The build runs as the `nixbld` group, so the tokens must be `nixbld`-readable —
#      `propnix cred` does this: token files are group-owned by `nixbld`, mode 0640; store dirs are 0755
#      (their names aren't secret, so a plain user can `cred list` without privilege).
#
# `propnix cred` writes a system dir, so `add`/`rm` sudo-escalate the store write while the browser login
# itself runs as the invoking user. The NixOS module (`nixosModules.propnix`) renders the sandbox bind.
{
  # Where the fetchers expect the pointer file inside the sandbox.
  credentialsFile = "/propnix/credentials.toml";

  # The bind argument to pass to `nix build`. LHS is the in-sandbox path; RHS is the host store dir.
  sandboxBind = "/propnix=/var/lib/propnix";

  # Render the credentials.toml body. `credentialDir` is the in-sandbox credential root (a path STRING, an
  # id — not a secret), so producing this is safe. `propnix cred` writes this automatically; this helper is
  # for a manual/declarative setup.
  mkCredentialsToml = ''
    # propnix credential pointer — NAMES the in-sandbox credential root (bound at /propnix).
    # Contains NO secret; tokens live under <root>/<type>/<username>/ and never enter the nix store.
    credentialDir = "/propnix"
  '';
}
