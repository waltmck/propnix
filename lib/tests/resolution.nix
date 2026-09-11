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
    baby-steps = "gog/x86_64-windows/${wineB}";
    baldurs-gate-3 = "gog/x86_64-windows/${wineB}";
    casualties-unknown-demo = "steam/x86_64-windows/${wineB}";
    # Steam-only, Windows-only pins (Steam publishes macOS/Linux depots for this app too, but they are
    # deliberately not pinned) → the single pair resolves itself.
    cities-skylines = "steam/x86_64-windows/${wineB}";
    # Likewise Steam-only, Windows-only — and not sold on GOG at all, so the single pinned pair is also the
    # only one that could ever exist here. The four base depots are all ONE (steam, x86_64-windows) row, so
    # they add payloads, not pairs.
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
  # The README's supported-games tables are derived from the same resolution, so this guards them too.
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
