# tests/resolution.nix — the STANDING eval gate for the (fetcher × emulatedPlatform) resolution semantics
# (wired as `checks.<system>.config-resolution`; pure eval, no payload is ever fetched — configFile paths
# are never forced here, only the resolved axes). It pins three things:
#
#   1. The RESOLUTION MATRIX under the default config: every game's (fetcher, platform, backend) triple.
#      A change here is either a deliberate re-ranking (update the expectation next to it) or a regression.
#   2. That NO game module defines `fetcher` (highestPrio == the injected schema default): a game-authored
#      `fetcher = lib.mkDefault …` is the sanctioned QUALITY-EXCEPTION channel, but it silently defeats the
#      user's preferredFetchers for that game — so every use must be deliberate and listed here (today: none).
#   3. The GUARDS: config validation (unknown/empty/duplicate fetchers), the legible unreachable-pair
#      errors, explicit-selection-beats-the-list, and the axis re-resolution on `.apply`.
{
  lib,
  pkgs,
}:
let
  mk = config: import ../. { inherit pkgs config; };
  dflt = mk { };
  gogOnly = mk { preferredFetchers = [ "gog" ]; };

  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;
  wineB = "wine"; # resolveStrategy's windows backend on both hosts
  linuxB = if isAarch64 then "box64" else "native";

  # 1. The expected triple per game under the DEFAULT config (all fetchers enabled, registry order).
  expected = {
    # Steam-only here (also sold on itch.io/GOG, unpinned) and single-depot per OS: the NATIVE Linux
    # build is pinned, so aarch64 takes box64 and x86_64 runs it directly — no wine on either host.
    baba-is-you = "steam/x86_64-linux/${linuxB}";
    baby-steps = "gog/x86_64-windows/${wineB}";
    baldurs-gate-3 = "gog/x86_64-windows/${wineB}";
    casualties-unknown-demo = "steam/x86_64-windows/${wineB}";
    # Steam-only, Windows-only pins (Steam publishes macOS/Linux depots for this app too, but they are
    # deliberately not pinned) → the single pair resolves itself.
    cities-skylines = "steam/x86_64-windows/${wineB}";
    # Likewise Steam-only, Windows-only — and not sold on GOG at all, so the single pinned pair is also the
    # only one that could ever exist here. The four base depots are all ONE (steam, x86_64-windows) row, so
    # they add payloads, not pairs.
    # The matrix's ONLY i386-linux row, and the one platform whose two hosts take different backends:
    # Aspyr's 32-bit x86 Linux port runs under emulators/fex-linux on aarch64 (box64 emulates x86_64 only)
    # and directly on an x86_64 host. Steam-only and single-pair — Civ V is not sold on GOG, and its
    # Windows depots are deliberately NOT pinned because they ship a CEG-stripped exe (see the package).
    civilization-5 = if isAarch64 then "steam/i386-linux/fex" else "steam/i386-linux/native";
    civilization-6 = "steam/x86_64-windows/${wineB}";
    cyberpunk-2077 = "gog/x86_64-windows/${wineB}";
    dont-starve = "gog/i386-windows/${wineB}";
    # The only HOST-DEPENDENT platform in the matrix: factorio ranks Wube's native ARM64 Linux build first,
    # and `strategy.runnable` drops it on x86_64 (no ARM-on-x86 emulator here), so the resolver walks on
    # down the SAME game-authored ranking to the x86_64 Linux build. Both are `native` — neither host
    # emulates the platform it ends up on.
    factorio = if isAarch64 then "steam/aarch64-linux/native" else "steam/x86_64-linux/native";
    fallout-nv = "gog/i386-windows/${wineB}";
    hollow-knight = "steam/x86_64-linux/${linuxB}"; # linux-first ranking (benchmarks: box64 ahead of wine+FEX)
    hollow-knight-silksong = "gog/x86_64-windows/${wineB}";
    homeworld-rm = "gog/i386-windows/${wineB}";
    iron-lung = "gog/x86_64-windows/${wineB}";
    iron-nest = "gog/x86_64-windows/${wineB}";
    kerbal-space-program = "gog/x86_64-windows/${wineB}";
    no-mans-sky = "gog/x86_64-windows/${wineB}";
    outlast = "gog/x86_64-windows/${wineB}";
    outlast-2 = "gog/x86_64-windows/${wineB}";
    papers-please = "gog/x86_64-windows/${wineB}";
    potionomics = "steam/x86_64-windows/${wineB}";
    prison-architect = "gog/x86_64-windows/${wineB}";
    # R.E.P.O. — Steam ships ONE depot for this app (no macOS/Linux, no DLC), so the matrix has a single
    # pair and there is nothing for the resolver to choose between.
    repo = "steam/x86_64-windows/${wineB}";
    # Rust — Steam-only (Facepunch sell it nowhere else), two depots on the one platform, so the single
    # pinned pair resolves itself. Packaged despite being unlikely to actually run: see pkgs/games/rust,
    # which records the EAC evidence rather than guessing.
    rust = "steam/x86_64-windows/${wineB}";
    # Pinned from BOTH stores at the SAME platform (as baldurs-gate-3 now is). That adds nothing to the
    # ranking — one pinned platform ⇒ `platformPreference` derives itself — so what this row pins is that
    # the FETCHER tie-break is the USER's, not the game's: `preferredFetchers` defaults to the registry's
    # own attr order, "gog" sorts before "steam", and the GOG build wins with no game-authored `fetcher`
    # exception. The `definesFetcher` ratchet below holds the second half of that; the
    # `same-platform-*` guards hold the first (both directions, so a registry reorder cannot silently
    # flip which store a default `nix run` downloads).
    shadow-of-mordor = "gog/x86_64-windows/${wineB}";
    skyrim-se = "gog/x86_64-windows/${wineB}";
    space-engineers = "steam/x86_64-windows/${wineB}";
    stellaris = "steam/x86_64-linux/${linuxB}";
    # Paradox's other Clausewitz title, but WINDOWS-only pins → wine, where stellaris goes Linux/box64.
    victoria-3 = "steam/x86_64-windows/${wineB}";
    # Complete Edition: GOG ships every expansion INSIDE the base build (no dlcId depots to pin), so this
    # is a plain single-pair GOG/Windows row like the other CDPR titles.
    witcher-3 = "gog/x86_64-windows/${wineB}";
  };
  triple = g: "${g.config.fetcher}/${g.config.emulatedPlatform}/${g.config.backend}";
  matrixErrors = lib.concatLists (
    lib.mapAttrsToList (
      n: want:
      let
        got = triple dflt.${n};
      in
      lib.optional (got != want) "${n}: resolved ${got}, expected ${want}"
    ) expected
  );

  # 2. Games with a game-authored `fetcher` definition (the quality-exception channel). Must equal this
  # list exactly — additions are deliberate, documented exceptions, never accidents.
  fetcherExceptions = [ ];
  schemaDefaultPrio = (lib.mkOptionDefault null).priority;
  definesFetcher = lib.filter (
    n: ((dflt.${n}.extend { }).options.fetcher.highestPrio) < schemaDefaultPrio
  ) (lib.attrNames expected);

  # 3. Guards. tryEval catches the resolver/validation throws; each MUST fail (or hold) as stated.
  throws = v: !(builtins.tryEval v).success;
  guards = {
    unknown-fetcher-name-throws =
      throws
        (mk { preferredFetchers = [ "gogg" ]; }).hollow-knight.config.fetcher;
    empty-list-throws = throws (mk { preferredFetchers = [ ]; }).hollow-knight.config.fetcher;
    duplicate-list-throws =
      throws
        (mk {
          preferredFetchers = [
            "gog"
            "gog"
          ];
        }).hollow-knight.config.fetcher;
    unreachable-pair-throws = throws gogOnly.stellaris.config.emulatedPlatform;
    sanctioned-fallback = triple gogOnly.hollow-knight == "gog/x86_64-windows/${wineB}";
    explicit-beats-list =
      triple (gogOnly.hollow-knight.apply { fetcher = "steam"; }) == "steam/x86_64-linux/${linuxB}";
    platform-apply-reresolves-fetcher =
      triple (dflt.hollow-knight.apply { emulatedPlatform = "x86_64-windows"; })
      == "gog/x86_64-windows/${wineB}";
    fetcher-apply-reresolves-platform =
      triple (dflt.hollow-knight.apply { fetcher = "steam"; }) == "steam/x86_64-linux/${linuxB}";
    # ── two fetchers pinning ONE platform (shadow-of-mordor, baldurs-gate-3, skyrim-se) ──
    # The `platformPreference` ratchet counts PINNED PLATFORMS, not pinned pairs, so a game in this shape
    # states no ranking and the store is decided purely by the user's `preferredFetchers` order. Both
    # directions are pinned deliberately: the DEFAULT is only "gog" because `attrNames fetchers` is
    # name-sorted, which is an implementation fact of the registry rather than a stated policy — pin it
    # here so a rename or a reordering shows up as a failed guard instead of as a default `nix run`
    # quietly downloading 43 GB from the other store.
    same-platform-tiebreak-is-the-user-list =
      triple
        (mk {
          preferredFetchers = [
            "steam"
            "gog"
          ];
        }).shadow-of-mordor == "steam/x86_64-windows/${wineB}";
    # …and neither single-store user is ever stranded: both narrowings reach the SAME platform, so this
    # shape has no unreachable-pair case at all (contrast `unreachable-pair-throws` above).
    same-platform-gog-only-resolves = triple gogOnly.shadow-of-mordor == "gog/x86_64-windows/${wineB}";
    same-platform-steam-only-resolves =
      triple (mk { preferredFetchers = [ "steam" ]; }).shadow-of-mordor
      == "steam/x86_64-windows/${wineB}";
    # A game in this shape must NOT declare a ranking: with one pinned platform the derived default is the
    # singleton list, and a hand-written `[ "x86_64-windows" ]` would be a claim the schema already makes.
    same-platform-ranking-stays-derived =
      dflt.shadow-of-mordor.config.platformPreference == [ "x86_64-windows" ];
    # ── the host-runnability filter (lib/strategy.nix `runnable`) ──
    # A platform this host cannot execute is skipped by the RESOLVER but stays selectable EXPLICITLY, and an
    # explicit selection must still EVALUATE — the CI eval matrix forces every pinned pair on both systems,
    # so a throw here would turn "this host can't run it" into a red leg. Unrunnability is a BUILD refusal.
    host-filter-skips-unrunnable-platform =
      dflt.factorio.config.emulatedPlatform == (if isAarch64 then "aarch64-linux" else "x86_64-linux");
    unrunnable-platform-still-evaluates =
      (builtins.tryEval (dflt.factorio.apply { emulatedPlatform = "aarch64-linux"; }).config.backend)
      .success;
    unrunnable-platform-is-broken-off-host =
      (dflt.factorio.apply { emulatedPlatform = "aarch64-linux"; }).meta.broken == !isAarch64;

    # ── the `allowBroken` escape hatch (app-options) ──
    # A caller testing a known wall (`./run-variant.sh hollow-knight '{ backend = "fex"; allowBroken =
    # true; }'`) must get a BUILDABLE package, and the default must stay refused — pinned in both
    # directions so neither the hatch nor the refusal can rot. The three claim SOURCES are covered: a
    # game's own `broken.systems` (hollow-knight's Mono/SMC wall under FEX), mk-thin-build's face×arch
    # guard (box64 handed 32-bit content), and `runnable` (aarch64 content off an aarch64 host).
    #
    # EXPECT WARNINGS when this check runs: forcing those `meta.broken` values is forcing packages built
    # with the hatch, and mkLauncherPackage says so by design. The check passing IS the assertion; the
    # warning lines are the feature working, not a misbehaving gate.
    # Refused on BOTH hosts, for DIFFERENT reasons: on aarch64 by hollow-knight's own Mono/SMC wall, on
    # x86_64 by the fex backend having no x86_64-host interpreter at all. (Writing this as
    # `== isAarch64` — expecting the x86_64 side to be fine — is what broke CI: the second claim was
    # overlooked because this check only ever gets run by hand on the aarch64 dev host.)
    allowbroken-default-refuses = (dflt.hollow-knight.apply { backend = "fex"; }).meta.broken;
    # …and the reason each host reports must be the one that applies THERE, which is the whole job of
    # mk-thin-build's claim selection. Pinned per host because the failure mode is silent: the wrong
    # reason still refuses the build, it just explains it with another machine's wall.
    allowbroken-reason-is-about-this-host =
      let
        r = (dflt.hollow-knight.apply { backend = "fex"; }).meta.brokenReason;
      in
      if isAarch64 then
        lib.hasInfix "guest Mono init" r
      else
        lib.hasInfix "no x86_64-host FEXInterpreter" r;
    allowbroken-suppresses-game-entry =
      (dflt.hollow-knight.apply {
        backend = "fex";
        allowBroken = true;
      }).meta.broken == false;
    allowbroken-keeps-the-reason =
      (dflt.hollow-knight.apply {
        backend = "fex";
        allowBroken = true;
      }).meta ? brokenReason;
    allowbroken-suppresses-face-guard =
      (dflt.civilization-5.apply {
        backend = "box64";
        allowBroken = true;
      }).meta.broken == false;
    allowbroken-suppresses-runnable-refusal =
      (dflt.factorio.apply {
        emulatedPlatform = "aarch64-linux";
        allowBroken = true;
      }).meta.broken == false;
    # A HEALTHY package must carry NO brokenReason at all. The claim list is assembled unconditionally
    # and its reason chosen afterwards, so a claim that does not fire has to say so with a null reason
    # rather than an empty `systems` — otherwise the fallback hands a working package someone else's
    # wall. Hollow Knight's default (box64 on aarch64, native on x86_64) makes no claim from any of the
    # three sources, so `brokenReason` must be absent, not merely unused.
    healthy-default-has-no-broken-reason =
      !(dflt.hollow-knight.meta ? brokenReason) && dflt.hollow-knight.meta.broken == false;
    # …while a package broken on the OTHER host keeps its reason as information (civilization-5 states an
    # x86_64 wall; on aarch64 that is not a refusal but is still worth reading).
    cross-host-reason-survives =
      let
        m = dflt.civilization-5.meta;
      in
      if isAarch64 then (m.broken == false && m ? brokenReason) else m.broken;

    # It is a CALLER's override, never a game's: no packaged title may set it (that would ship a build
    # whose own `broken.systems` says it cannot work).
    allowbroken-unset-by-every-game = lib.all (n: dflt.${n}.config.allowBroken == false) (
      lib.attrNames expected
    );

    # ── the app-wide x87 knob ──
    # ON by default everywhere (the measurement is in app-options), and ONE `false` must reach every
    # backend — pinned so a new backend cannot quietly skip the translation.
    x87-default-is-reduced = lib.all (n: dflt.${n}.config.x87ReducedPrecision) (lib.attrNames expected);
    x87-knob-turns-off =
      (dflt.hollow-knight.apply { x87ReducedPrecision = false; }).config.x87ReducedPrecision == false;

    overridescope-reinstantiates =
      triple
        ((mk { }).overrideScope (final: prev: { propnixConfig.preferredFetchers = [ "gog" ]; }))
        .hollow-knight == "gog/x86_64-windows/${wineB}";
  };
  guardErrors = lib.concatLists (
    lib.mapAttrsToList (n: ok: lib.optional (!ok) "guard failed: ${n}") guards
  );

  # COVERAGE. `expected` is hand-maintained, so without this a NEW game silently escapes the whole check —
  # its resolution unpinned, and its `fetcher` exempt from the quality-exception ratchet below (which
  # iterates `attrNames expected`). That is not hypothetical: baldurs-gate-3 was absent and unchecked.
  # The README's supported-games tables describe this same resolution, but THIS check does not see them:
  # they are prose, and a game absent from both is absent from nothing an eval can reach. Five were
  # missing that way. `ci/readme-tables.sh` is what actually holds them (regenerating both tables from
  # the resolver and diffing), so add a game here AND run that with `--write`.
  uncovered = lib.subtractLists (lib.attrNames expected) (lib.attrNames dflt.games);
  stale = lib.subtractLists (lib.attrNames dflt.games) (lib.attrNames expected);

  errors =
    matrixErrors
    ++ guardErrors
    ++ lib.optional (
      uncovered != [ ]
    ) "games missing from the resolution roster (add their expected triple): ${toString uncovered}"
    ++ lib.optional (
      stale != [ ]
    ) "resolution roster names games that no longer exist: ${toString stale}"
    ++
      lib.optional (definesFetcher != fetcherExceptions)
        "games defining `fetcher` (quality exceptions) changed: got [${toString definesFetcher}], sanctioned [${toString fetcherExceptions}]";
in
if errors == [ ] then
  pkgs.runCommand "propnix-config-resolution-ok" { } "touch $out"
else
  throw "propnix config-resolution check failed:\n  ${lib.concatStringsSep "\n  " errors}"
