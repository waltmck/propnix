{
  description = "propnix — reproducible Nix packaging of proprietary games/apps (GOG, MS Store) via wine (+FEX/ARM64EC on aarch64, native on x86_64), without muvm";

  # Pinned to the exact nixpkgs 26.11 rev the preliminaries POCs built against (registry `flake:nixpkgs`),
  # so the already-built emulator closure (wine-hangover, FEX-2607 DLLs, DXVK/vkd3d, llvm-mingw) is reused
  # rather than rebuilt. Bump deliberately + re-verify (16K HK boot) per RESEARCH §22.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/9bc02893134c733dd85de46ee4fb2fac696b5529";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # aarch64-linux is the primary/tested host (wine + FEX + ARM64EC). x86_64-linux runs the SAME wine
      # source natively (no FEX); its emulator set is wired arch-aware in lib/default.nix. The x86_64 path
      # is structured + evaluates but is UNBUILT/UNTESTED so far (no x86_64 builder here).
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems f;

      # The propnix package set for a system — a lib.makeScope where callPackage wires every edge, branching
      # on the host arch for the emulator set. Memoised per system below.
      scopeFor =
        system:
        import ./lib {
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true; # proprietary payloads (allowSubstitutes=false; never public-cached)
          };
        };
      scopes = forAllSystems scopeFor;
    in
    {
      # Whole scope per system, for `nix build .#legacyPackages.<system>.<x>` and downstream reuse.
      legacyPackages = scopes;

      packages = forAllSystems (
        system:
        let
          scope = scopes.${system};
        in
        {
          inherit (scope)
            wine
            dxvk
            vkd3d
            prefixLower
            propnix-launcher
            ;
          # No `default` — a game is chosen explicitly (`.#hollow-knight`); the flake default is left blank.
        }
        // scope.games # every auto-discovered game (pkgs/games/*) exposed as `.#<name>`
        # aarch64-only: the ARM64EC toolchain + FEX/box64 emulators (absent on x86_64).
        // lib.optionalAttrs (system == "aarch64-linux") {
          inherit (scope) fexdlls llvmMingw box64;
        }
      );

      # `nix run .#hollow-knight` on either host arch — emulation handled transparently below the launcher.
      # One app per auto-discovered game (`nix run .#<name>`). No `default` — the flake default is blank.
      apps = forAllSystems (
        system:
        lib.mapAttrs (_: pkg: {
          type = "app";
          program = lib.getExe pkg;
        }) scopes.${system}.games
      );

      # Arch-agnostic helpers (pure lib / data), usable without picking a system. The arch-specific builders
      # (makeAppWine, fetchGogGalaxyBuild) live under legacyPackages.<system>.
      lib = {
        inherit (import ./lib/sealing.nix { inherit lib; })
          mkSeal
          flattenTuning
          mergeTuning
          resolveTuning
          defaultScrub
          ;
        wineDefaults = import ./lib/wine-defaults.nix;
      };

      # Host wiring: `services.propnix.enable` binds the credential dir into the build sandbox and loads
      # ntsync. Arch-agnostic; adds no game packages. See nixos/propnix.nix.
      nixosModules = rec {
        propnix = import ./nixos/propnix.nix;
        default = propnix;
      };
    };
}
