# backends/wine — the wine backend REGISTRY ENTRY (windows content; FEX/ARM64EC underneath on aarch64,
# native wine on x86_64 — the arch split lives in the scope's emulator attrs, not here). A backend entry is
# `{ modules; build; }`: the option modules mk-app always imports (every game may set `wine.*` conditionally,
# whatever backend ends up selected) plus the dispatch arm building the package from the resolved config.
#
# Everything wine lives in this directory: options.nix (the `wine.*` tuning schema), defaults.nix (the base
# tuning layer every game inherits, platform-aware), and this entry. The heavy lifting is the mkWineApp
# builder (lib/builders/wine.nix).
{
  lib,
  knobTypes,
  wineDefaults, # the applied defaults.nix: { platform, wine }: tuning defs (scope-injected — override the scope attr to re-base all games)
  mkWineApp,
  mkFallbackGl, # builders/gl-fallback.nix: the baked GL/Vulkan stack of last resort (its header has the why)
}:
{
  modules = [
    (import ./options.nix { inherit lib knobTypes; })
    # The base tuning layer, as defs of config.wine. A config-FUNCTION of the fixed point: derived mount
    # rows (galaxyStubDlls/extraSystem32 → rows) recompute against the FINAL knob values, and the d3d
    # default follows the app's emulatedPlatform. Only ever forced by this backend's build — a linux game
    # that sets no wine tuning never evaluates it.
    (
      { config, ... }:
      {
        config.wine = wineDefaults {
          platform = config.emulatedPlatform;
          wine = config.wine;
        };
      }
    )
  ];

  build =
    {
      cfg,
      enabledDlc,
      executables,
    }:
    mkWineApp {
      inherit (cfg)
        pname
        appid
        name
        exe
        exeArgs
        online
        workingDir
        maskFiles
        env
        icon
        broken
        payloads
        extraLowers
        setupScript
        ;
      # `extraBinds` is thin-only (view-relative dst; wine's binds are profile-home-relative) — refuse it
      # legibly instead of silently dropping the rows.
      saveBinds =
        lib.throwIf (cfg.extraBinds != [ ])
          "propnix (${cfg.pname}): extraBinds is thin-only (view-relative dst semantics) — express the row as `wine.mounts` on the wine backend."
          cfg.saveBinds;
      resolvedConfig = cfg.wine; # pre-resolved tuning (defaults layer + game + `.apply`, merged by evalModules)
      dlc = cfg.dlc.available;
      inherit enabledDlc;
      # gbe_fork wired in (modules/steam-emu.nix) → the launcher seats the stored account's SteamID64.
      steamEmu = cfg.steam.emu.enable;
      # The GL/Vulkan userspace of last resort — on wine it feeds winevulkan/DXVK (VK_DRIVER_FILES),
      # wined3d-GL (GLX/EGL vendor) and winewayland's gbm buffers. See builders/gl-fallback.nix.
      fallbackGl = mkFallbackGl cfg.mesa;
    };
}
