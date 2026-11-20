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
  # The 32-bit (i386) sibling of pkgsX86, for a payload whose ABI is i386-linux — the FEX thin backend's
  # guest set on aarch64, and the library set + PT_INTERP loader a 32-bit payload needs on the native face
  # of an x86_64 host. Each host takes the route that is BUILDABLE THERE WITHOUT EMULATION:
  #   * x86_64 — `pkgsi686Linux`, nixpkgs' own 32-bit set. An x86_64 CPU executes i686 directly, so this is
  #     a NATIVE instantiation that Hydra builds and caches; no cross, no binfmt.
  #   * aarch64 — `pkgsCross.gnu32`, CROSS-compiled from the host. Deliberately NOT
  #     `import pkgs.path { system = "i686-linux"; }`: that is a foreign-arch native instantiation, so
  #     every uncached path would build under qemu binfmt (slowly, on this host) and the whole set would be
  #     unbuildable the moment a substituter is unavailable. pkgsX86 above takes that route because its
  #     x86_64 closures ARE reliably Hydra-cached; an i686 set on aarch64 is not.
  pkgsGuest32 =
    if pkgs.stdenv.hostPlatform.isx86_64 then pkgs.pkgsi686Linux else pkgs.pkgsCross.gnu32;
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
    # Per-ABI Steam-API reimplementation (the steam-emu shim): Linux from source, Windows PE prebuilt. The
    # mingw args serve ONLY its lazy `steamStubProxy` passthru (a from-source PE for SteamStub-wrapped
    # exes) and follow galaxyStub's toolchain split verbatim — llvm-mingw on aarch64, nixpkgs' cached
    # cross-GCC on x86_64, where that prebuilt does not exist. Nothing is forced unless a game sets
    # `steam.emu.steamStub`.
    gbeFork = callPackage ../emulators/gbe-fork {
      inherit pkgs;
      llvmMingw = if isAarch64 then llvmMingw else null;
      mingwGccW64 = pkgs.pkgsCross.mingwW64.stdenv.cc;
      mingwGcc32 = pkgs.pkgsCross.mingw32.stdenv.cc;
      mingwThreads64 = pkgs.pkgsCross.mingwW64.windows.mcfgthreads;
      mingwThreads32 = pkgs.pkgsCross.mingw32.windows.mcfgthreads;
    };
    # The .NET CLR every MANAGED (pure .NET) Windows title needs before it can execute a single
    # instruction. ARCH-AGNOSTIC: one package serves both hosts (its header explains why the x86-family
    # tarball is the right — and only — choice on aarch64 too). Wired into `prefixLower` by argument name.
    # Hybrid: upstream's release tarball for the class libraries, x86_64 runtime rebuilt from source with
    # emulators/wine-mono/patches (the native→managed callback fix managed titles need on ARM64EC+FEX).
    wineMono = callPackage ../emulators/wine-mono {
      mingwGccW64 = pkgs.pkgsCross.mingwW64.stdenv.cc;
      llvmMingw = if isAarch64 then llvmMingw else null; # aarch64: the x64 runtime slot gets an ARM64EC build
    };
    prefixLower = callPackage ../emulators/wine-prefix-lower.nix { }; # RO system tree; FEX DLLs only on aarch64 (fexdlls ? null); CLR from wineMono
    # ── Windows PE packages, PER TARGET PLATFORM: `winPkgs.<target>.<pkg>` is the same expression
    #    instantiated with that target's cross toolchain (lib/win-toolchain.nix has the vocabulary —
    #    x86_64-windows / i386-windows / aarch64-windows / aarch64ec-windows — and the per-host toolchain
    #    split). A consumer indexes the set by the PROCESS platform it serves, which is the game's own
    #    arch today and the native ARM64 player's when lib/modules/unity-player.nix swaps the engine.
    #    Targets this host cannot produce (the ARM ones on x86_64) are absent; a package with no build for
    #    a target is null there. The aliases below are the host's default-process-target views, which
    #    every existing consumer and CI attr reads.
    winToolchains = import ./win-toolchain.nix {
      inherit lib pkgs;
      llvmMingw = if isAarch64 then llvmMingw else null;
    };
    winPkgs = lib.mapAttrs (
      target: toolchain:
      lib.makeScope pkgs.newScope (ws: {
        inherit target toolchain;
        # Graceful no-op GOG Galaxy SDK stubs: every target, since the stub matches the importing process.
        galaxyStub = ws.callPackage ../emulators/galaxy-stub { };
        # DXVK / vkd3d-proton: the ARM targets from source with llvm-mingw; x86_64 as nixpkgs' mingwW64
        # build, flattened — on x86_64 hosts only, the one place that process target is served (a
        # cross-build of it on aarch64 would be a derivation no job caches, for a process this host never
        # runs natively).
        dxvk =
          if lib.hasPrefix "aarch64" target then
            ws.callPackage ../emulators/dxvk-llvm-mingw.nix { }
          else if target == "x86_64-windows" && !isAarch64 then
            callPackage ../emulators/dxvk-x86_64.nix { dxvk = pkgs.dxvk; }
          else
            null;
        vkd3d =
          if lib.hasPrefix "aarch64" target then
            ws.callPackage ../emulators/vkd3d-proton-llvm-mingw.nix { }
          else if target == "x86_64-windows" && !isAarch64 then
            callPackage ../emulators/vkd3d-proton-x86_64.nix { }
          else
            null;
        # Unity's Mono runtime (`mono-2.0-bdwgc.dll`), one build per Unity stream, for the ARM targets:
        # ARM64EC replaces the shipped x64 runtime under wine+FEX (lib/modules/unity-mono.nix), plain
        # ARM64 serves the native player. The x64 runtime is what games ship.
        unityMono = if lib.hasPrefix "aarch64" target then ws.callPackage ../emulators/unity-mono { } else null;
        # gbe_fork's Windows Steam-API shim: upstream's prebuilt release for the x86 targets
        # (`share/gbe_fork/win/{x64,x86}/`, the layout lib/modules/steam-emu.nix indexes).
        # The Steam shim: upstream's prebuilt x64/x86 PEs for the x86 targets (emulators/gbe-fork,
        # `winPrebuilt`), and for plain ARM64 — which upstream ships no release for — the from-source twin of
        # the Linux shims (shim-win.nix), its libraries built static for the target (win-deps.nix). ARM64EC
        # has none: the hybrid stack runs x64 games, whose loader takes the x64 prebuilt.
        gbeFork =
          if target == "x86_64-windows" || target == "i386-windows" then
            gbeFork.winPrebuilt
          else if target == "aarch64-windows" then
            ws.callPackage ../emulators/gbe-fork/shim-win.nix {
              inherit (gbeFork.linuxShims.${if isAarch64 then "aarch64" else "x64"}) src version libssq;
              winDeps = ws.callPackage ../emulators/gbe-fork/win-deps.nix { };
              winPrebuilt = gbeFork.winPrebuilt;
            }
          else
            null;
      })
    ) (lib.filterAttrs (_: t: t != null) winToolchains);
    # The host's default process target for a Windows game's D3D layer: the hybrid ARM64EC DLLs beside the
    # x64 game under wine+FEX on aarch64, nixpkgs' x64 DLLs on x86_64.
    unityMono = winPkgs."aarch64ec-windows".unityMono or null;
    # Unity's own native ARM64 Windows player per Unity version (emulators/unity-player; unfree, never
    # cached) — what lib/modules/unity-player.nix swaps a title's x64 player for. Pure evaluation on every
    # host; only an aarch64 wine build of an enabled title references a player.
    unityPlayer = callPackage ../emulators/unity-player { };
    dxvk = winPkgs.${if isAarch64 then "aarch64ec-windows" else "x86_64-windows"}.dxvk;
    vkd3d = winPkgs.${if isAarch64 then "aarch64ec-windows" else "x86_64-windows"}.vkd3d;
    # The nested compositor every game runs inside (both arches, native), with its WSI layer in the same
    # output. Pass nixpkgs' gamescope explicitly (else callPackage resolves `gamescope` from this scope →
    # itself → infinite recursion).
    gamescope = callPackage ../emulators/gamescope { gamescope = pkgs.gamescope; };
    # gamescope's PROPNIX_BENCH overlay (`mangoapp`), with FEX's stats on aarch64. nixpkgs' passed explicitly
    # for the same reason as gamescope's.
    mangohud =
      if isAarch64 then
        callPackage ../emulators/mangohud.nix { mangohud = pkgs.mangohud; }
      else
        pkgs.mangohud;

    # ── propnix tools (Rust; arch-agnostic — built for the host arch from the same source) ──
    # The launcher LINKS the mount + prefetch helpers as library crates (path deps), so it's the single
    # build.
    propnix-launcher = callPackage ../pkgs/propnix-launcher { }; # per-app launcher (splash + seal + in-process mount/prefetch + orchestration)
    propnix-cli = callPackage ../pkgs/propnix-cli { }; # the `propnix` CLI (cred management + `propnix pin` re-pinning)

    # ── the module system (D16) ──
    sealing = import ./sealing.nix { inherit (pkgs) lib; }; # §7 env-seal data model + tuning flatten (pure lib)
    knobTypes = import ./modules/types.nix { inherit lib; }; # custom leaf option types (knob / lastWins / dedupList)
    # The platform axis + pure backend selection (D4): `platforms`, `platformToNeed`, `resolveStrategy`,
    # `runnable`. Exposed as ONE attr rather than spread into the scope — `platforms`/`runnable` are names
    # a callPackage'd package could plausibly want for something else.
    strategy = import ./strategy.nix { inherit lib; };
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
    # its own option namespace + dispatch arm). `native` is the direct-exec face of the box64 entry (the
    # entry decides emulator-vs-direct-exec from `cfg.backend` — i.e. from the PAYLOAD's arch against the
    # host's, not from the host alone); it re-uses the build with NO modules so the shared `box64.*`
    # options aren't declared twice.
    backends =
      let
        box64Entry = callPackage ./backends/box64 { inherit pkgs pkgsX86 pkgsGuest32; };
      in
      {
        wine = callPackage ./backends/wine { };
        box64 = box64Entry;
        native = {
          modules = [ ];
          build = box64Entry.build;
        };
        # The aarch64 emulator for x86 LINUX content of either width; resolveStrategy routes i386-linux
        # here (box64 is x86_64-only) and an x86_64-linux payload only via `.apply { backend = "fex"; }`.
        fex = callPackage ./backends/fex { inherit pkgsX86 pkgsGuest32; };
      };

    mkApp = callPackage ./mk-app.nix { }; # the evalModules app dispatcher + `.apply` override surface

    # ── builders (backend-agnostic packaging) ──
    mkWineApp = callPackage ./builders/wine.nix { }; # resolved config → package (wine PREFIX mode)
    mkThinApp = callPackage ./builders/thin.nix { }; # resolved config + launch block → package (THIN mode)
    mkThinBuild = callPackage ./backends/mk-thin-build.nix { }; # shared thin dispatch-arm assembler (block contract check)
    mkLauncherPackage = callPackage ./builders/launcher-package.nix { }; # the shared packaging tail (wrapper + .desktop + meta)
    mkDesktopItem = callPackage ./builders/desktop-item.nix { }; # §5 .desktop + symbolic icon
    mkStoreSkeleton = callPackage ./builders/store-skeleton.nix { }; # data-only overlay skeleton (sparse stubs+xattrs → tar)
    mkPatchedExes = callPackage ./builders/patched-exes.nix { }; # +x (and PT_INTERP-stamped) exe overlay for the execve'ing thin backends
    mkWineReg = callPackage ./builders/wine-reg.nix { }; # declarative per-game reg hive (wine-gen base + overrides)
    mkSetupScript = callPackage ./builders/setup-script.nix { }; # setup.sh wrapper (pinned PATH + pipefail + ini-lib)
    # Offline entitlement answers for a Steam engine that asks the (absent) Steam client whether the
    # owner's already-decrypted DLC is owned: the payload-ABI gbe_fork shim (a COPY, so its
    # beside-the-library settings probe resolves here) + the generated settings tree it reads.
    mkSteamOfflineEntitlement = callPackage ./builders/steam-offline-entitlement.nix { };
    # The game-dir tree carrying a stream's ARM64EC Unity runtime over the payload (unityMono above),
    # checked against the payload's own player at build time; lib/modules/unity-mono.nix's output.
    mkUnityMonoTree = callPackage ./builders/unity-mono-tree.nix { };
    # Its native-player sibling: the tree carrying Unity's ARM64 player, our ARM64 runtime and the
    # declared ARM64 plugins over the payload (unityPlayer above); lib/modules/unity-player.nix's output.
    mkUnityPlayerTree = callPackage ./builders/unity-player-tree.nix { };
    # The baked GL/Vulkan fallback stack (mesa + discovery paths) both backends hand the launcher; takes
    # the app's `mesa` knob (null → nixpkgs mesa as a fallback; a derivation → forced). See its header.
    mkFallbackGl = callPackage ./builders/gl-fallback.nix { };
    # The base wine tuning layer; override to re-base all games. The Galaxy stub trees per PE target, so a
    # row binds the stub of the PROCESS that imports it (winPkgs above).
    wineDefaults = callPackage ./backends/wine/defaults.nix {
      galaxyStubs = lib.mapAttrs (_: s: s.galaxyStub) winPkgs;
    };

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
    # Its 32-bit sibling, for an i386-linux payload (see the `let` above for why the two hosts resolve it
    # differently). Same purpose: a game that must build a derivation in the GUEST's ABI.
    inherit pkgsGuest32;

    # ── games ── auto-discovered from ../pkgs/games/*: drop a pkgs/games/<name>/default.nix and it becomes
    #    scope.<name> + a flake package/app — no wiring here. `games` groups them for the flake to enumerate.
    inherit games;
    # The subset whose axes RESOLVE under this scope's preferredFetchers (pure eval probe, no payload
    # forced) — for consumers that enumerate/build everything under a restrictive config.
    resolvableGames = lib.filterAttrs (_: g: g.resolvable) games;

    # Graceful no-op GOG Galaxy SDK DLLs (Galaxy64/Galaxy/pops_api), bound over a game's bundled copies so a
    # statically-imported online SDK never reaches GOG's services — the same offline policy as masking
    # Steam's steam_api64.dll. The x86 games' view: the x86_64 and i386 targets' stubs joined into one tree
    # (`Galaxy64.dll`, `pops_api.dll`, `Galaxy.dll`), which both hosts build (emulators/galaxy-stub for the
    # whole argument). A native ARM64 process reads `winPkgs.aarch64-windows.galaxyStub` instead.
    galaxyStub = pkgs.symlinkJoin {
      name = "galaxy-stub";
      paths = [
        winPkgs."x86_64-windows".galaxyStub
        winPkgs."i386-windows".galaxyStub
      ];
      meta.description = "Graceful no-op GOG Galaxy SDK stubs (Galaxy64.dll/Galaxy.dll/pops_api.dll) for wine";
    };
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
    # Only the compiler is rebuilt; the mingw sysroots, libc++ 22 and compiler-rt builtins stay
    # exactly as upstream shipped them. `llvmMingw` is what every consumer in this scope resolves,
    # so nothing can accidentally build against the unpatched base. Why a backport onto 22 rather
    # than the clang-23 release that carries the fix: docs/research/llvm-mingw-toolchain.md.
    llvmMingwPrebuilt = callPackage ../emulators/llvm-mingw { };
    llvmMingwPatched = callPackage ../emulators/llvm-mingw/patched-22.nix {
      prebuilt = llvmMingwPrebuilt;
    };
    llvmMingw = llvmMingwPatched;
    fexdlls = callPackage ../emulators/fex { }; # FEX-2611 from source + ./patches (+ box64 wowbox64)

    # FEXInterpreter — the LINUX x86_64/i386-on-aarch64 emulator for the THIN FEX backend (distinct from
    # fexdlls, the Windows/ARM64EC DLLs wine loads).
    #
    # OURS, not nixpkgs': stock FEX >= 2508 hard-requires a 4 KiB kernel page and does not start at all on
    # this 16 KiB host — its bundled jemalloc refuses before any guest runs. emulators/fex-linux carries
    # the large-host-page work plus the two 32-bit-guest fixes that make i386 guests usable, which is what
    # pkgs/games/civilization-5 runs on.
    fexInterpreter = callPackage ../emulators/fex-linux { };
    # box64 re-export: pass nixpkgs' box64 explicitly (else callPackage resolves `box64` from this scope →
    # itself → infinite recursion).
    box64 = callPackage ../emulators/box64-latest.nix { box64 = pkgs.box64; };
  }
)
