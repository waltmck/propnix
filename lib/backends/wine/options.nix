# backends/wine/options.nix — the `wine.*` tuning option schema, as a module (imported by the wine backend
# registry entry). Declares one typed option per knob defaults.nix defines, with a custom leaf type
# (modules/types.nix) per knob chosen so the module merge reproduces the historical `sealing.mergeTuning`
# algebra EXACTLY: mkApp evaluates this module plus each tuning LAYER (the defaults layer + the per-game
# tuning + `.apply` tweaks, verbatim, at equal priority in import order) and the wine builder consumes the
# resolved `config.wine`.
#
# Type ↔ sealing merge map:
#   knob                      graphics, d3d                         — whole {value;reason;} record, last-wins
#   attrsOf knob              dllOverrides                          — per-DLL, whole-knob last-wins  (`a // b`)
#   attrsOf (attrsOf knob)    userReg fpsUserReg vsyncUserReg        — per-key/per-name knob         (mergeNested)
#                             systemReg userdefReg
#   attrsOf lastWins          extraSystem32                         — per-DLL, whole-value           (`a // b`)
#   attrsOf (attrsOf lastWins) mounts                               — per-target/per-field           (mergeNested)
#   dedupList str             brokenVariables galaxyStubDlls        — union + dedup, base-first
#   lastWins                  userRegScript                         — whole-value REPLACE            (`a // b`)
#
# NO option has a `default`: wine-defaults defines every knob, so each is always defined by a layer — which
# means (a) no default is ever MATERIALIZED into the config (the byte-identity trap the audit flagged), and
# (b) `moduleResolve`'s output carries exactly the keys `resolveTuning` produces, no more.
{ lib, knobTypes }:
let
  t = lib.types;
  k = knobTypes;
  # A nested "<key>"."<name>" = knob map (userReg family + systemReg/userdefReg): per-key, per-name, each a
  # whole-record last-wins knob — exactly `sealing.mergeNested` over knob values.
  nestedKnob = t.attrsOf (t.attrsOf k.knob);
in
{
  options.wine = {
    d3d = lib.mkOption {
      type = k.knob;
      description = "D3D→GPU backend knob (dxvk|wined3d).";
    };
    graphics = lib.mkOption {
      type = k.knob;
      description = "wine display-driver knob (wayland|x11).";
    };

    # WINEDLLOVERRIDES as a per-DLL map; each entry a whole knob (later layer's entry replaces the DLL's knob).
    dllOverrides = lib.mkOption { type = t.attrsOf k.knob; };

    # HKCU / HKLM / HKU\.Default override maps — per-key/per-name knobs (mergeNested).
    userReg = lib.mkOption { type = nestedKnob; };
    fpsUserReg = lib.mkOption { type = nestedKnob; };
    vsyncUserReg = lib.mkOption { type = nestedKnob; };
    systemReg = lib.mkOption { type = nestedKnob; };
    userdefReg = lib.mkOption { type = nestedKnob; };

    # Staged system32 DLLs: per-DLL store-path string, whole-value last-wins (a plain `//` in sealing).
    extraSystem32 = lib.mkOption { type = t.attrsOf k.lastWins; };

    # Union+dedup lists (base-first order preserved).
    brokenVariables = lib.mkOption { type = k.dedupList t.str; };
    galaxyStubDlls = lib.mkOption { type = k.dedupList t.str; };

    # Whole-value REPLACE (sealing does not special-case these → plain `//`). NB `setupScript` is NOT
    # here: it runs in the OUTER phase before any prefix exists, so it is a top-level app option
    # (modules/app-options.nix) that the thin backends honour too.
    userRegScript = lib.mkOption { type = k.lastWins; };

    # The mount table: per-target, per-field whole-value last-wins (mergeNested over the mount records). NO
    # submodule — a submodule would materialize field defaults (mode=rw, seed=null, …) into every row and turn
    # the whole-record bind→overlay replacement into a field-merge (the KSP writable-overlay regression the
    # audit caught). `attrsOf (attrsOf lastWins)` carries exactly the authored fields.
    mounts = lib.mkOption { type = t.attrsOf (t.attrsOf k.lastWins); };
  };
}
