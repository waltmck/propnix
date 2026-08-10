# Global winefex tuning defaults — the base every winefex app inherits (PLAN2 §5/§6). A per-game
# `tuning.nix` layers on top via `sealing.mergeTuning` (per-game wins; `dllOverrides` merge per-DLL), so a
# game spec states only what is SPECIFIC to it — for a well-behaved title, just `save`. Everything here is
# ALSO overridable at runtime by the matching `PROPNIX_*` env var (§5), so there are two global-override
# layers (this baked file + the launch-time env) plus the per-game layer. Each scalar knob is
# `{ value; reason; }` so a non-default choice justifies itself inline.
#
# Pure data (no `pkgs`), exposed as the scope attr `winefexDefaults` — override it to re-base all games.
{
  # D3D→GPU backend. The winefex default.
  d3d = {
    value = "dxvk";
    reason = "native ARM64EC DXVK → Vulkan measures 60 fps; wine's builtin wined3d-Vulkan present-stalls to ~12 (architectural, RESEARCH §22). Per-title override to \"wined3d\" if a title misbehaves.";
  };

  # wine display driver.
  graphics = {
    value = "wayland";
    reason = "winewayland: native fractional scaling, single native window, no Xwayland. Per-title override to \"x11\" for titles needing a correct hardware cursor or that misrender on wayland (RESEARCH §12).";
  };

  # WINEDLLOVERRIDES as a STRUCTURED DLL→load-order map (mergeable/overridable per-DLL, unlike a string;
  # the launcher composes the final `dll=order;…` string and merges the DXVK/vkd3d entries into it).
  # Load order: "n" = native, "b" = builtin, "" = disabled (n,b combinations also allowed, e.g. "n,b").
  # These three are universal wine hygiene, not per-game:
  dllOverrides = {
    mscoree = {
      value = "b";
      reason = "builtin: suppress the wine-mono install prompt without breaking .NET.";
    };
    mshtml = {
      value = "";
      reason = "disabled: drop the wine-gecko install prompt.";
    };
    "winemenubuilder.exe" = {
      value = "";
      reason = "disabled: stop wine writing its own .desktop/icon files for the app — propnix ships the launcher's.";
    };
  };

  # HKCU (user.reg) registry overrides, RE-APPLIED on every launch so they always win and update without a
  # prefix reset (wine regenerates user.reg fresh per prefix; the launcher layers these back on each time via
  # `wine reg add`). Structured like dllOverrides but two levels: "<key relative to HKCU>"."<value name>" =
  # { value; reason; type ? "REG_SZ"; }; merged per-value, so a game can add/override entries in tuning.nix.
  #
  # No defaults currently. (An earlier attempt set COLOR_WINDOW=black here to kill the ~0.5 s white flash
  # before a game's first frame, but Hollow Knight's window class has NO background brush — `bg=(nil)`, wine
  # +class trace — so wine never erases it and COLOR_WINDOW is irrelevant; the flash is the D3D swapchain's
  # first frame, not the wine window background. The mechanism is kept for genuine HKCU defaults.)
  userReg = { };
}
