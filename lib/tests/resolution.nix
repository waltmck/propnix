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
    prison-architect = "gog/x86_64-windows/${wineB}";
    skyrim-se = "gog/x86_64-windows/${wineB}";
    stellaris = "steam/x86_64-linux/${linuxB}";
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
    # ── the host-runnability filter (lib/strategy.nix `runnable`) ──
    # A platform this host cannot execute is skipped by the RESOLVER but stays selectable EXPLICITLY, and an
    # explicit selection must still EVALUATE — the CI eval matrix forces every pinned pair on both systems,
    # so a throw here would turn "this host can't run it" into a red leg. Unrunnability is a BUILD refusal.
    host-filter-skips-unrunnable-platform =
      dflt.factorio.config.emulatedPlatform
      == (if isAarch64 then "aarch64-linux" else "x86_64-linux");
    unrunnable-platform-still-evaluates =
      (builtins.tryEval (dflt.factorio.apply { emulatedPlatform = "aarch64-linux"; }).config.backend).success;
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

  errors =
    matrixErrors
    ++ guardErrors
    ++
      lib.optional (definesFetcher != fetcherExceptions)
        "games defining `fetcher` (quality exceptions) changed: got [${toString definesFetcher}], sanctioned [${toString fetcherExceptions}]";
in
if errors == [ ] then
  pkgs.runCommand "propnix-config-resolution-ok" { } "touch $out"
else
  throw "propnix config-resolution check failed:\n  ${lib.concatStringsSep "\n  " errors}"
