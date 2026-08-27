# modules/app-options.nix — the top-level option schema every propnix app module is evaluated against
# (the backend-specific namespaces — `wine.*`, `box64.*` — are declared by the backend registry entries in
# lib/backends/<name>/options.nix, and `steam.*` by modules/steam-emu.nix; all imported alongside this
# module by mk-app.nix).
#
# A game file authors a MODULE setting these options, conditionally on the two ORTHOGONAL axes:
#   * `fetcher`          — WHERE the payload comes from (which store). Picks the payload source + which
#                          store-integration DLL to neutralize (Galaxy stub vs Steam whiteout). A thin layer.
#   * `emulatedPlatform` — the content's OS+ABI. Determines the `backend` (via resolveStrategy) and MOST
#                          tweaks (wine tuning for a Windows build; box64 library triage for a Linux build).
# Neither is stated per-game: both RESOLVE from the game's fetch matrix + its `platformPreference` quality
# ranking + the user's `preferredFetchers` allowlist (platform-major lexicographic — see the axis options
# below), and `.apply { … }` overrides either. The resolution is PURE (config-driven; credentials are
# never probed at eval). Guarded by lib/tests/resolution.nix (the standing flake check).
#
# This file is a FUNCTION of the registries + the validated config (its enums and defaults derive from
# them) — applied by mk-app.nix, which owns the wiring.
{
  lib,
  stdenv,
  knobTypes,
  strategy, # lib/strategy.nix: `platforms` (the axis vocabulary) + `platformToNeed` / `resolveStrategy` / `runnable`
  fetchers, # fetcher registry: name → (emulatedPlatform → fetch function); see lib/default.nix
  backends, # backend registry: name → { modules; build; }; see lib/backends/*/default.nix
  preferredFetchers, # the validated ranked allowlist from propnixConfig (lib/default.nix)
}:
let
  # The supported content platforms + their ABI mapping live in lib/strategy.nix, next to the backend
  # selection that reads them: extending the axis is one edit there, and the fetch matrix below (a
  # genAttrs over this list) then generates the new (fetcher, platform) options automatically.
  inherit (strategy) platforms platformToNeed resolveStrategy;

  # Whether THIS host can run a platform's content at all. A platform is host-specific when it names an
  # arch no emulator here covers (aarch64-linux: native on aarch64, nothing on x86_64), so the resolver
  # filters the game's ranking through this before choosing — see `emulatedPlatform`.
  hostRunnable = p: strategy.runnable p stdenv.hostPlatform.system;

  # The pinned (fetcher, platform) pairs of a fetch matrix — for the resolver error messages.
  pinnedPairsOf =
    fetchInfo:
    lib.concatLists (
      lib.mapAttrsToList (
        f: byPlatform:
        lib.concatLists (lib.mapAttrsToList (p: v: lib.optional (v != null) "${f}/${p}") byPlatform)
      ) fetchInfo
    );

  # The priority of an option's own injected default (mkOptionDefault): a definition with a STRONGER
  # (numerically lower) priority means someone actually defined the option — a game's deliberate mkDefault
  # or a user's `.apply`. Reading `options.<x>.highestPrio` inspects definition priorities WITHOUT forcing
  # the default's value, which is what makes the coupled axis defaults below cycle-free (verified).
  schemaDefaultPrio = (lib.mkOptionDefault null).priority;
in
{ config, options, ... }:
{
  options = {
    pname = lib.mkOption {
      type = lib.types.str;
      description = "Package name (the `bin/<pname>` launcher entry point and derivation name).";
    };
    appid = lib.mkOption {
      type = lib.types.str;
      description = ''
        Stable propnix app id: keys the state dir ($XDG_STATE_HOME/propnix/<appid>), the default save dir
        ($PROPNIX_SAVE_DIR/<appid>), and the reverse-DNS desktop/icon id (org.propnix.<appid>).
      '';
    };
    name = lib.mkOption {
      type = lib.types.str;
      default = config.pname;
      defaultText = lib.literalExpression "config.pname";
      description = "Human-visible name (desktop entry, splash, window-watcher title match).";
    };

    # ── the two orthogonal axes ── Both RESOLVE by default from the game's fetch matrix, its
    # `platformPreference` quality ranking, and the user's `preferredFetchers` allowlist — platform-major
    # lexicographic: for each game-ranked platform, the first listed fetcher that pins it wins. The user's
    # account preference can therefore shift the platform ONLY along the game's own ranking (the game
    # sanctions every fallback); anything unreachable is a legible eval error, never a silent flip.
    platformPreference = lib.mkOption {
      type = knobTypes.lastWins;
      default =
        let
          pinned = lib.filter (
            p: lib.any (f: config.fetchInfo.${f}.${p} != null) (lib.attrNames fetchers)
          ) platforms;
        in
        if lib.length pinned <= 1 then
          pinned
        else
          throw "propnix mkApp (${config.pname}): ${toString (lib.length pinned)} platforms are pinned (${toString pinned}) — declare `platformPreference` (an explicit list, best first) so the selection order is the game's stated quality judgment, not attribute order.";
      defaultText = lib.literalExpression "the single pinned platform (a multi-platform game must declare its ranking)";
      description = ''
        The game's QUALITY ranking of its pinned platforms, best first. Derived automatically for a
        single-platform matrix; a game pinning a second platform MUST state the order explicitly (the
        ratchet keeps selection order a deliberate judgment). The resolver never selects a platform
        outside this list.
      '';
    };
    fetcher = lib.mkOption {
      type = lib.types.enum (lib.attrNames fetchers);
      default =
        let
          match = lib.filter (f: config.fetchInfo.${f}.${config.emulatedPlatform} != null) preferredFetchers;
        in
        if match != [ ] then
          lib.head match
        else
          throw ''
            propnix mkApp (${config.pname}): none of your preferredFetchers [ ${toString preferredFetchers} ] has a
            build pinned for emulatedPlatform '${config.emulatedPlatform}' (pinned pairs: ${lib.concatStringsSep ", " (pinnedPairsOf config.fetchInfo)}).
            Either extend config.preferredFetchers, or select a pinned pair explicitly:
            `.apply { fetcher = …; }` / `.apply { emulatedPlatform = …; }`.'';
      defaultText = lib.literalExpression "the first of preferredFetchers that pins emulatedPlatform";
      description = ''
        Which store the payload comes from. Selects the `fetchInfo.<fetcher>` row of the fetch matrix and
        the store-specific neutralization (GOG's Galaxy SDK needs a no-op stub — `wine.galaxyStubDlls`;
        a Steam build's steam_api needs true absence — `maskFiles`). Resolves from `preferredFetchers`
        within the selected platform; `.apply { fetcher = …; }` overrides (even to an unlisted fetcher —
        the list shapes defaults, it is not a sandbox), and a game may state a deliberate
        `lib.mkDefault` quality exception (which likewise beats the list; keep those rare and justified).
      '';
    };
    emulatedPlatform = lib.mkOption {
      type = lib.types.enum platforms;
      default =
        let
          # An EXPLICIT fetcher definition (a user's `.apply` or a game's mkDefault — anything stronger
          # than the injected schema default) constrains the platform walk to that fetcher's pins;
          # otherwise any listed fetcher counts. Guarded by highestPrio so the two axis defaults never
          # read each other simultaneously (cycle-free; see schemaDefaultPrio).
          fetcherExplicit = options.fetcher.highestPrio < schemaDefaultPrio;
          reachable =
            p:
            if fetcherExplicit then
              config.fetchInfo.${config.fetcher}.${p} != null
            else
              lib.any (f: config.fetchInfo.${f}.${p} != null) preferredFetchers;
          # Skipped BEFORE reachability: a platform this host cannot execute at all (aarch64-linux on
          # x86_64) is not a fallback the user can enable by adding a fetcher, so it must not shape the
          # error either. This is the ONE host-dependent step of the resolution — it lets a game rank its
          # host-specific native build first (factorio: aarch64-linux) without stranding the other host,
          # which then walks on down the SAME game-authored ranking to a portable build. That is why
          # `platformPreference` stays host-INDEPENDENT: it states which build is better, and this filter
          # states what this machine can do with that.
          #
          # NOTE for the day propnix gains an ARM-on-x86 emulator: `runnable` would then be true for
          # aarch64-linux on BOTH hosts, and a plain filter no longer expresses "prefer your own
          # architecture" — an x86_64 host would pick the emulated ARM64 build over its own native one just
          # because the game ranks ARM64 higher. The fix belongs HERE, as a host-native TIEBREAK over the
          # game's ranking (stable-sort the candidates so a platform whose arch matches the host wins ties),
          # not as per-host branching pushed back into every game's `platformPreference`.
          candidates = lib.filter (p: hostRunnable p && reachable p) config.platformPreference;
          # For the error message: platforms this game PINS that the host cannot run. Read off the fetch
          # matrix, not off `platformPreference`, because a game may already have host-conditioned its own
          # ranking (factorio drops aarch64-linux on x86_64) — in which case the unrunnable platform never
          # appears in the ranking and a diagnostic derived from it would always be empty. What the reader
          # needs to know is "this game HAS a build for something, and it isn't one this machine can run".
          hostRejected = lib.filter (
            p: !hostRunnable p && lib.any (f: config.fetchInfo.${f}.${p} != null) (lib.attrNames fetchers)
          ) platforms;
        in
        if candidates != [ ] then
          lib.head candidates
        else
          throw ''
            propnix mkApp (${config.pname}): no platform in this game's ranking [ ${toString config.platformPreference} ] is
            reachable with ${
              if fetcherExplicit then
                "the selected fetcher '${config.fetcher}'"
              else
                "your preferredFetchers [ ${toString preferredFetchers} ]"
            } (pinned pairs: ${lib.concatStringsSep ", " (pinnedPairsOf config.fetchInfo)}).${
              lib.optionalString (hostRejected != [ ]) ''

                (This game also pins ${toString hostRejected}, which ${stdenv.hostPlatform.system} cannot
                run — propnix has no backend for that content here.)''
            }
            Either extend config.preferredFetchers, or select a pinned pair explicitly:
            `.apply { fetcher = …; emulatedPlatform = …; }`.'';
      defaultText = lib.literalExpression "the first game-ranked platform that this host can run and preferredFetchers can reach";
      description = ''
        The content's OS+ABI. Drives `backend` (via resolveStrategy) and most per-game tweaks. Resolves to
        the first `platformPreference` entry that (a) this HOST can run — `lib/strategy.nix` `runnable`,
        which is how a game may rank a host-specific native build (aarch64-linux) first — and (b) is
        reachable with the enabled fetchers; `.apply { emulatedPlatform = …; }` overrides (the fetcher then
        re-resolves within it, and an unrunnable explicit choice is a legible `backend` error).
      '';
    };
    backend = lib.mkOption {
      type = lib.types.enum (lib.attrNames backends);
      default = resolveStrategy (platformToNeed config.emulatedPlatform) stdenv.hostPlatform.system;
      defaultText = lib.literalExpression "resolveStrategy (platformToNeed config.emulatedPlatform) stdenv.hostPlatform.system";
      description = ''
        The execution backend (a lib/backends/* registry entry): windows → wine (FEX/ARM64EC underneath on
        aarch64); x86 linux → box64 on aarch64, native on x86_64; aarch64 linux → native. Override per
        launch style: `.apply { backend = "fex"; }`.

        NB `resolveStrategy` is total over the registry — it answers which backend WOULD run the content,
        not whether this host can. A platform the host cannot run (aarch64 content on x86_64, reachable
        only by an explicit `.apply`) still evaluates and is refused at BUILD time via `meta.broken`,
        contributed by the backend entry. See lib/strategy.nix `runnable`.
      '';
    };

    # ── the fetch matrix ── one option per (fetcher, platform) pair, GENERATED from the registry × the
    # platform list so a typo at either level is an "option does not exist" eval error. A non-null value
    # IS the availability of that pair; the `payloads` default consumes it.
    fetchInfo = lib.genAttrs (lib.attrNames fetchers) (
      f:
      lib.genAttrs platforms (
        p:
        lib.mkOption {
          type = knobTypes.lastWins;
          default = null;
          description = ''
            Fetch arguments for the ${f}/${p} build: a LIST of arg-sets, one per depot/build tree, each
            passed VERBATIM to the ${f} fetcher (order = payload/overlay priority, first wins). null (the
            default) = this game has no ${f} build for ${p} — selecting the pair is a legible error.
            Games usually wire this straight from versions.json: `fetchInfo = (lib.importJSON
            ./versions.json).fetchInfo;`. INVARIANT: a fetchInfo value must never depend on
            config.fetcher / config.emulatedPlatform / config.platformPreference — the matrix is read
            WHILE those axes resolve.
          '';
        }
      )
    );

    # ── the game tree(s) + how to run them ──
    payloads = lib.mkOption {
      type = knobTypes.lastWins;
      default =
        let
          info = config.fetchInfo.${config.fetcher}.${config.emulatedPlatform};
          available = pinnedPairsOf config.fetchInfo;
        in
        if info == null then
          throw ''
            propnix mkApp (${config.pname}): no ${config.fetcher} build is pinned for emulatedPlatform
            '${config.emulatedPlatform}'. Pinned (fetcher/platform) pairs: ${
              if available == [ ] then
                "NONE (set fetchInfo.<fetcher>.<platform>)"
              else
                lib.concatStringsSep ", " available
            }.
            Select one with `.apply { fetcher = …; emulatedPlatform = …; }`, or pin this pair in
            fetchInfo.${config.fetcher}."${config.emulatedPlatform}".''
        else
          map (fetchers.${config.fetcher} config.emulatedPlatform) info;
      defaultText = lib.literalExpression "map (fetchers.\${fetcher} emulatedPlatform) fetchInfo.\${fetcher}.\${emulatedPlatform}";
      description = ''
        The game tree derivation(s), mounted read-only and unioned at launch (first wins; a multi-depot
        game like Stellaris lists its binaries depot before its data depot). Defaults to fetching the
        selected `fetchInfo` pair; settable directly for a bespoke source.
      '';
    };
    exe = lib.mkOption {
      type = knobTypes.lastWins;
      description = "The executable, RELATIVE to the game dir (payload root).";
    };
    online = lib.mkOption {
      type = knobTypes.lastWins;
      default = true;
      description = ''
        Whether this app is allowed to reach the network. `false` makes the launcher unshare a NETWORK
        NAMESPACE for the game, leaving it loopback-only — so propnix's offline guarantee is enforced by the
        kernel rather than by trusting the app and its bundled online SDKs. Display and audio are
        unaffected: Wayland, X11 and PulseAudio are UNIX sockets, which live in the mount namespace.

        Default `true`, deliberately: silently cutting a game off would break anything with legitimate
        online features and is miserable to debug. Set `false` per game once it is known not to need the
        network, or to hold an SDK to its offline path — e.g. a launcher that opens an online sign-in flow
        when it can reach its servers but takes a working offline route when it cannot.
      '';
    };
    exeArgs = lib.mkOption {
      type = knobTypes.lastWins;
      default = [ ];
      description = ''
        Baked launch arguments (before any runtime `-- <args>` passthrough). The single source of exe
        args on every backend.
      '';
    };
    executables = lib.mkOption {
      type = knobTypes.lastWins;
      default = null;
      defaultText = lib.literalExpression "[ config.exe ]";
      description = ''
        THIN backends: game-dir-relative paths that must carry the EXEC bit (Steam depots ship 0444),
        reproduced via a zero-copy metacopy skeleton. null → just the exe. Ignored by wine.
      '';
    };
    maskFiles = lib.mkOption {
      type = knobTypes.dedupList lib.types.str;
      default = [ ];
      description = ''
        Game-dir-relative files ERASED from the game tree at runtime (propnix-mount whiteout rows → true
        absence, no store copy) on every backend. The store-DLL neutralizer for libraries the game merely
        dlopens (a Steam build's libsteam_api.so / steam_api64.dll → the engine reports "no online
        subsystems" and runs offline). An EMPTY stub would instead fault the loader — and a STATICALLY
        imported SDK (GOG Galaxy) needs the opposite, a real no-op stub: `wine.galaxyStubDlls`.

        MECHANISM CONSTRAINT: a whiteout re-overlays the target's PARENT dir in place, using the parent's
        current contents as lowerdir. A parent that is itself a multi-lower overlayfs (the game dir of a
        build with enabled DLC or `extraLowers` — including everything steam.emu wires in) is refused by
        the kernel as a lowerdir: the launch dies with EINVAL. Masks compose with a plain single-payload
        bind (hollow-knight); a game that needs both DLC/extraLowers AND a mask needs the whiteout moved
        into a layer of the stack first — no current builder does that, so treat the combination as
        unsupported rather than as something to work around.
      '';
    };
    workingDir = lib.mkOption {
      type = knobTypes.lastWins;
      default = null;
      description = ''
        Launch working directory RELATIVE to the game dir; null → the game dir itself. For engines that
        resolve assets from the CWD rather than the exe path (Don't Starve: exe "bin/dontstarve.exe",
        workingDir "bin").
      '';
    };
    saveBinds = lib.mkOption {
      type = knobTypes.lastWins;
      default = [ ];
      # A misspelled bind field (`dest`, `readonly`) would otherwise be silently ignored by the builders'
      # `b.ro or false` reads — validate the field names at eval.
      apply = map (
        b:
        let
          unknown = lib.subtractLists [ "src" "dst" "ro" "create" ] (lib.attrNames b);
        in
        lib.throwIfNot (unknown == [ ] && b ? src && b ? dst)
          "propnix: a saveBinds entry needs { src; dst; ro?; create?; } — got unknown/missing field(s): ${toString unknown}"
          b
      );
      description = ''
        Save/state binds `{ src; dst; ro ? false; create ? true; }`: bind the persistent, $VAR-expandable
        `src` (usually "$PROPNIX_SAVE_DIR/$PROPNIX_APPID") at `dst`, a HOME-RELATIVE path — under the
        ephemeral $HOME view on thin backends, under the wine profile home (drive_c/users/<user>/) on
        wine, where each bind derives one mount row (a game's `wine.mounts` can still override it
        per-target). The game writes its native path; the data persists in a propnix dir. NB: this
        expresses BINDS only — overlay-style save persistence (KSP's writable game dir with a
        $PROPNIX_SAVE_DIR upper) stays a hand-written `wine.mounts` row.

        THIN backends additionally accept an ABSOLUTE `dst`, which places the row at that exact path
        instead of under the view — the launcher joins `dst` onto the view, and an absolute component
        replaces it. Used to put a file where a bundled runtime insists on finding it, including inside a
        read-only store path: bind its parent as well and propnix-mount stubs the missing child into a
        skeleton, all confined to the launch's private mount namespace. Wine joins `dst` onto the profile
        home by string, so an absolute path there is an eval-time error — use `wine.mounts` on that
        backend.
      '';
    };
    extraBinds = lib.mkOption {
      type = knobTypes.dedupList lib.types.raw;
      default = [ ];
      apply = map (
        b:
        let
          unknown = lib.subtractLists [ "src" "dst" "ro" "create" ] (lib.attrNames b);
        in
        lib.throwIfNot (unknown == [ ] && b ? src && b ? dst)
          "propnix: an extraBinds entry needs { src; dst; ro?; create?; } — got unknown/missing field(s): ${toString unknown}"
          b
      );
      description = ''
        THIN-only COMPOSABLE bind rows, same `{ src; dst; ro?; create?; }` shape and view-relative `dst`
        semantics as `saveBinds` but UNIONED across layers instead of last-wins — so a framework module
        (steam-emu's shim/settings placements) and the game can each contribute rows without clobbering
        the other. `dst` may reach inside the game dir (`game/<path>`): binding over an existing file
        works, and a missing sibling mountpoint is stubbed into the game overlay by propnix-mount's
        child-skeleton machinery. Not consumed by wine (an eval-time error there — use `wine.mounts`).
      '';
    };

    # ── icon ──
    icon = {
      png = lib.mkOption {
        type = knobTypes.lastWins;
        default = null;
        description = ''
          High-res raster icon SOURCE (usually a PNG shipped in the game's own data), preferred over
          auto-extraction: autocropped, recentred, and emitted as the hicolor theme + splash
          (lib/icons/from-png.nix).
        '';
      };
      symbolic = lib.mkOption {
        type = knobTypes.lastWins;
        default = null;
        description = "Monochrome `-symbolic.svg` (currentColor) icon variant, or null.";
      };
      auto = lib.mkOption {
        type = knobTypes.lastWins;
        default = true;
        description = ''
          When no `icon.png` is given, auto-extract the icon from the payload: the exe's PE resources on
          wine; Unity's <exe>_Data/Resources/UnityPlayer.png on thin backends. DELIBERATELY fails the
          build loudly when extraction finds nothing (e.g. a non-Unity thin game) — set `icon.png` or
          `icon.auto = false` rather than shipping iconless silently.
        '';
      };
    };

    # ── broken ──
    broken = {
      systems = lib.mkOption {
        type = knobTypes.dedupList lib.types.str;
        default = [ ];
        description = ''
          Systems on which this title is known-broken → `meta.broken` there. The derivation still
          EVALUATES (discoverable, reason inspectable); only building is refused.
        '';
      };
      reason = lib.mkOption {
        type = knobTypes.lastWins;
        default = null;
        description = "Why (surfaced via meta for humans; does not affect the build).";
      };
    };

    # ── extra game-dir trees ──
    extraLowers = lib.mkOption {
      type = knobTypes.dedupList lib.types.raw;
      default = [ ];
      description = ''
        Extra trees unioned into the game dir ABOVE the payloads, alongside enabled DLC — for content that
        is neither a payload nor DLC, such as configuration a bundled runtime insists on finding next to
        the game rather than in the store (pkgs/games/stellaris: the offline Steam entitlement settings).
        Merged read-only at mount time, so no copy of the base is made.

        On THIN backends these rank ABOVE every game tree, including each tree's exec-bit fix layer — so
        an entry both adds paths and overrides one a payload already provides. (It ranks below the
        backend's own overlay, the patched-exe layer, which must win at the executable's path.)
      '';
    };

    # ── DLC ──
    dlc = {
      available = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        default = { };
        description = ''
          Available DLC (name → tree derivation, typically a dlcId fetch), set conditionally on the axes
          by the game. Enabled DLC union ABOVE the base payload at mount time (no store copy of the base).
        '';
      };
      enabled = lib.mkOption {
        type = knobTypes.lastWins;
        default = [ ];
        description = ''
          DLC selection by name — set via `game.withDlc [ "…" ]` / `game.withAllDlc` /
          `.apply { dlc.enabled = [ … ]; }`. An unknown name is a legible error.
        '';
      };
    };

    # ── child environment ──
    env = lib.mkOption {
      # lastWins accepts anything; constrain the leaves to STRINGS at eval (the launcher's env map is
      # String→String — a bare number would only fail at load time otherwise).
      type = lib.types.attrsOf (
        knobTypes.lastWins
        // {
          check = builtins.isString;
          description = "string (last definition wins)";
        }
      );
      default = { };
      description = ''
        Extra child environment, unified across backends; values are $VAR-expanded at launch on every
        backend. Precedence: on thin backends applied AFTER the launcher's own defaults (a game can
        override BOX64_*); on wine folded into seal.setEnv BEFORE the launcher's computed
        WINEPREFIX/WINEDLLOVERRIDES/DXVK_* (which always win). Reserved names (WINEDEBUG, USER, LOGNAME,
        WINEPREFIX, WINEDLLOVERRIDES, LD_LIBRARY_PATH, LD_PRELOAD) are an eval-time error on wine.
      '';
    };
  };
}
