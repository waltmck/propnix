# mk-app.nix — the evalModules app dispatcher (D16). A game file authors a MODULE that sets, conditionally
# on the two ORTHOGONAL axes (`fetcher` × `emulatedPlatform` — see modules/app-options.nix), everything
# about how it's packaged; `mkApp` evaluates it and dispatches to the selected backend's builder. The
# result is a real DERIVATION that also carries `.apply`/`.extend`/`.config` (Lassulus/wrappers style:
# accumulate modules → re-evaluate), promoted to the top level so `nix build`/`nix run`/`lib.getExe` work
# AND overrides chain: `hollow-knight.apply { fetcher = "steam"; emulatedPlatform = "x86_64-linux"; }`.
#
# The two REGISTRIES are scope-injected, so extending either is a scope overlay, not an edit here:
#   * `fetchers` — name → (emulatedPlatform → fetch function). Feeds the `fetcher` enum + the `payloads`
#     default (the fetch matrix); see lib/default.nix for the entries (GOG is per-platform: Galaxy for
#     Windows builds, the offline installer for Linux — D15).
#   * `backends` — name → `{ modules; build; }` (lib/backends/<name>/): each entry carries its OWN option
#     namespace (wine.*, box64.*) plus the dispatch arm. Every entry's modules are always imported (a game
#     sets wine.*/box64.* conditionally, whatever backend ends up selected); `backend` is an enum over the
#     registry, so the dispatch cannot miss.
{
  lib,
  stdenv,
  knobTypes,
  resolveStrategy,
  fetchers,
  backends,
  mkSteamOfflineEntitlement,
  gbeFork,
  propnixConfig, # the validated instantiation config (lib/default.nix): { preferredFetchers = [ … ]; }
}:
spec:
let
  appOptions = import ./modules/app-options.nix {
    inherit
      lib
      stdenv
      knobTypes
      resolveStrategy
      fetchers
      backends
      ;
    inherit (propnixConfig) preferredFetchers;
  };
  # The `steam.*` namespace + its automatic wiring (offline Steam entitlement for thin Steam games).
  steamEmu = import ./modules/steam-emu.nix {
    inherit
      lib
      knobTypes
      mkSteamOfflineEntitlement
      gbeFork
      ;
  };

  eval =
    applied:
    lib.evalModules {
      modules = [
        appOptions
        steamEmu
      ]
      ++ lib.concatMap (b: b.modules) (lib.attrValues backends)
      ++ [ spec ]
      ++ applied;
    };

  build =
    applied:
    let
      cfg = (eval applied).config;

      availableDlc = cfg.dlc.available;
      enabledDlc = map (
        n:
        availableDlc.${n}
          or (throw "propnix mkApp (${cfg.pname}): DLC '${n}' is not available for ${cfg.fetcher}/${cfg.emulatedPlatform} (available: ${lib.concatStringsSep ", " (lib.attrNames availableDlc)}).")
      ) cfg.dlc.enabled;
      executables = if cfg.executables != null then cfg.executables else [ cfg.exe ];

      # Dispatch: the selected backend's build arm. `backend` is an enum over the registry, so the lookup
      # cannot miss; an unavailable (fetcher, platform) throws from the `payloads` default when forced.
      # On wine, steam.emu's ONLY mechanism is union-replacement at a declared `.dll` libPath — enabled
      # with none declared would be a silently-inert shim (the game loads its genuine dll, every DLC reads
      # unowned), the half-wiring this framework refuses. See modules/steam-emu.nix.
      drv =
        lib.throwIf
          (
            cfg.steam.emu.enable
            && cfg.backend == "wine"
            && !(lib.any (lib.hasSuffix ".dll") cfg.steam.emu.libPaths)
          )
          "propnix mkApp (${cfg.pname}): steam.emu on the wine backend needs `steam.emu.libPaths` to name the game's shipped steam_api(64).dll (union-replacement is the only PE mechanism — there is no preload) — declare it, or set `steam.emu.enable = false`."
          (backends.${cfg.backend}.build { inherit cfg enabledDlc executables; });

      # The override surface, promoted to the top level (so `game.apply`, `lib.getExe game` work) AND
      # mirrored into passthru.
      surface = {
        config = cfg;
        apply = m: build (applied ++ [ m ]);
        extend = m: eval (applied ++ [ m ]);
        withDlc = names: build (applied ++ [ { dlc.enabled = names; } ]);
        withAllDlc = build (applied ++ [ { dlc.enabled = lib.attrNames availableDlc; } ]);
        dlc = availableDlc; # the selected (fetcher, platform)'s DLC set (name → derivation), for discovery
        # Pure resolvability probe: can the axes resolve under the current preferredFetchers? Lets a
        # consumer enumerate/build-all (`scope.resolvableGames`) without tryEval-ing full builds — an
        # unresolvable game otherwise eval-throws only when FORCED (its legible error is the desired
        # behavior for a direct `nix run`/build).
        resolvable =
          (builtins.tryEval (builtins.seq cfg.fetcher (builtins.seq cfg.emulatedPlatform true))).success;
      };
    in
    # Restrict the result to a PREDICTABLE attr spine (lib.lazyDerivation): a plain `drv // surface`
    # is strict in `drv`, so ANY attr access (even `.config` or the `resolvable` probe) would force the
    # default-combo axis resolution + backend dispatch (`backends.${cfg.backend}`) — which made the
    # tryEval in `resolvable` dead code (the throw fired before the probe could catch it) and let one
    # game's base-eval regression poison every consumer that merely enumerates the scope
    # (`resolvableGames`, the CI eval matrix). The spine below is lazy in `drv`: derivation attrs
    # (outPath/drvPath/meta/…) still force it on access — semantics there are unchanged, including the
    # meta.broken refusal — but the surface no longer does.
    lib.lazyDerivation {
      derivation = drv;
      passthru = surface // {
        # mkDerivation's top-level passthru promotion doesn't survive the fixed spine; re-expose the
        # names mkLauncherPackage guarantees (values stay lazy in drv), and passthru itself.
        inherit (drv) configFile launcher;
        passthru = (drv.passthru or { }) // surface;
      };
    };
in
build [ ]
