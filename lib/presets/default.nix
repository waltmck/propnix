# presets — reusable wine-tuning FRAGMENTS for engine-family behaviours several games share, plus the
# combinator that composes them safely. A fragment is a plain tuning attrset (the same shape a game's
# wine-tuning.nix has); a game builds its `wine` value as
#
#   wine = presets.mergeTuning [ (import ./wine-tuning.nix) (presets.unity.framePacing "Software\\…") ];
#
# `mergeTuning` is a knob-aware deep merge that THROWS on any leaf collision — fragments must be disjoint,
# so a preset can never silently clobber a game's own entry (the failure mode a naive `//` has: it would
# replace a whole nested map like `fpsUserReg`). To OVERRIDE a preset's entry, don't merge — set the knob
# in the game's own tuning and let the module system's per-key merge do it (game layers win there).
{ lib }:
let
  # A tuning knob is `{ value; reason; … }` — merged WHOLE (never field-wise), so the collision check
  # treats it as a leaf.
  isKnob = v: builtins.isAttrs v && v ? value;

  mergeTwo =
    path: a: b:
    if builtins.isAttrs a && builtins.isAttrs b && !(isKnob a || isKnob b) then
      lib.zipAttrsWith
        (
          name: vals:
          if builtins.length vals == 1 then
            builtins.head vals
          else
            mergeTwo (path ++ [ name ]) (builtins.elemAt vals 0) (builtins.elemAt vals 1)
        )
        [
          a
          b
        ]
    else
      throw "propnix presets.mergeTuning: fragments collide at `${lib.concatStringsSep "." path}` — fragments must be disjoint (set the knob in the game's own tuning to override a preset).";
in
rec {
  # Compose disjoint tuning fragments into one tuning attrset (see the header).
  mergeTuning = lib.foldl' (mergeTwo [ ]) { };

  unity = {
    # Unity frame pacing, agreeing with the launcher's PROPNIX_FPS modes (see the fps three-state):
    # Unity persists `VidVSync` / `VidTFR` PlayerPrefs under HKCU\<key> — the value-name `_h<hash>`
    # suffixes are Unity-global constants (the deterministic hash of the pref NAME, identical across
    # games), so a fragment needs only the game's HKCU key ("Software\\<company>\\<product>").
    #   Fixed (PROPNIX_FPS > 0): DXVK caps + forces vsync OFF → engine vsync OFF (else Unity paces to
    #   vblank and fights the cap) and the engine target frame rate = the cap.
    #   VRR (PROPNIX_FPS = 0): DXVK forces vsync ON, uncapped → engine vsync ON so it presents FIFO and
    #   the display's variable refresh follows.
    framePacing = key: {
      fpsUserReg.${key} = {
        "VidVSync_h382800143" = {
          value = "0";
          type = "REG_DWORD";
          reason = "Fixed FPS: disable the engine vsync so the DXVK frame cap (DXVK_FRAME_RATE) paces, not Unity vblank sync.";
        };
        "VidTFR_h3151569246" = {
          value = "$PROPNIX_FPS";
          type = "REG_DWORD";
          reason = "Fixed FPS: set the engine target frame rate to the cap so the engine agrees with DXVK.";
        };
      };
      vsyncUserReg.${key}."VidVSync_h382800143" = {
        value = "1";
        type = "REG_DWORD";
        reason = "VRR (PROPNIX_FPS=0): enable the engine vsync so it presents FIFO and the display's variable refresh follows.";
      };
    };

    # Force fullscreen via the PERSISTED Unity PlayerPref, NOT a `-screen-fullscreen` exe arg: the CLI arg
    # is applied at startup but the game's own persisted setting then overrides it back to windowed (a
    # fullscreen window flashes and drops); setting the pref itself leaves nothing to revert to. Value 1 =
    # the Unity FullScreenMode enum FullScreenWindow (borderless fullscreen); no resolution keys are set →
    # Unity uses the native desktop resolution, keeping this host-agnostic.
    fullscreen = key: {
      userReg.${key}."Screenmanager Fullscreen mode_h3630240806" = {
        value = "1";
        type = "REG_DWORD";
        reason = "FullScreenWindow (1): a windowed Unity app on fractional-scale winewayland confines the in-game cursor to ~1/scale of the window; fullscreen fixes it. Set via the pref (not -screen-fullscreen) so the game doesn't revert it to windowed.";
      };
    };
  };
}
