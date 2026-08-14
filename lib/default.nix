# The propnix package set — a lib.makeScope over nixpkgs, ARCH-AWARE. Each package below is a plain
# callPackage'd function whose ARGUMENT NAMES are resolved from this scope first (then from nixpkgs), so
# the inter-package edges are wired automatically. The scope branches on the host arch:
#
#   * aarch64-linux — the winefex path: Hangover wine (ARM64X-hybrid) + FEX emulator DLLs + native ARM64EC
#     DXVK/vkd3d + the ARM64EC toolchain (llvm-mingw). x86_64 Windows code runs under FEX.
#   * x86_64-linux  — the native path: the SAME wine source built for x86_64 (no arm64ec) + standard
#     x86_64 DXVK/vkd3d (nixpkgs cross builds, flattened) + NO FEX (wine runs x86_64 natively).
#
# The arch-specific bits are confined to a few emulator attrs; makeAppWine, the launcher, the game specs
# and tuning are all arch-agnostic (PLAN2 §9 callPackage / §10 layout).
{ pkgs }:
let
  lib = pkgs.lib;
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;
  # Auto-discovered games: each subdir of ../pkgs/games holds one arch-agnostic game spec (default.nix).
  gamesDir = ../pkgs/games;
  gameNames = builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir gamesDir));
in
pkgs.lib.makeScope pkgs.newScope (
  self:
  with self;
  let
    # callPackage each discovered game dir; the scope injects the arch-appropriate emulator set.
    games = lib.genAttrs gameNames (name: callPackage (gamesDir + "/${name}") { });
  in
  {
    # ── wine + graphics (arch-aware INTERNALLY: same source, arch-appropriate archs/DLL flavor) ──
    wine = callPackage ../emulators/wine-hangover { }; # Hangover fork; arm64ec archs on aarch64, plain on x86_64
    prefixLower = callPackage ../emulators/wine-prefix-lower.nix { }; # RO system tree; FEX DLLs only on aarch64 (fexdlls ? null)
    dxvk =
      if isAarch64 then
        callPackage ../emulators/dxvk-arm64ec.nix { } # native ARM64EC PE
      else
        callPackage ../emulators/dxvk-x86_64.nix { dxvk = pkgs.dxvk; }; # nixpkgs mingwW64 PE, flattened
    vkd3d =
      if isAarch64 then
        callPackage ../emulators/vkd3d-proton-arm64ec.nix { }
      else
        callPackage ../emulators/vkd3d-proton-x86_64.nix { };

    # ── propnix tools (Rust; arch-agnostic — built for the host arch from the same source) ──
    # The launcher LINKS the mount + prefetch helpers as library crates (path deps), so it's the single build;
    # propnix-mount / propnix-prefetch are no longer separate packages.
    propnix-launcher = callPackage ../pkgs/propnix-launcher { }; # per-app launcher (splash + seal + in-process mount/prefetch + orchestration)

    # ── lib helpers (arch-agnostic) ──
    sealing = import ./sealing.nix { inherit (pkgs) lib; }; # §7 env-seal data model (pure lib, not a derivation)
    wineDefaults = import ./wine-defaults.nix; # global tuning base every game inherits (§5/§6)
    mkPropnixDesktopItem = callPackage ./desktop-item.nix { }; # §5 .desktop + symbolic icon
    extractPeIcon = callPackage ./extract-pe-icon.nix { }; # PE .exe icon → freedesktop hicolor theme
    fetchGogGalaxyBuild = callPackage ./fetchers/fetchGogGalaxyBuild { }; # GOG Galaxy depot FOD (gogdl; arch-independent NAR)
    mkStoreSkeleton = callPackage ./mkStoreSkeleton.nix { }; # data-only overlay skeleton (sparse stubs+xattrs → tar)
    mkWineReg = callPackage ./mkWineReg.nix { }; # declarative per-game reg hive (wine-gen base + overrides)
    makeAppWine = callPackage ./makeAppWine.nix { }; # §4 wrapper: spec -> package invoking the launcher

    # ── games ── auto-discovered from ../pkgs/games/*: drop a pkgs/games/<name>/default.nix and it becomes
    #    scope.<name> + a flake package/app — no wiring here. `games` groups them for the flake to enumerate.
    inherit games;
  }
  // games # spread each game top-level as scope.<name> (so `inherit (scope) <name>` + cross-refs resolve)
  # ── aarch64-only: the ARM64EC toolchain + FEX/box64 emulators. Absent on x86_64, where wine is native,
  #    so `prefixLower`'s `fexdlls ? null` default applies and nothing references llvm-mingw. ──
  // pkgs.lib.optionalAttrs isAarch64 {
    llvmMingw = callPackage ../emulators/llvm-mingw { }; # shared mstorsjo toolchain (arm64ec + reindex fix)
    fexdlls = callPackage ../emulators/fex-dlls.nix { }; # FEX-2607 from source (+ box64 wowbox64); uses llvmMingw
    # Graceful no-op GOG Galaxy SDK DLLs (Galaxy64/Galaxy/pops_api). makeAppWine swaps a game's bundled
    # copies for these so the SDK's offline RPC init can't fault wine's rpcrt4 (winefex path; x86_64 = native).
    galaxyStub = callPackage ../emulators/galaxy-stub { }; # uses llvmMingw
    # box64 re-export: pass nixpkgs' box64 explicitly (else callPackage resolves `box64` from this scope →
    # itself → infinite recursion). Unused this pass; carried for the box64 backlog.
    box64 = callPackage ../emulators/box64-latest.nix { box64 = pkgs.box64; };
  }
)
