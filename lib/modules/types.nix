# modules/types.nix — the custom leaf `mkOptionType`s that let an evalModules-based tuning resolver reproduce
# `sealing.nix`'s hand-tuned merge algebra EXACTLY (D16). The module system's default option merging cannot:
# a scalar has no "later definition wins" (equal-priority defs conflict), submodules field-merge (which
# reintroduces the reason-bleed `sealing` was built to prevent) and materialize defaults into the config, and
# `listOf` concatenates without dedup. These three types fix all of that by owning `merge` themselves.
#
# The invariant that makes them exact: propnix layers a game's tuning at EQUAL PRIORITY in module IMPORT ORDER
# (base wine-defaults first, per-game next, `.apply` tweaks last). nixpkgs' `mergeModules` REVERSES the module
# list (`reverseList (doCollect).modules`, lib/modules.nix), so `type.merge` receives the definitions
# LATEST-LAYER-FIRST. Therefore:
#   * last-wins  == `builtins.head defs` (the latest layer)          → reproduces `sealing`'s `defaults // perGame`
#   * base-first == `reverseList defs` before folding                → reproduces `sealing`'s `unique (a ++ b)`
# `filterOverrides` still runs FIRST, so a user's `mkDefault`/`mkForce` escapes order when they want it; with
# all propnix layers at equal (normal) priority, every def survives and the head/reverse rules above hold.
{ lib }:
let
  inherit (lib)
    mkOptionType
    unique
    concatMap
    reverseList
    ;
in
rec {
  # An atomic `{ value; reason; type? }` tuning knob. Merge = WHOLE-RECORD last-wins (never field-wise), so a
  # later layer's knob replaces the earlier one entirely and a new `value` always arrives with its own `reason`
  # — reproducing `mergeTuning`'s `defaults // perGame` on a scalar knob with NO reason-bleed. The winning
  # record must carry a `reason` (mirrors `sealing.unwrapKnob`'s located assert; kept in `merge` so the error
  # is a legible propnix message, not an opaque type mismatch).
  knob = mkOptionType {
    name = "knob";
    description = "atomic { value; reason; type? } tuning knob (whole-record last-wins)";
    # Structural check per definition (loose — the reason contract is enforced with a nicer message in merge).
    check = v: builtins.isAttrs v && v ? value;
    merge =
      loc: defs:
      let
        winner = (builtins.head defs).value;
      in
      lib.throwIfNot (winner ? reason)
        "propnix tuning knob '${lib.showOption loc}' must be { value; reason; } (every knob justifies itself)."
        winner;
  };

  # Whole-value last-wins, NO reason — for non-knob scalars/records `sealing` also replaces via `//`: `exeArgs`
  # (a whole list, REPLACED not concatenated), `setupScript`/`userRegScript`, and each per-field mount value.
  # `check = _: true` so it accepts any leaf (a mount field is str|bool|null|int heterogeneously).
  lastWins = mkOptionType {
    name = "lastWins";
    description = "last definition wins (whole value, no reason)";
    check = _: true;
    merge = _loc: defs: (builtins.head defs).value;
  };

  # UNION + DEDUP in base-first order, first-occurrence kept — reproduces `lib.unique (defaults ++ perGame)`
  # for `brokenVariables` / `galaxyStubDlls`. `defs` arrive latest-first (see header), so `reverseList` restores
  # base-first before the concat. Built by overriding the merge of `listOf elem` (element check/description
  # still apply), NOT by concatenating-with-reorder.
  dedupList =
    elem:
    (lib.types.listOf elem)
    // {
      merge = _loc: defs: unique (concatMap (d: d.value) (reverseList defs));
    };
}
