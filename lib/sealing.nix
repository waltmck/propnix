# sealing.nix — pure-lib data model for the §7 environment seal and the typed-tuning flatten/merge.
#
# Nix COMPUTES the intended environment here; the Rust launcher ENFORCES it. The seal is a TARGETED
# SCRUB, never an env_clear()+allowlist: the launcher unsets only the env vars whose names start with the
# scrub prefixes (WINE*/FEX_*/BOX64_*/LD_*), leaves the rest of the inherited session env intact
# (WAYLAND_DISPLAY/DISPLAY/GL/MESA_* shader cache/XDG_*/DBUS/PULSE/PIPEWIRE/PATH/LANG all pass through),
# then applies the meant vars on top. One missing GL/Wayland var under a clear+allowlist is a black screen
# — the targeted scrub cannot have that failure mode. (See the prefer-targeted-env-scrub decision.)
{ lib }:
let
  # The env-var namespaces the launcher unsets before spawning the wine child. These are exactly the
  # families that would otherwise leak the *caller's* wine/FEX/box64/loader config into the sealed child.
  defaultScrub = [
    "WINE"
    "FEX_"
    "BOX64_"
    "LD_"
  ];

  # A tuning knob is authored as { value; reason; } so every non-default choice carries its justification
  # inline (PLAN2 §6).
  isKnob = v: builtins.isAttrs v && v ? value;

  unwrapKnob =
    name: v:
    assert lib.assertMsg (v ? value && v ? reason)
      "propnix tuning knob '${name}' must be { value; reason; } (PLAN2 §6: every knob justifies itself).";
    v.value;

  # Merge two nested "<key>"."<name>" maps per-VALUE (per-game adds/overrides individual values within a
  # key; the rest of the global map stays). Used for `userReg`.
  mergeNested =
    a: b:
    lib.listToAttrs (
      map (k: lib.nameValuePair k ((a.${k} or { }) // (b.${k} or { }))) (
        lib.unique (lib.attrNames a ++ lib.attrNames b)
      )
    );

  # Layer a per-game tuning over the global winefexDefaults. Top-level keys: per-game REPLACES the global
  # atomically (a scalar knob is a whole { value; reason; }, so no reason-bleed). `dllOverrides` merges
  # per-DLL and `userReg` merges per-value (per-game adds/overrides individual entries; the rest stays).
  # `save` (per-game only) simply appears. This is why a game spec need only state what's specific to it.
  mergeTuning =
    defaults: perGame:
    (defaults // perGame)
    // {
      dllOverrides = (defaults.dllOverrides or { }) // (perGame.dllOverrides or { });
      userReg = mergeNested (defaults.userReg or { }) (perGame.userReg or { });
    };

  # Flatten `userReg` (nested "<key>"."<name>" = { value; reason; type ? "REG_SZ"; }) to a LIST of
  # { key; name; value; type; } — the launcher applies each into HKCU every launch via `wine reg add`.
  flattenUserReg =
    userReg:
    lib.concatLists (
      lib.mapAttrsToList (
        key: values:
        lib.mapAttrsToList (
          name: knob:
          assert lib.assertMsg (knob ? value && knob ? reason)
            "propnix userReg[${key}][${name}] must be { value; reason; } (PLAN2 §6: every override justifies itself).";
          {
            inherit key name;
            value = knob.value;
            type = knob.type or "REG_SZ";
          }
        ) values
      ) userReg
    );

  # Strip the reasons to plain values for the runtime config. `dllOverrides` → DLL → value (map); `userReg`
  # → a flat list (above). Structured non-knob entries (e.g. `save = { guestRel; hostDefault; }`) pass
  # through untouched. Asserts the { value; reason; } shape so a typo fails at eval, not silently at launch.
  flattenTuning =
    tuning:
    lib.mapAttrs (
      name: v:
      if name == "dllOverrides" then
        lib.mapAttrs (dll: knob: unwrapKnob "dllOverrides.${dll}" knob) v
      else if name == "userReg" then
        flattenUserReg v
      else if isKnob v then
        unwrapKnob name v
      else
        v
    ) tuning;

  # mkSeal builds the seal record baked into the launcher config: the scrub prefixes, the structured
  # `dllOverrides` map (DLL → load order; the launcher joins it into WINEDLLOVERRIDES and merges the
  # DXVK/vkd3d entries), and `setEnv` (the remaining meant vars: WINEDEBUG, USER/LOGNAME, plus any per-game
  # extras). The launcher layers PROPNIX_* runtime overrides on top at launch.
  mkSeal =
    {
      setEnv ? { },
      dllOverrides ? { },
      scrub ? defaultScrub,
    }:
    {
      inherit scrub dllOverrides setEnv;
    };
in
{
  inherit
    defaultScrub
    isKnob
    mergeTuning
    flattenTuning
    mkSeal
    ;
}
