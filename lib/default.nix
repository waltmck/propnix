# The propnix package set — a lib.makeScope over nixpkgs, ARCH-AWARE. Each package below is a plain
# callPackage'd function whose ARGUMENT NAMES are resolved from this scope first (then from nixpkgs), so
# the inter-package edges are wired automatically. The scope branches on the host arch:
#
#   * aarch64-linux — the winefex path: Hangover wine (ARM64X-hybrid) + FEX emulator DLLs + native ARM64EC
#     DXVK/vkd3d + the ARM64EC toolchain (llvm-mingw). x86_64 Windows code runs under FEX.
#   * x86_64-linux  — the native path: the SAME wine source built for x86_64 (no arm64ec) + standard
#     x86_64 DXVK/vkd3d (nixpkgs cross builds, flattened) + NO FEX (wine runs x86_64 natively).
#
# The arch-specific bits are confined to a few emulator attrs; the builders, launcher, game specs and
# tuning are all arch-agnostic (PLAN2 §9 callPackage / §10 layout).
#
# LAYOUT (lib/):
#   mk-app.nix        the evalModules dispatcher (`.apply` override surface)
#   modules/          option schemas + the custom leaf types (types.nix)
#   backends/<name>/  one self-contained backend REGISTRY ENTRY each: option namespace + dispatch arm
#   builders/         backend-agnostic package builders (wine.nix, thin.nix, launcher-package.nix, …)
#   icons/            the icon sources (from-pe / from-png / from-unity over a shared pipeline)
#   fetchers/         the store fetchers (content-addressed FODs)
#   presets/          reusable tuning fragments (engine-family behaviours)
{
  pkgs,
  # Instantiation config, nixpkgs-style (`import propnix { pkgs; config.preferredFetchers = [ … ]; }`).
  # PURE eval input only — nothing here (or anywhere at eval) probes /propnix credentials; a mis-stated
  # config still fails at FOD-fetch time exactly as an absent account does today. Recognized keys:
  #   preferredFetchers : [ str ] — ranked ALLOWLIST of store fetchers, decreasing preference (see
  #                       `propnixConfig` below). Default = every registered fetcher, registry order —
  #                       i.e. "no account statement made".
  config ? { },
}:
let
  lib = pkgs.lib;
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;
  # A substitutable x86_64-linux nixpkgs, for the box64 GUEST library set (§7/D7): the x86_64 copies of the
  # sonames the emulated process needs. On an x86_64 host this IS `pkgs`; on aarch64 it's a second, native
  # x86_64 instantiation of the SAME pinned nixpkgs (Hydra-substitutable .so closures — NEVER pkgsCross,
  # whose outputs aren't cached). Only ever a build-time DEPENDENCY; every derivation stays host-arch.
  pkgsX86 =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      pkgs
    else
      import pkgs.path {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
  # Auto-discovered games: each subdir of ../pkgs/games holds one arch-agnostic game spec (default.nix).
  gamesDir = ../pkgs/games;
  gameNames = builtins.attrNames (
    lib.filterAttrs (_: t: t == "directory") (builtins.readDir gamesDir)
  );
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
    gbeFork = callPackage ../emulators/gbe-fork.nix { }; # prebuilt guest-x86_64 Steam-API reimplementation (the steam-emu shim)
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
    # The launcher LINKS the mount + prefetch helpers as library crates (path deps), so it's the single
    # build; propnix-mount / propnix-prefetch are no longer separate packages.
    propnix-launcher = callPackage ../pkgs/propnix-launcher { }; # per-app launcher (splash + seal + in-process mount/prefetch + orchestration)
    propnix-cli = callPackage ../pkgs/propnix-cli { }; # the `propnix` CLI (cred management + `propnix pin` re-pinning)

    # ── the module system (D16) ──
    sealing = import ./sealing.nix { inherit (pkgs) lib; }; # §7 env-seal data model + tuning flatten (pure lib)
    knobTypes = import ./modules/types.nix { inherit lib; }; # custom leaf option types (knob / lastWins / dedupList)
    inherit (import ./strategy.nix { inherit lib; }) resolveStrategy; # pure backend selection (D4)
    presets = import ./presets { inherit lib; }; # reusable tuning fragments (unity.*) + mergeTuning

    # The FETCHER REGISTRY: fetcher name → (emulatedPlatform → fetch function). Feeds mkApp's `fetcher`
    # enum + the fetch matrix. GOG is PER-PLATFORM (D15): the Galaxy content system pins Windows builds by
    # buildId but has NO Linux builds, so a GOG Linux build comes from the (latest-only) offline installer.
    fetchers = {
      gog =
        platform: if lib.hasSuffix "-linux" platform then fetchGogLinuxInstaller else fetchGogGalaxyBuild;
      steam = _platform: fetchSteamDepot;
    };

    # The NORMALIZED instantiation config every game resolves against. Validation lives IN the scope (not
    # at import) deliberately: it checks against the FINAL (post-overlay) fetcher registry — an overlay
    # that adds a fetcher can be named in the list — and it re-runs for
    # `scope.overrideScope (final: prev: { propnixConfig.preferredFetchers = …; })`, which re-instantiates
    # every game under the new preference (makeScope semantics). Lazy per-force: a bad config surfaces at
    # the first forced game with a legible error, and non-game scope members stay evaluable.
    #
    # `preferredFetchers` is a ranked ALLOWLIST (decreasing preference): the resolver defaults in
    # modules/app-options.nix select the first listed fetcher that pins the game's platform, and — the A′
    # rule — may walk DOWN the game's own `platformPreference` ranking when a higher-ranked platform is
    # unreachable with the listed fetchers (the game sanctions every fallback; nothing outside its ranking
    # is ever selected). The list shapes DEFAULTS, it is not a sandbox: an explicit
    # `.apply { fetcher = …; }` (or a game's own deliberate `fetcher = lib.mkDefault …` quality exception)
    # still wins.
    propnixConfig = {
      preferredFetchers =
        let
          registered = lib.attrNames self.fetchers;
          raw = config.preferredFetchers or registered; # default: every fetcher, registry order = no account statement
          unknown = lib.subtractLists registered raw;
        in
        lib.throwIf (raw == [ ])
          "propnix: config.preferredFetchers must not be empty (registered fetchers: ${toString registered})"
          (
            lib.throwIfNot (unknown == [ ])
              "propnix: unknown fetcher(s) in config.preferredFetchers: ${toString unknown} (registered: ${toString registered})"
              (
                lib.throwIfNot (
                  lib.unique raw == raw
                ) "propnix: config.preferredFetchers contains duplicates: ${toString raw}" raw
              )
          );
    };

    # The BACKEND REGISTRY: backend name → { modules; build; } (lib/backends/<name>/ — each entry carries
    # its own option namespace + dispatch arm). `native` is the x86_64 face of the box64 entry (the entry
    # itself decides emulator-vs-direct-exec by host arch); it re-uses the build with NO modules so the
    # shared `box64.*` options aren't declared twice.
    backends =
      let
        box64Entry = callPackage ./backends/box64 { inherit pkgs pkgsX86; };
      in
      {
        wine = callPackage ./backends/wine { };
        box64 = box64Entry;
        native = {
          modules = [ ];
          build = box64Entry.build;
        };
        fex = callPackage ./backends/fex { inherit pkgsX86; }; # research/meta.broken on 16K; `.apply { backend = "fex"; }`
      };

    mkApp = callPackage ./mk-app.nix { }; # the evalModules app dispatcher + `.apply` override surface

    # ── builders (backend-agnostic packaging) ──
    mkWineApp = callPackage ./builders/wine.nix { }; # resolved config → package (wine PREFIX mode)
    mkThinApp = callPackage ./builders/thin.nix { }; # resolved config + launch block → package (THIN mode)
    mkThinBuild = callPackage ./backends/mk-thin-build.nix { }; # shared thin dispatch-arm assembler (block contract check)
    mkLauncherPackage = callPackage ./builders/launcher-package.nix { }; # the shared packaging tail (wrapper + .desktop + meta)
    mkDesktopItem = callPackage ./builders/desktop-item.nix { }; # §5 .desktop + symbolic icon
    mkStoreSkeleton = callPackage ./builders/store-skeleton.nix { }; # data-only overlay skeleton (sparse stubs+xattrs → tar)
    mkWineReg = callPackage ./builders/wine-reg.nix { }; # declarative per-game reg hive (wine-gen base + overrides)
    mkSetupScript = callPackage ./builders/setup-script.nix { }; # setup.sh wrapper (pinned PATH + pipefail + ini-lib)
    # Offline entitlement answers for a Steam engine that asks the (absent) Steam client whether the
    # owner's already-decrypted DLC is owned: the guest-arch gbe_fork shim (a COPY, so its
    # beside-the-library settings probe resolves here) + the generated settings tree it reads.
    mkSteamOfflineEntitlement = callPackage ./builders/steam-offline-entitlement.nix { };
    wineDefaults = callPackage ./backends/wine/defaults.nix { }; # the base wine tuning layer; override to re-base all games

    # ── icons ── three SOURCES, one output layout (hicolor theme + share/propnix/<id>.png splash):
    extractPeIcon = callPackage ./icons/from-pe.nix { }; # a Windows exe's PE resources, at their true sizes
    mkAppIcon = callPackage ./icons/from-png.nix { }; # a high-res raster from the game data (autocrop + recentre)
    extractUnityIcon = callPackage ./icons/from-unity.nix { }; # a Unity Linux build's UnityPlayer.png

    # ── fetchers (content-addressed FODs) ──
    fetchGogGalaxyBuild = callPackage ./fetchers/fetchGogGalaxyBuild { }; # GOG Galaxy depot (propnix download; buildId-pinned)
    fetchGogLinuxInstaller = callPackage ./fetchers/fetchGogLinuxInstaller.nix { }; # GOG Linux offline installer (lgogdownloader; latest-only)
    fetchSteamDepot = callPackage ./fetchers/fetchSteamDepot.nix { }; # Steam SteamPipe depot (propnix download; manifest-pinned, permanently reproducible)

    # The GUEST nixpkgs (D7): x86_64 on every host — a second native instantiation on aarch64, `pkgs` itself
    # on x86_64. Exposed so a game can build a derivation that must be the EMULATED arch (a library loaded
    # into the guest process), not just list one via `box64.guestLibs`.
    pkgsGuest = pkgsX86;

    # ── games ── auto-discovered from ../pkgs/games/*: drop a pkgs/games/<name>/default.nix and it becomes
    #    scope.<name> + a flake package/app — no wiring here. `games` groups them for the flake to enumerate.
    inherit games;
    # The subset whose axes RESOLVE under this scope's preferredFetchers (pure eval probe, no payload
    # forced) — for consumers that enumerate/build everything under a restrictive config.
    resolvableGames = lib.filterAttrs (_: g: g.resolvable) games;
  }
  // games # spread each game top-level as scope.<name> (so `inherit (scope) <name>` + cross-refs resolve)
  # ── aarch64-only: the ARM64EC toolchain + FEX/box64 emulators. Absent on x86_64, where wine is native,
  #    so `prefixLower`'s `fexdlls ? null` default applies and nothing references llvm-mingw. ──
  // pkgs.lib.optionalAttrs isAarch64 {
    # THE ARM64EC TOOLCHAIN, in two pieces. `llvmMingwPrebuilt` is mstorsjo's stable 20260616 release
    # (clang 22.1.8) as shipped; `llvmMingwPatched` grafts onto it a clang built from the SAME commit with
    # llvm/llvm-project#190933 — the ARM64EC variadic exit-thunk fix, without which every `[out]` context
    # handle is corrupted and no Windows installer can register a service (RESEARCH §23).
    #
    # Only the compiler is rebuilt; the mingw sysroots, libc++ 22 and compiler-rt builtins stay exactly as
    # upstream shipped them. The alternative — pinning 20260812 (clang 23.1.0-rc3), the only release
    # carrying the fix — was implemented, measured and rejected: libc++ 23 drops transitive includes and
    # needs a patch per third-party source, and it hard-blocks fex-dlls outright. `llvmMingw` is what every
    # consumer in this scope resolves, so nothing can accidentally build against the unpatched base.
    llvmMingwPrebuilt = callPackage ../emulators/llvm-mingw { };
    llvmMingwPatched = callPackage ../emulators/llvm-mingw/patched-22.nix {
      prebuilt = llvmMingwPrebuilt;
    };
    llvmMingw = llvmMingwPatched;
    fexdlls = callPackage ../emulators/fex { }; # FEX-2607 from source + ./patches (+ box64 wowbox64)

    # FEXInterpreter — the LINUX x86_64-on-aarch64 emulator for the THIN FEX backend (distinct from
    # fexdlls, the Windows/ARM64EC DLLs wine loads). The thin FEX path is research/meta.broken on 16K.
    fexInterpreter = pkgs.fex;
    # Graceful no-op GOG Galaxy SDK DLLs (Galaxy64/Galaxy/pops_api): bound over a game's bundled copies so a
    # statically-imported online SDK never reaches GOG's services — propnix games run fully offline, the
    # same policy as masking Steam's steam_api64.dll (winefex path; x86_64 = native wine, no stub).
    galaxyStub = callPackage ../emulators/galaxy-stub { }; # uses llvmMingw
    # box64 re-export: pass nixpkgs' box64 explicitly (else callPackage resolves `box64` from this scope →
    # itself → infinite recursion).
    box64 = callPackage ../emulators/box64-latest.nix { box64 = pkgs.box64; };
  }
)
