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
#   4. Read is one group, WRITE is another. Token files are group-owned mode 0640; store dirs are 0755 (their
#      names aren't secret, so a plain user can `cred list` without privilege). Two parties must READ a token
#      — the sandboxed builder, and the human running `propnix pin` — and a file has only one group, so both
#      go in the same one. Write cannot hang off that group, or a build could rewrite the store, so it hangs
#      off the group on the DIRECTORIES, which the build users are not in. Under the NixOS module:
#          propnix        the humans. Owns the dirs, 2775 (group-writable + setgid) → `cred add`/`cred rm`
#                         need no sudo, and a new dir inherits the group instead of being chowned.
#          propnix-fetch  those humans PLUS the Nix build users (nix passes a build user's supplementary
#                         groups to the builder). Owns the token files → read only.
#      `propnix cred` takes the FILE group from `PROPNIX_BUILD_GROUP` (which the module sets to
#      `propnix-fetch`) and the DIR group by inheritance from the setgid parent — never the file group, which
#      would hand builds the store. Off NixOS both collapse to `nixbld`: dirs stay 0755 owner-only, the human
#      reads as the file's owner, and store writes sudo-escalate as before.
#      NEVER the reverse — putting a human in `nixbld` would make them eligible to run builds as.
#
#   5. Declared credentials are the config's, not the CLI's. The NixOS module records what it materializes in
#      `<root>-declarative-credentials` (beside the store, never inside it — the bind carries auth only): one
#      store-relative token path per line, world-readable. That manifest is the contract by which the module
#      prunes a credential dropped from the config, and by which the CLI answers "is this declarative?" —
#      `cred list` marks such an account `(declarative)` and `cred rm` refuses it, naming the option to edit.
#      The module also keeps a declared account's dir root-owned 0755, so the unprivileged path cannot delete
#      what activation would only restore.
#
#      Those modes are hygiene, not a security boundary. `sandbox-paths` is GLOBAL: once the bind is
#      configured, EVERY sandboxed build on the host sees `/propnix`, so anyone allowed to use the daemon can
#      `cp -r /propnix $out` and read the token out of the (world-readable) store. Whoever may build on the
#      host can read the credentials — which is why the module's group defaults to `nix.settings
#      .allowed-users`, and why an untrusted-user host should not carry the bind at all.
#
#      A COROLLARY for nix's `auto-allocate-uids`: it runs builds as a per-build synthetic uid/gid that is in
#      no host group, and its user namespace doesn't map root, so no group membership reaches the builder and
#      a 0640 token is unreadable. Only a world-readable token would work there, so propnix doesn't support
#      that mode (the NixOS module warns).
#
# `propnix cred` writes a system dir, so `add`/`rm` sudo-escalate the store write while the browser login
# itself runs as the invoking user. The NixOS module (`nixosModules.propnix`) renders the sandbox bind.
#
# The store can equally be provisioned DECLARATIVELY instead of by `propnix cred add` — see
# `services.propnix.credentials` in nixos/propnix.nix, which materializes the same layout from
# already-decrypted files (sops-nix, agenix, …). Either way the on-disk shape below is the contract.
{
  # Where the fetchers expect the pointer file inside the sandbox.
  credentialsFile = "/propnix/credentials.toml";

  # The token filename each account type stores under `<root>/<type>/<username>/`. This is the SAME table the
  # `propnix cred` providers implement (`Provider::token_filename`, pkgs/propnix-cli/src/cred/{gog,steam}.rs) and
  # the fetchers glob for; the NixOS module reads it to place declaratively-provisioned tokens. Adding a
  # backend means adding it here, in the provider, and in that backend's fetcher.
  tokenFilenames = {
    gog = "galaxy_tokens.json"; # lgogdownloader/gogdl flat OAuth token object
    steam = "depotdownloader-store.tar"; # tar of DepotDownloader's isolated-storage account.config
  };

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
