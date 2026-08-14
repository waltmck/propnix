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

  # Layer a per-game tuning over the global wineDefaults. Top-level keys: per-game REPLACES the global
  # atomically (a scalar knob is a whole { value; reason; }, so no reason-bleed). `dllOverrides` merges
  # per-DLL, `userReg` merges per-value, and `mounts` merges per-target/per-field (below). This is why a
  # game spec need only state what's specific to it (e.g. its save-dir mount rows).
  mergeTuning =
    defaults: perGame:
    (defaults // perGame)
    // {
      dllOverrides = (defaults.dllOverrides or { }) // (perGame.dllOverrides or { });
      userReg = mergeNested (defaults.userReg or { }) (perGame.userReg or { });
      # `fpsUserReg` / `vsyncUserReg` — same nested shape as `userReg`, merged per-value (a game adds its
      # fps>0-conditional resp. fps==0-conditional keys).
      fpsUserReg = mergeNested (defaults.fpsUserReg or { }) (perGame.fpsUserReg or { });
      vsyncUserReg = mergeNested (defaults.vsyncUserReg or { }) (perGame.vsyncUserReg or { });
      # `mounts` merges per-TARGET *and* per-field: a game can add an entry, override one field of a
      # default (e.g. `mounts."drive_c/windows/temp".source = …`), or disable one
      # (`mounts.<t>.enabled = false;`) without restating the rest.
      mounts = mergeNested (defaults.mounts or { }) (perGame.mounts or { });
      # `brokenVariables` is a UNION of the global + per-game lists (a game adds the env vars it can't tolerate
      # on top of any global ones), deduplicated.
      brokenVariables = lib.unique ((defaults.brokenVariables or [ ]) ++ (perGame.brokenVariables or [ ]));
      # `systemReg`/`userdefReg` (HKLM/HKU\.Default) merge per-value like `userReg`. `extraSystem32` merges
      # per-DLL like `dllOverrides`. `galaxyStubDlls` is a deduplicated UNION (a layer adds stubs). `exeArgs`,
      # `setupScript`, `userRegScript` are NOT special-cased → the `defaults // perGame` above REPLACES them
      # (a game states its complete arg list / its one script).
      systemReg = mergeNested (defaults.systemReg or { }) (perGame.systemReg or { });
      userdefReg = mergeNested (defaults.userdefReg or { }) (perGame.userdefReg or { });
      extraSystem32 = (defaults.extraSystem32 or { }) // (perGame.extraSystem32 or { });
      galaxyStubDlls = lib.unique ((defaults.galaxyStubDlls or [ ]) ++ (perGame.galaxyStubDlls or [ ]));
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
  # → a flat list (above). Structured non-knob entries (e.g. the `mounts` table) pass through untouched.
  # Asserts the { value; reason; } shape so a typo fails at eval, not silently at launch.
  flattenTuning =
    tuning:
    lib.mapAttrs (
      name: v:
      if name == "dllOverrides" then
        lib.mapAttrs (dll: knob: unwrapKnob "dllOverrides.${dll}" knob) v
      else if name == "userReg" || name == "fpsUserReg" || name == "vsyncUserReg" then
        # Same nested `"<key>"."<name>" = { value; reason; type ? }` shape → the same flat list. The
        # fps/vsync variants' values may carry `$VAR` refs (resolved by the launcher at runtime); the reason
        # assert still holds.
        flattenUserReg v
      else if name == "mounts" then
        # Default each entry's `type` to "mount" (the common case, so bind rows omit it); the launcher's
        # tagged `Mount` sum then always sees a discriminator. An entry that sets `type = "overlay"` wins.
        lib.mapAttrs (_target: m: { type = "mount"; } // m) v
      else if isKnob v then
        unwrapKnob name v
      else
        v
    ) tuning;

  # Resolve a stack of tuning LAYERS to one config via a FIXED POINT (the module-system semantic, in miniature):
  # each layer is either a plain tuning attrset OR a FUNCTION of the FINAL merged config, so a DERIVED entry can
  # reference another knob's POST-override value (e.g. `config: { userReg.…Graphics.value = config.graphics.value; }`
  # recomputes whenever a later layer overrides `graphics`). Layers merge left→right with `mergeTuning` (later
  # wins). `lib.fix` ties the knot; it terminates because derived entries depend on knobs, not vice versa (no
  # cycles). This is what `//`-merge cannot do: `//` resolves a reference BEFORE the override, freezing it.
  resolveTuning =
    layers:
    lib.fix (
      final:
      let
        resolved = map (l: if lib.isFunction l then l final else l) layers;
      in
      lib.foldl' mergeTuning (lib.head resolved) (lib.tail resolved)
    );

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
    resolveTuning
    flattenTuning
    mkSeal
    ;
}
