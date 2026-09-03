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
#   4. A token has EXACTLY TWO readers, and its plain permission bits name them both:
#          owner  the human who created it — reads via the owner bits (what lets `propnix pin` run
#                 without privilege).
#          group  the BUILD-USERS group (`nixbld`; `PROPNIX_BUILD_GROUP` overrides) — reads via the group
#                 bits (what lets a sandboxed fetch read it). Mode 0640; the account dir above is 2750, so
#                 nobody else reads or traverses in.
#      Plain group OWNERSHIP is load-bearing, not a style choice. A sandboxed builder runs in a user
#      namespace that keeps only its single primary gid (`nixbld`): supplementary groups are dropped (a
#      members-list group grants a build nothing), and — verified the hard way on ZFS — a POSIX ACL group
#      entry is not honored for such a build either. The group bits are the one mechanism that reaches it.
#      And since a human is not (and must never be — nix would run builds as them) a member of `nixbld`,
#      the group arrives by SETGID INHERITANCE rather than chgrp: the TYPE dirs (`gog/`, `steam/`) are
#      `root:nixbld` mode 3777 — setgid + sticky + world-writable, the /tmp model — so any human creates
#      their account dir unprivileged and everything beneath inherits the build group. World-writability
#      stops at the type-dir level, which holds no secrets (account-dir names only); the sticky bit keeps
#      one user from removing another's account dir. Off NixOS the CLI bootstraps the same layout itself
#      (the type-dir creation sudo-escalates once when the store root isn't writable).
#
#   4b. `<root>/cache` is a companion artifact cache, not a credential (Steam depot keys and manifest
#      snapshots — pin/steamcache.rs): a fetch whose pin carries the trust anchors
#      (`depotKeySha256`/`manifestSha256` on the row) completes from it with zero Steam logins.
#      WRITE is open to everyone (world-writable, builders included) and NEVER privileged — a sandboxed
#      FOD cannot sudo, so the cache is entirely self-managing: correctness never rests on it (every entry
#      is hash-verified against the pin before use; stale, truncated, or arbitrarily wrong bytes from a
#      malfunctioning builder read as a MISS that falls back to the login path). READ follows the token
#      rule in spirit: entries are 0640, owned by their WRITER, group = the writer's — a depot key is an
#      ownership-gated content-decryption key, so it is never world-readable. A build user's primary group
#      IS `nixbld`, so build-written entries are shared by all builds unprivileged; a host pin's entries
#      stay the human's (on a module store the setgid `cache/steam` dir lands even those in `nixbld`, so
#      the pin→build handoff is cache-hot there too). The dir is deliberately NON-sticky: a build that
#      meets an entry it cannot read replaces it with its own readable copy (self-heal — a host pin never
#      clobbers, avoiding ping-pong), and each run prunes a depot's superseded manifests, so the cache
#      holds ~1 manifest + 1 key per depot regardless of users, accounts, or update history.
#
#   5. Declared credentials are the config's, not the CLI's. The NixOS module records what it materializes in
#      `<root>-declarative-credentials` (beside the store, never inside it — the bind carries auth only): one
#      store-relative token path per line, world-readable. That manifest is the contract by which the module
#      prunes a credential dropped from the config, and by which the CLI answers "is this declarative?" —
#      `cred list` marks such an account `(declarative)` and `cred rm` refuses it, naming the option to edit
#      (and `cred add` over one is refused the same way). The module keeps a declared account's dir
#      root-owned (2750), so the unprivileged CLI path cannot delete or overwrite what activation restores.
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
