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
  stdenv, # host arch only — whether an x86 EMULATOR is in the prefix at all (see the x87 env below)
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
        exeArgs
        online
        workingDir
        maskFiles
        icon
        maintainers
        payloads
        extraLowers
        setupScript
        ;
      # x87 PRECISION, in both emulators' spellings. Unlike the thin backends, a wine prefix does not know
      # in advance WHICH x86 emulator will be loaded: an x86_64 guest runs on FEX's ARM64EC DLLs and an
      # i386 one on box64's wowbox64 (Hangover loads it by that hardcoded name — see
      # emulators/wine-prefix-lower.nix), and box64 documents BOX64_X87_NO80BITS as honoured there too. So
      # state both; each emulator reads its own and ignores the other. The 32-bit case is the one that
      # pays — that guest computes FP in the x87 stack, exactly like the i386 Linux payload where this was
      # measured (app-options `x87ReducedPrecision` carries the numbers).
      #
      # aarch64 ONLY: on an x86_64 host wine runs the guest natively with no emulator in the path, so
      # there is no x87 being emulated and these would be inert vars in the prefix's environment.
      #
      # The game's own `env` merges OVER these, so a per-title override still wins — but the knob is the
      # documented way, and it reaches every backend at once.
      env =
        lib.optionalAttrs stdenv.hostPlatform.isAarch64 {
          FEX_X87REDUCEDPRECISION = if cfg.x87ReducedPrecision then "1" else "0";
          BOX64_X87_NO80BITS = if cfg.x87ReducedPrecision then "1" else "0";
        }
        // cfg.env;
      # The app's `broken` record plus the caller's escape hatch, which mkLauncherPackage reads as the
      # third field: `allowBroken` suppresses the meta.broken refusal for a deliberate test of a known
      # wall (app-options documents it). Wine contributes no brokenness of its own — it is the one
      # backend that exists on both hosts — so the record passes through otherwise unchanged.
      broken = cfg.broken // {
        allow = cfg.allowBroken;
      };
      # `extraBinds` is thin-only (view-relative dst; wine's binds are profile-home-relative) — refuse it
      # legibly instead of silently dropping the rows.
      saveBinds =
        lib.throwIf (cfg.extraBinds != [ ])
          "propnix (${cfg.pname}): extraBinds is thin-only (view-relative dst semantics) — express the row as `wine.mounts` on the wine backend."
          cfg.saveBinds;
      exe = cfg.exe;
      resolvedConfig = cfg.wine; # pre-resolved tuning (defaults layer + game + `.apply`, merged by evalModules)
      dlc = cfg.dlc.available;
      inherit enabledDlc;
      # gbe_fork wired in (modules/steam-emu.nix); informational for the launcher.
      steamEmu = cfg.steam.emu.enable;
      # The GL/Vulkan userspace of last resort — on wine it feeds winevulkan/DXVK (VK_DRIVER_FILES),
      # wined3d-GL (GLX/EGL vendor) and winewayland's gbm buffers. See builders/gl-fallback.nix.
      fallbackGl = mkFallbackGl cfg.mesa;
    };
}
