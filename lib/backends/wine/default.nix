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
        workingDir
        maskFiles
        saveBinds
        env
        icon
        broken
        payloads
        ;
      resolvedConfig = cfg.wine; # pre-resolved tuning (defaults layer + game + `.apply`, merged by evalModules)
      dlc = cfg.dlc.available;
      inherit enabledDlc;
    };
}
