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

  eval =
    applied:
    lib.evalModules {
      modules = [
        appOptions
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
      drv = backends.${cfg.backend}.build { inherit cfg enabledDlc executables; };

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
    drv // surface // { passthru = (drv.passthru or { }) // surface; };
in
build [ ]
