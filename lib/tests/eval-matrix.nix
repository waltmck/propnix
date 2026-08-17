# tests/eval-matrix.nix — the CI EVAL matrix (wired as the flake's `ci.<system>` output; driven by
# .github/workflows/eval.yml via ci/eval-matrix.sh, ONE `nix eval` process per target — an in-eval
# infinite recursion aborts the whole evaluator and `tryEval` cannot catch it, so per-process isolation
# is what keeps one blown combo from masking the rest and makes the failing combo identifiable).
#
# Coverage: every PINNED (game × fetcher × emulatedPlatform) pair of every auto-discovered game — each
# forced via `.apply { fetcher; emulatedPlatform; }` down to `.drvPath` — and, where the pair has DLC,
# the `.withAllDlc` derivation in the same target. Pure eval only: nothing is ever built or fetched.
#
# The nixpkgs instantiation here (flake.nix `ci` output) sets allowBroken: a meta.broken title must
# still EVALUATE (broken refuses building, not evaluation) — so a broken mark never fails the matrix,
# while a genuine eval error inside a broken game's expression still does.
{ lib, pkgs }:
let
  scope = import ../. { inherit pkgs; };

  # Force one combo: the base derivation, plus the all-DLC derivation when the pair carries DLC. The
  # returned string is what `nix eval --raw` prints on success; its content is incidental — the point is
  # what evaluating it forces.
  force =
    game: fetcher: platform:
    let
      applied = game.apply { inherit fetcher; emulatedPlatform = platform; };
      dlcNames = lib.attrNames applied.dlc;
    in
    if dlcNames == [ ] then
      applied.drvPath
    else
      "${applied.drvPath} +dlc[${toString dlcNames}]:${applied.withAllDlc.drvPath}";

  # "game/fetcher/platform" → lazy forced-eval product, one entry per pinned pair. Enumerating the names
  # forces only each game's fetchInfo (axis-independent by invariant — see modules/app-options.nix), never
  # the combos themselves — mkApp's lazyDerivation spine is what keeps `game.config` access from forcing
  # the default-combo backend dispatch (see lib/mk-app.nix), so one game's regression can't poison the
  # other games' targets.
  targets = lib.listToAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        gname: game:
        lib.concatLists (
          lib.mapAttrsToList (
            fetcher: byPlatform:
            lib.concatLists (
              lib.mapAttrsToList (
                platform: pin:
                lib.optional (pin != null) (
                  lib.nameValuePair "${gname}/${fetcher}/${platform}" (force game fetcher platform)
                )
              ) byPlatform
            )
          ) game.config.fetchInfo
        )
      ) scope.games
    )
  );
in
{
  names = lib.attrNames targets;
  inherit targets;
}
