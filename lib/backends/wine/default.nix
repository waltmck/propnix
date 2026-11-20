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
  strategy, # lib/strategy.nix — `runnable`, for the meta.broken contribution below
  wineDefaults, # the applied defaults.nix: { platform, wine }: tuning defs (scope-injected — override the scope attr to re-base all games)
  mkWineApp,
  mkFallbackGl, # builders/gl-fallback.nix: the baked GL/Vulkan stack of last resort (its header has the why)
  winPkgs, # the per-target Windows package set: DXVK/vkd3d for the platform's architecture (below)
  dxvk, # the host-default pair, for a platform whose target this host's set lacks (below)
  vkd3d,
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
      gamescopeScaling = cfg.gamescope;
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
      # wall (app-options documents it). Wine itself exists on both hosts; what it cannot do on x86_64 is
      # run an ARM64 Windows process (the aarch64-windows platform), and `runnable` says so — a BUILD
      # refusal, because the package must still EVALUATE (the CI matrix forces every pinned pair on both
      # systems). The same mechanism as the thin backends'.
      broken =
        let
          unrunnable = !(strategy.runnable cfg.emulatedPlatform stdenv.hostPlatform.system);
        in
        cfg.broken
        // {
          allow = cfg.allowBroken;
        }
        // lib.optionalAttrs unrunnable {
          systems = lib.unique (cfg.broken.systems ++ [ stdenv.hostPlatform.system ]);
          reason = "emulatedPlatform '${cfg.emulatedPlatform}' cannot run on ${stdenv.hostPlatform.system} — a native ARM64 Windows process needs an aarch64 host (propnix ships no ARM-on-x86 emulator). Pick a platform this host can run, or drop the explicit `.apply { emulatedPlatform = … }` and let the resolver choose.";
        };
      # `extraBinds` is thin-only (view-relative dst; wine's binds are profile-home-relative) — refuse it
      # legibly instead of silently dropping the rows.
      saveBinds =
        lib.throwIf (cfg.extraBinds != [ ])
          "propnix (${cfg.pname}): extraBinds is thin-only (view-relative dst semantics) — express the row as `wine.mounts` on the wine backend."
          cfg.saveBinds;
      exe = cfg.exe;
      # D3D translation for the PLATFORM's process architecture, never the host's: on aarch64 an x64
      # process loads the ARM64EC DXVK/vkd3d and a native ARM64 one (the aarch64-windows platform,
      # modules/unity-player.nix) the plain-ARM64 builds; on x86_64 the x86_64 builds. An i386 process
      # defaults to wined3d and loads neither; its paths are still emitted, as ever. A target this host's
      # set lacks (aarch64-windows on x86_64) takes the host pair: the package is broken there (above) and
      # the fallback only keeps the configuration evaluable.
      d3d =
        let
          t =
            if cfg.emulatedPlatform == "aarch64-windows" then
              "aarch64-windows"
            else if stdenv.hostPlatform.isAarch64 then
              "aarch64ec-windows"
            else
              "x86_64-windows";
        in
        if winPkgs ? ${t} then { inherit (winPkgs.${t}) dxvk vkd3d; } else { inherit dxvk vkd3d; };
      platform = cfg.emulatedPlatform;
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
