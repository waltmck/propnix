# NixOS module for propnix host wiring. Enabling it does the five things a host needs to BUILD and RUN
# propnix games that the games themselves can't do from inside a derivation:
#   1. binds the credential directory into the Nix build sandbox at the fixed guest path `/propnix`, so
#      credentialed FODs (e.g. the GOG payload fetch) can read `/propnix/credentials.toml`;
#   2. loads the `ntsync` kernel module (in-kernel Windows sync primitives) that wine uses for fast,
#      correct synchronization;
#   3. trusts the propnix binary cache, so the redistributable half of the closure (the multi-hour wine
#      build, the emulator stack, the Rust tools) is substituted instead of built;
#   4. installs the `propnix` CLI system-wide, which is what populates the credential store in (1);
#   5. optionally MATERIALIZES that credential store declaratively from already-decrypted files
#      (`services.propnix.credentials`) — the sops-nix / agenix path, described below;
#   6. creates the `propnix` group — its members manage the credential store, so `propnix cred add`/`rm`
#      and `propnix pin` need no sudo at all. Members come from `allowedUsers` (default:
#      {option}`nix.settings.allowed-users`) or from `users.users.<you>.extraGroups = [ "propnix" ]`.
#      Tokens themselves are group-owned by the BUILD-USERS group (`nixbld`) via setgid type dirs, which is
#      how a sandboxed build can READ a credential while never being able to write one — see the group
#      comment below for why plain group bits are the only mechanism that reaches a builder.
#
# ── Declarative credentials (sops-nix &c.) ──────────────────────────────────────────────────────────────
# `propnix cred add gog` is imperative: it logs in once and drops a token in /var/lib/propnix. To keep the
# token in your (encrypted) config repo instead, hand this module the RUNTIME PATH of the decrypted file and
# it assembles the store layout the fetchers expect:
#
#   sops.secrets."propnix/gog/alice" = {
#     sopsFile = ./secrets/gog-alice.json;  # the encrypted galaxy_tokens.json
#     format = "binary";                    # store the file verbatim, not as a YAML key
#     restartUnits = [ "propnix-credentials.service" ];   # re-copy when the secret changes
#   };
#   services.propnix.credentials.gog.alice.source = config.sops.secrets."propnix/gog/alice".path;
#
# `propnix-credentials.service` then copies that file to
# `${credentialsPath}/gog/alice/galaxy_tokens.json` (`root:nixbld`, 0640) and writes the non-secret
# `credentials.toml` pointer. It COPIES rather than symlinks on purpose: sops-nix's `path` option
# only creates a symlink into `/run/secrets.d/<generation>/`, and that target does not exist inside the Nix
# build sandbox — the fetcher would see a dangling link. Anything decrypted to a readable path works the same
# way (agenix, a hand-rolled unit, …); this module never knows which one you use.
#
# A declared credential belongs to the config, not to the CLI: `propnix cred list` marks it `(declarative)`
# and `propnix cred rm`/`cred add` refuse it, pointing at the option to edit. Both read the manifest the
# materializer writes beside the store, which is also what it uses to prune a credential you stop declaring.
#
# The copy means the token is plaintext at rest wherever {option}`services.propnix.credentialsPath` points —
# exactly as with `propnix cred add`. For a fully declarative host, set that path to `/run/propnix`: /run is
# a tmpfs, so the store is re-materialized from the encrypted source at every boot and never hits disk.
# ───────────────────────────────────────────────────────────────────────────────────────────────────────
#
# The launcher assembles each wine prefix inside an unprivileged user+mount namespace; those are enabled by
# default on NixOS, so this module adds nothing for them (the launcher errors clearly if they're disabled).
#
# Exposed as the flake's `nixosModules.propnix` (and `.default`) — a `self`-closing module, so the CLI it
# installs is the one built against propnix's OWN pinned nixpkgs (a host-nixpkgs rebuild would miss the
# cache). It adds no game packages — reference those directly, e.g.
# `inputs.propnix.packages.${system}.hollow-knight`.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.propnix;

  # The store contract (layout, pointer body, per-type token filenames), shared with the CLI + fetchers.
  credLib = import ../config/credentials.nix;

  # A token has EXACTLY TWO permitted readers, and its plain permission bits name them both:
  #
  #   owner  = the human who created it  (reads via the owner bits — what lets `propnix pin` run unprivileged)
  #   group  = the BUILD-USERS group     (reads via the group bits — what lets a sandboxed fetch read it)
  #   mode 0640, and the account dir above it 2750, so nobody else reads or even traverses in.
  #
  # Why plain group OWNERSHIP and nothing fancier: a sandboxed builder runs in a user namespace that keeps
  # only its single primary gid (`nixbld`) — supplementary groups are dropped (so a members-list group like
  # the old `propnix-fetch` grants a build nothing), and, decisively on ZFS, the kernel does not honor a
  # POSIX ACL group entry for such a build either (a short-lived ACL contract silently failed exactly
  # there). Plain group-ownership bits are the one mechanism that reliably reaches the builder.
  #
  # Why a human can produce a group-`nixbld` file without sudo (humans are not, and must not be, members of
  # `nixbld` — nix would pick them to run builds as): SETGID INHERITANCE. The TYPE dirs (`gog/`, `steam/`)
  # are `root:nixbld` mode 3777 — setgid + sticky + world-writable, the /tmp model — so any human creates
  # their account dir there unprivileged and it (and the token beneath) inherit group `nixbld` for free.
  # World-writable is confined to the type-dir level, which holds no secrets (account-dir names only), and
  # the sticky bit keeps one user from removing another's account dir.
  #
  # The `propnix` group survives with one job: managing the store ROOT (creating/removing whole type dirs,
  # `cred rm` beside other users' accounts) without sudo.
  credGroup = "propnix";

  # The group whose PRIMARY membership sandboxed builders carry — the group every token must be OWNED by.
  # The CLI is told via PROPNIX_BUILD_GROUP below, so the two writers of the store name the same group.
  buildUsersGroup = config.nix.settings.build-users-group or "nixbld";

  # The humans, resolved from `allowedUsers` using nix's own spelling for that kind of list: a bare name is a
  # user, `@grp` is every member of a group, `*` is every human account (nix's default for allowed-users).
  credentialUsers =
    let
      expand =
        entry:
        if entry == "*" then
          lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users)
        else if lib.hasPrefix "@" entry then
          let
            g = lib.removePrefix "@" entry;
          in
          # `@propnix` would be this very list — skip rather than recurse.
          if g == credGroup then [ ] else config.users.groups.${g}.members or [ ]
        else
          [ entry ];
    in
    lib.unique (lib.concatMap expand cfg.allowedUsers);

  # Flatten `credentials.<type>.<username>` into a list of installable rows.
  credentials = lib.concatLists (
    lib.mapAttrsToList (
      type: accounts:
      lib.mapAttrsToList (username: c: {
        inherit type username;
        inherit (c) source;
        # `null` tokenFile → the type's known filename; the assertion below rejects an unknown type, so the
        # placeholder is never reached (it only keeps evaluation going until assertions are reported).
        file =
          if c.tokenFile != null then c.tokenFile else credLib.tokenFilenames.${type} or "«unknown-type»";
      }) accounts
    ) cfg.credentials
  );

  # The declarative manifest lives NEXT TO the credential dir — never inside it, because the store is
  # bind-mounted into the build sandbox and must carry nothing but authentication. The materializer writes
  # it (one managed store-relative token path per line, world-readable) and uses last generation's copy to
  # prune a credential the config dropped; it is also the CLI's answer to "is this account declarative?"
  # (`CredStore::is_declarative`). Only its PATH is needed here; the contents are derived in the materializer.
  manifestPath = "${lib.removeSuffix "/" cfg.credentialsPath}-declarative-credentials";

  # The activation config for `propnix cred materialize` (the Rust materializer that replaced this unit's
  # former inline shell — pkgs/propnix-cli/src/cred/materialize.rs). It carries everything the store
  # assembly + prune + convergence needs, so the unit itself is a one-line exec. `owner_uid = 0`: the unit
  # runs as root and stamps declared tokens root-owned. Group NAMES (not gids) — the materializer resolves
  # them at activation, when the groups certainly exist. `types` seeds the convergence sweep; it unions the
  # declared types itself, so a custom `tokenFile` type is still converged.
  materializeConfig = pkgs.writeText "propnix-cred-materialize.json" (
    builtins.toJSON {
      root = cfg.credentialsPath;
      owner_uid = 0;
      root_group = credGroup;
      build_group = buildUsersGroup;
      meta_group = "root";
      pointer_body = credLib.mkCredentialsToml;
      manifest_path = manifestPath;
      types = lib.attrNames credLib.tokenFilenames;
      credentials = map (c: {
        inherit (c) type username file source;
      }) credentials;
    }
  );
in
{
  options.services.propnix = {
    enable = lib.mkEnableOption "propnix host support (credential store + sandbox path, ntsync, CLI, cache)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.propnix-cli;
      defaultText = lib.literalExpression "propnix.packages.\${system}.propnix-cli";
      description = ''
        The `propnix` CLI added to {option}`environment.systemPackages` — `propnix cred add <type>` writes
        the credential store at {option}`services.propnix.credentialsPath`. Defaults to the package from
        propnix's own pinned nixpkgs so it substitutes from the cache; override to build your own.
      '';
    };

    credentialsPath = lib.mkOption {
      # A plain string (a host path/id), deliberately NOT `types.path`: a `types.path` would copy the
      # credential dir into the world-readable store. The value is only ever used as a sandbox bind target.
      type = lib.types.str;
      default = "/var/lib/propnix";
      example = "/var/lib/propnix";
      description = ''
        Host directory holding the propnix credential store — the `credentials.toml` pointer plus the
        per-account tokens under `<type>/<username>/` (populated by `propnix cred add <type>`). When
        {option}`services.propnix.enable` is set, this is bound into the Nix build sandbox as `/propnix`
        via {option}`nix.settings.extra-sandbox-paths`, so credentialed fetches can read it. A token file is
        readable by exactly two parties: its owner (the human who added it — how `propnix pin` reads it)
        and the nix build group that OWNS it (mode 0640 — how the sandboxed fetch reads it). Never copied
        into the Nix store.

        The bare directory is created by {option}`systemd.tmpfiles.rules`, which runs in `sysinit.target`
        — BEFORE `nix-daemon.socket` — so the sandbox bind can never dangle. That ordering is the whole
        point: `nix.settings.extra-sandbox-paths` names this path unconditionally, and a build whose
        sandbox source does not exist FAILS, so a directory created only by an unordered oneshot leaves a
        window at every boot (and, on a tmpfs path like `/run/propnix`, at every boot without fail) in
        which EVERY sandboxed build on the host breaks. `propnix-credentials.service` then materializes
        the contents. Either way it ends up `root:propnix` mode 2775: group-writable, so that
        `propnix cred add`/`rm` need no sudo, and setgid, so anything a member creates at the root level
        keeps the managing group. With every credential declared via {option}`services.propnix.credentials`, set
        this to `/run/propnix`: /run is a tmpfs, so the store is rebuilt from the encrypted sources at
        each boot and no token is ever written to disk.
      '';
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.nix.settings.allowed-users;
      defaultText = lib.literalExpression "config.nix.settings.allowed-users";
      example = [
        "alice"
        "@wheel"
      ];
      description = ''
        Users who may MANAGE the credential store beyond their own accounts. Adding one's own credential
        needs NO membership at all (the type dirs are world-writable-with-sticky, /tmp-style, and `propnix
        pin` reads one's own tokens as their owner); the `propnix` group additionally owns the store root,
        so a member can remove other users' accounts or add a new backend type dir without sudo. Building a
        game needs no membership either (the sandboxed fetcher reads tokens via its build group).

        Written like nix's user lists, and defaulting to {option}`nix.settings.allowed-users` because that
        is already the real boundary: the credential dir is bound into EVERY sandboxed build on this host
        (see {option}`nix.settings.extra-sandbox-paths`), so anyone who may use the daemon can copy
        `/propnix` into a derivation output and read the token from the world-readable store. Group
        membership grants nothing extra — it just saves the detour. A bare name is one user, `@grp` is every
        member of that group, and `*` — nix's default — is every human account on the machine. `[ ]` keeps
        the group empty and leaves membership to {option}`users.users.<name>.extraGroups`, which is honoured
        either way.
      '';
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.attrsOf (
          lib.types.submodule {
            options = {
              source = lib.mkOption {
                # A RUNTIME path string, deliberately NOT `types.path` — a `types.path` would copy the token
                # into the world-readable Nix store. Passing `./token.json` is therefore a type error, which
                # is the point.
                type = lib.types.str;
                example = lib.literalExpression ''config.sops.secrets."propnix/gog/alice".path'';
                description = ''
                  Path to the DECRYPTED token file on the running system — e.g. the `path` of a sops-nix or
                  agenix secret. Its contents are copied into the credential store at activation; the file
                  itself is only read at runtime and never enters the Nix store.

                  The copy is deliberate: sops-nix's `path` is a symlink into `/run/secrets.d/<generation>/`,
                  which does not exist inside the Nix build sandbox, so a symlinked token would read as
                  dangling during a build.

                  If the file is missing when `propnix-credentials.service` runs, that one credential is
                  skipped with an error in the journal and the unit fails — the others are still installed.
                '';
              };

              tokenFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Filename to store the token under, i.e. the name the fetcher globs for. `null` means the
                  standard name for this account type (`gog` → `galaxy_tokens.json`, `steam` →
                  `depotdownloader-store.tar`). Only set this when adding a backend propnix doesn't know yet.
                '';
              };

            };
          }
        )
      );
      default = { };
      example = lib.literalExpression ''
        {
          gog.alice.source = config.sops.secrets."propnix/gog/alice".path;
          steam.bob.source = config.sops.secrets."propnix/steam/bob".path;
        }
      '';
      description = ''
        Credential store contents, declared as `<account type>.<username>`, materialized at activation by
        `propnix-credentials.service` into
        `''${config.services.propnix.credentialsPath}/<type>/<username>/<token file>` — the exact layout
        `propnix cred add <type>` produces, so the fetchers, `propnix cred list` and `propnix pin` see no
        difference. Account types are the `propnix cred add` types: `gog`, `steam`.

        This is the sops-nix / agenix path: the encrypted token lives in your config repo, and only
        {option}`source` — a runtime path to the decrypted file — is named here. Add
        `restartUnits = [ "propnix-credentials.service" ]` to the secret so rotating it re-copies.

        Tokens are installed `root:<build group>` mode 0640: the sandboxed fetch reads them via the group
        bits, and no human reads them directly at all — a declared token belongs to the configuration, so
        `propnix pin` on a declarative-only host runs under sudo (root reads anything) or alongside an
        imperative account of one's own.

        Declarative and imperative credentials coexist: this only ever writes the accounts listed here, and
        prunes one when you remove it, so tokens added with `propnix cred add` are left alone. In the other
        direction the CLI defers to the config — `propnix cred list` marks a declared account `(declarative)`
        and `propnix cred rm` refuses it, naming this option instead.
      '';
    };

    useCache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Add `https://propnix.cachix.org` to {option}`nix.settings.substituters` and its public key to
        {option}`nix.settings.trusted-public-keys`. The cache holds only the redistributable packages
        (the wine/FEX/box64 emulator stack and the Rust launcher/CLI) — game payloads are fetched from
        the vendor with your own credentials and are never pushed. Set to `false` to build the stack
        locally instead; expect a multi-hour wine build.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      map (c: {
        assertion = c.file != "«unknown-type»";
        message =
          "services.propnix.credentials.${c.type}.${c.username}: unknown account type '${c.type}' "
          + "(known: ${lib.concatStringsSep ", " (lib.attrNames credLib.tokenFilenames)}). "
          + "If this is a new backend, name its token file explicitly with "
          + "services.propnix.credentials.${c.type}.${c.username}.tokenFile.";
      }) credentials
      ++ [
        {
          # The manifest path is derived by stripping ONE trailing slash (`manifestPath` above), while
          # the CLI derives its own by the same rule from `PROPNIX_CRED_DIR` — but "/var/lib/propnix//"
          # strips to ".../propnix/" here and the CLI would look elsewhere, so the two would silently
          # disagree about which accounts are declarative. Refuse the input instead of normalizing it.
          assertion = cfg.credentialsPath == lib.removeSuffix "/" cfg.credentialsPath;
          message =
            "services.propnix.credentialsPath must not end in a slash (got "
            + "'${cfg.credentialsPath}'): the declarative-credentials manifest path is derived from it, "
            + "and a trailing slash desynchronizes it from the path the propnix CLI computes.";
        }
      ]
      ++ lib.concatMap (
        c:
        let
          # Every one of these is a single path COMPONENT under the store root, and all three are also
          # written verbatim into the line-oriented manifest. A slash or `..` escapes the frozen
          # `<type>/<username>/<file>` layout (the unit would then `install -d`/`rm -f` outside it); a
          # newline forges a manifest entry, and so a false "(declarative)" mark in `cred list`.
          plain =
            what: v:
            let
              bad = lib.hasInfix "/" v || lib.hasInfix ".." v || lib.hasInfix "\n" v || v == "" || v == ".";
            in
            {
              assertion = !bad;
              message =
                "services.propnix.credentials.${c.type}.${c.username}: ${what} must be a plain path "
                + "component (got '${v}'): no '/', no '..', no '.', no newline, not empty. It becomes one "
                + "level of <credentialsPath>/<type>/<username>/<token file> and is recorded verbatim, one "
                + "per line, in the declarative-credentials manifest.";
            };
        in
        [
          (plain "the account type" c.type)
          (plain "the username" c.username)
          (plain "tokenFile" c.file)
          {
            # `cache/` is the artifact-cache sibling with its own (world-writable, non-secret) contract;
            # a credential "type" of that name would re-stamp it to the token contract and hide the
            # account from `cred list`. The materializer refuses it too; catch it at eval time.
            assertion = c.type != "cache";
            message =
              "services.propnix.credentials.cache.${c.username}: 'cache' is the artifact cache beside "
              + "the credential store, not a credential type.";
          }
        ]
      ) credentials;

    # May-manage-a-credential: the humans from `allowedUsers`. Merges with the members nixpkgs derives from
    # `extraGroups`, so a hand-added user is not displaced.
    users.groups.${credGroup}.members = credentialUsers;

    warnings = lib.optional (config.nix.settings.auto-allocate-uids or false) ''
      services.propnix: nix `auto-allocate-uids` runs each build as a per-build synthetic uid/gid that
      belongs to no host group, so a token group-owned by `${buildUsersGroup}` is unreadable to the
      builder. A bound-in token would have to be world-readable for a credentialed fetch (the GOG/Steam
      payloads) to read it, which propnix does not do. Turn `auto-allocate-uids` off on a host that
      builds propnix game packages.
    '';

    # `propnix cred add gog` etc. — the tool that populates the credential dir bound in below.
    environment.systemPackages = [ cfg.package ];

    # Keep the CLI pointed at the same store this module binds + materializes, and at the same group, so an
    # imperatively added token is readable by exactly the same people as a declared one. (Both are read by
    # the unprivileged CLI process before it sudo-escalates the store write, so a session variable lands.)
    environment.sessionVariables = {
      PROPNIX_CRED_DIR = cfg.credentialsPath;
      # The group every token must be OWNED by — the build users' PRIMARY group, the one identity a
      # user-namespaced builder keeps. Exported so the CLI and this module's convergence can't disagree.
      PROPNIX_BUILD_GROUP = buildUsersGroup;
    };

    # The sandbox bind target, created EARLY. `extra-sandbox-paths` names this path unconditionally, and
    # a build whose sandbox source is missing fails outright — so it cannot be left to the oneshot below,
    # which is ordered against nothing: every boot would have a window in which every sandboxed build on
    # the host breaks, and with the recommended tmpfs `/run/propnix` that window is EVERY boot.
    # systemd-tmpfiles-setup runs in sysinit.target, well before nix-daemon.socket. The unit below then
    # brings the same directory to policy and fills it; both agree on root:propnix 2775.
    #
    # `cache/` is the ARTIFACT CACHE beside the credential dirs (pin/steamcache.rs). WRITE side: open to
    # everyone (`cache` is 0777, world-writable and NON-sticky), builders included — the point being that a
    # fetch holding the pin's trust anchors runs with NO Steam login. World-WRITE is safe because nothing in
    # it is trusted: every entry is verified against a versions.json hash before use, and any mismatch —
    # including whatever a malfunctioning builder scribbles — is just a cache miss. READ side: the leaf
    # `cache/steam` is setgid `${buildUsersGroup}` and NON-sticky (2777) — setgid so even a host-side pin's
    # entries land in the build group (cache-hot pin→build handoff), non-sticky so a build can replace an
    # entry it can't read and `supersede` can prune old manifests regardless of who wrote them. Its entries
    # are 0640, so a cached depot key (an ownership-gated content key) is readable only by its creator and
    # the build sandbox — the same two readers a token has — never world-readable.
    #
    # The TYPE dirs are pre-created per the token contract (see the group comment above): setgid
    # `${buildUsersGroup}` + sticky + world-writable, so a human's `cred add` needs no privilege and the
    # token inherits the build group. One rule per known backend, straight from the shared contract table.
    systemd.tmpfiles.rules = [
      "d ${cfg.credentialsPath} 2775 root ${credGroup} -"
      "d ${cfg.credentialsPath}/cache 0777 root root -"
      # setgid so even a host-side pin's entries land in the build group (cache-hot pin→build handoff);
      # NON-sticky (2777, not 3777) so a build can replace an entry it can't read and `supersede` can
      # prune old manifests regardless of which build user wrote them — the cache is regenerable and
      # anchor-verified, so it needs no sticky deletion-guard.
      "d ${cfg.credentialsPath}/cache/steam 2777 root ${buildUsersGroup} -"
    ]
    ++ map (t: "d ${cfg.credentialsPath}/${t} 3777 root ${buildUsersGroup} -") (
      lib.attrNames credLib.tokenFilenames
    );

    # Materialize the credential store: assemble the pointer + declared tokens, prune what a previous
    # generation declared and this one doesn't, and converge the whole store onto the group-ownership
    # contract. This was a long inline shell script; it is now `propnix cred materialize` (Rust —
    # pkgs/propnix-cli/src/cred/materialize.rs), because the store's type dirs are WORLD-WRITABLE and the
    # convergence has to re-own/re-mode entries beneath them without ever following a symlink some other
    # user planted there. Shell `chmod` always dereferences and has no per-fd form, leaving a check-then-
    # chmod race the script could not close; the Rust version opens every entry with `O_NOFOLLOW` and
    # mutates the resulting descriptor (`fchmod`/`fchown`/`fremovexattr`), so a swapped-in symlink either
    # fails the `openat` or is simply not what the `fchmod` acts on. All the policy (modes, groups, owner)
    # lives in the JSON config rendered above.
    systemd.services.propnix-credentials = {
      description = "Materialize the propnix credential store";
      wantedBy = [ "multi-user.target" ];
      # sops-nix decrypts during activation (before units start) and, in setups that use it, from this unit;
      # ordering against a unit that doesn't exist is a no-op, so this covers both without a dependency.
      after = [ "sops-install-secrets.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe cfg.package} cred materialize ${materializeConfig}";
      };
    };

    # Expose the credential dir inside the build sandbox at the fixed guest path propnix fetchers expect.
    nix.settings.extra-sandbox-paths = [ "/propnix=${cfg.credentialsPath}" ];

    # wine's ntsync backend needs the /dev/ntsync char device the kernel module provides.
    boot.kernelModules = [ "ntsync" ];

    # Substitute the redistributable half of the closure from the propnix cache. Listed plainly (not
    # `extra-*`) so it merges with the rest of the host's config; nixpkgs `mkAfter`s cache.nixos.org,
    # so upstream still gets tried last.
    nix.settings.substituters = lib.optionals cfg.useCache [ "https://propnix.cachix.org" ];
    nix.settings.trusted-public-keys = lib.optionals cfg.useCache [
      "propnix.cachix.org-1:SNLYz28zaBpFI1ORjqI7pPXy95fFmumG1aF4gW1eAxo="
    ];
  };
}
