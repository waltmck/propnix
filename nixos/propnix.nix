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
#      A second, derived group `propnix-fetch` holds those same humans PLUS the Nix build users, and owns
#      the token files: a build can READ a credential, never write one. See the group comment below.
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
# `${credentialsPath}/gog/alice/galaxy_tokens.json` (`root:propnix-fetch`, 0640) and writes the non-secret
# `credentials.toml` pointer. It COPIES rather than symlinks on purpose: sops-nix's `path` option
# only creates a symlink into `/run/secrets.d/<generation>/`, and that target does not exist inside the Nix
# build sandbox — the fetcher would see a dangling link. Anything decrypted to a readable path works the same
# way (agenix, a hand-rolled unit, …); this module never knows which one you use.
#
# A declared credential belongs to the config, not to the CLI: `propnix cred list` marks it `(declarative)`
# and `propnix cred rm` refuses it, pointing at the option to edit. Both read the manifest the service keeps
# beside the store (see `managedList` below), which is also what prunes a credential you stop declaring.
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

  # TWO groups, because read and write have to be separable. Everyone who reads a token — every human, AND
  # the Nix build users that run the credentialed fetch — must share the group on the token FILE, since a file
  # has only one. But a build must never be able to WRITE the store, so write can't hang off that same group.
  # It hangs off the group on the DIRECTORIES instead, which the build users are not in:
  #
  #   propnix        the humans. Owns the dirs (2775) → `propnix cred add`/`rm` need no sudo.
  #   propnix-fetch  those same humans PLUS the build users. Owns the token files (0640) → read only.
  #
  # `propnix` is the one users touch (`users.users.<you>.extraGroups = [ "propnix" ]`); membership of
  # `propnix-fetch` is derived from it below, so the two can't drift. Neither is the build-users group
  # (`nixbld`) itself: its members are exactly who nix picks to RUN builds as, so putting a human in it would
  # hand builds their uid.
  credGroup = "propnix";
  fetchGroup = "propnix-fetch";

  # The build users, for the read group only. Nix applies a build user's supplementary groups to the builder
  # (`getgrouplist` in libstore's user-lock.cc — the same mechanism that gets builders into `kvm`), so
  # supplementary membership is enough; their primary group stays `nixbld`.
  buildUsers = lib.optionals config.nix.enable (
    map (n: "nixbld${toString n}") (lib.range 1 config.nix.nrBuildUsers)
  );

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
          # `@propnix`/`@propnix-fetch` would be this very list — skip rather than recurse.
          if g == credGroup || g == fetchGroup then [ ] else config.users.groups.${g}.members or [ ]
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

  # Store-relative paths this generation manages, one per line. Recorded as a manifest NEXT TO the credential
  # dir — never inside it, because the store is bind-mounted into the build sandbox and must carry nothing
  # but authentication. Comparing last generation's manifest against this one prunes a credential the config
  # dropped, while never listing (and so never touching) a token `propnix cred add` created.
  #
  # It is also the CLI's answer to "is this account declarative?" (`CredStore::is_declarative`) — hence a
  # world-readable file at a path derived from the store root, not a private detail of this unit.
  managedList = pkgs.writeText "propnix-managed-credentials" (
    lib.concatMapStrings (c: "${c.type}/${c.username}/${c.file}\n") credentials
  );
  manifestPath = "${lib.removeSuffix "/" cfg.credentialsPath}-declarative-credentials";

  pointerFile = pkgs.writeText "propnix-credentials.toml" credLib.mkCredentialsToml;
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
        via {option}`nix.settings.extra-sandbox-paths`, so credentialed fetches can read it. Token files are
        group-owned by `propnix-fetch` (mode 0640) — the group that holds both the readers from
        {option}`services.propnix.allowedUsers` and the Nix build users. Never copied into the Nix store.

        The bare directory is created by {option}`systemd.tmpfiles.rules`, which runs in `sysinit.target`
        — BEFORE `nix-daemon.socket` — so the sandbox bind can never dangle. That ordering is the whole
        point: `nix.settings.extra-sandbox-paths` names this path unconditionally, and a build whose
        sandbox source does not exist FAILS, so a directory created only by an unordered oneshot leaves a
        window at every boot (and, on a tmpfs path like `/run/propnix`, at every boot without fail) in
        which EVERY sandboxed build on the host breaks. `propnix-credentials.service` then materializes
        the contents. Either way it ends up `root:propnix` mode 2775: group-writable, so that
        `propnix cred add`/`rm` need no sudo, and setgid, which is how the CLI recognises a store under
        group management. With every credential declared via {option}`services.propnix.credentials`, set
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
        Users who may MANAGE the credential store. They go in the `propnix` group, which owns the store
        directories, and in the derived `propnix-fetch`, which owns the token files — so a member can run
        `propnix cred add`, `propnix cred rm` and `propnix pin` with no sudo anywhere. Building a game needs
        no membership at all (the sandboxed fetcher gets read access of its own).

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

        Tokens are installed `root:propnix-fetch` mode 0640, so who can read one is
        {option}`services.propnix.allowedUsers`.

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
              bad = lib.hasInfix "/" v || lib.hasInfix ".." v || lib.hasInfix "\n" v || v == "";
            in
            {
              assertion = !bad;
              message =
                "services.propnix.credentials.${c.type}.${c.username}: ${what} must be a plain path "
                + "component (got '${v}'): no '/', no '..', no newline, not empty. It becomes one level "
                + "of <credentialsPath>/<type>/<username>/<token file> and is recorded verbatim, one per "
                + "line, in the declarative-credentials manifest.";
            };
        in
        [
          (plain "the account type" c.type)
          (plain "the username" c.username)
          (plain "tokenFile" c.file)
        ]
      ) credentials;

    # May-manage-a-credential: the humans from `allowedUsers`. Merges with the members nixpkgs derives from
    # `extraGroups`, so a hand-added user is not displaced.
    users.groups.${credGroup}.members = credentialUsers;

    # May-read-a-credential: whoever ended up in `propnix` by either route, plus the build users. Derived from
    # the group above rather than from `allowedUsers`, so a user hand-added with `extraGroups` gets read
    # access too instead of write-without-read.
    users.groups.${fetchGroup}.members = lib.unique (
      config.users.groups.${credGroup}.members ++ buildUsers
    );

    warnings = lib.optional (config.nix.settings.auto-allocate-uids or false) ''
      services.propnix: nix `auto-allocate-uids` runs each build as a per-build synthetic uid/gid that
      belongs to no host user or group (and, under the user namespace it maps, cannot override permissions
      on a root-owned file), so no `propnix-fetch` membership can reach the builder. A bound-in token would
      have to be world-readable for a credentialed fetch (the GOG/Steam payloads) to read it, which propnix
      does not do. Turn `auto-allocate-uids` off on a host that builds propnix game packages.
    '';

    # `propnix cred add gog` etc. — the tool that populates the credential dir bound in below.
    environment.systemPackages = [ cfg.package ];

    # Keep the CLI pointed at the same store this module binds + materializes, and at the same group, so an
    # imperatively added token is readable by exactly the same people as a declared one. (Both are read by
    # the unprivileged CLI process before it sudo-escalates the store write, so a session variable lands.)
    environment.sessionVariables = {
      PROPNIX_CRED_DIR = cfg.credentialsPath;
      # The group for token FILES. The CLI takes the dirs' group by inheritance instead (the store root is
      # setgid `propnix`), which is what keeps a `cred add` from ever group-writing to the read group.
      PROPNIX_BUILD_GROUP = fetchGroup;
    };

    # The sandbox bind target, created EARLY. `extra-sandbox-paths` names this path unconditionally, and
    # a build whose sandbox source is missing fails outright — so it cannot be left to the oneshot below,
    # which is ordered against nothing: every boot would have a window in which every sandboxed build on
    # the host breaks, and with the recommended tmpfs `/run/propnix` that window is EVERY boot.
    # systemd-tmpfiles-setup runs in sysinit.target, well before nix-daemon.socket. The unit below then
    # brings the same directory to policy and fills it; both agree on root:propnix 2775.
    systemd.tmpfiles.rules = [ "d ${cfg.credentialsPath} 2775 root ${credGroup} -" ];

    # Materialize the credential store: the non-secret pointer always, plus a copy of every declared token.
    systemd.services.propnix-credentials = {
      description = "Materialize the propnix credential store";
      wantedBy = [ "multi-user.target" ];
      # sops-nix decrypts during activation (before units start) and, in setups that use it, from this unit;
      # ordering against a unit that doesn't exist is a no-op, so this covers both without a dependency.
      after = [ "sops-install-secrets.service" ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        root=${lib.escapeShellArg cfg.credentialsPath}
        rc=0

        # The store root, created if absent and otherwise brought to policy: this unit running at all means
        # the module manages the store, so a root first made by `propnix cred add` (owned by whoever ran it,
        # group `nixbld` before this module existed) converges here. 2775 = group-writable by `propnix`, so a
        # member adds/removes a credential without sudo, and setgid so what they create keeps that group —
        # which is also the flag `propnix cred` reads to know the store is under group management.
        install -d -m 2775 -o root -g ${credGroup} "$root"

        # The fetcher pointer. Names the in-sandbox root (/propnix); holds no secret.
        install -m 0644 -o root -g ${fetchGroup} ${pointerFile} "$root/credentials.toml"

        # Copy one decrypted token into the store, readable by the propnix-fetch group and nobody else. A
        # failure is reported and skipped rather than fatal, so a single missing/unreadable secret can't
        # strand every other account. `[ -e ]` follows symlinks, which is what catches a sops secret whose
        # generation dir is gone.
        #
        # The type dir matches the root (2775 `propnix`) so imperative accounts can still be added beside a
        # declared one, but the ACCOUNT dir is deliberately root-owned and NOT group-writable: a declared
        # credential belongs to the config, so `propnix cred rm` refuses it (it reads the manifest, and could
        # not unlink the token anyway) rather than deleting something the next activation restores.
        install_cred() { # <type> <username> <token file> <source>
          local type=$1 user=$2 file=$3 src=$4
          if [ ! -e "$src" ]; then
            echo "propnix: $type/$user: credential source $src does not exist — skipped" >&2
            rc=1
            return
          fi
          if install -d -m 2775 -o root -g ${credGroup} "$root/$type" \
            && install -d -m 0755 -o root -g ${credGroup} "$root/$type/$user" \
            && install -m 0640 -o root -g ${fetchGroup} "$src" "$root/$type/$user/$file"; then
            return
          fi
          echo "propnix: $type/$user: failed to install credential from $src" >&2
          rc=1
        }

        ${lib.concatMapStrings (
          c:
          "install_cred ${
            lib.escapeShellArgs [
              c.type
              c.username
              c.file
              c.source
            ]
          }\n"
        ) credentials}

        # Prune credentials a previous generation declared and this one doesn't. Only paths from our own
        # manifest are considered, so an imperatively added token is never a candidate.
        manifest=${lib.escapeShellArg manifestPath}
        if [ -f "$manifest" ]; then
          while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            if ! grep -Fxq -- "$rel" ${managedList}; then
              rm -f -- "$root/$rel"
              # Tidy the now-possibly-empty <type>/<username>/ and <type>/ dirs; a non-empty one just fails.
              rmdir -- "$root/$(dirname "$rel")" 2>/dev/null || true
              rmdir -- "$root/$(dirname "$(dirname "$rel")")" 2>/dev/null || true
            fi
          done < "$manifest"
        fi
        install -D -m 0644 -o root -g root ${managedList} "$manifest"

        exit $rc
      '';
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
