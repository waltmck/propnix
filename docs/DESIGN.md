# propnix — Definitive Architecture (v2)

Status: the decision record and reference for the shipped architecture. Where an alternative's headline abstraction was rejected, the reasoning is in **Rejected Alternatives**; the ideas worth keeping are folded into the Decisions below.

---

## Goals

- **Package proprietary games/apps once, wrap per `(fetcher, emulatedPlatform, hostPlatform)`.** A single game module yields every combination it has pins for — a GOG Windows build under wine, a Steam Linux build under box64, native on `x86_64-linux` — selected with `.apply { fetcher = …; emulatedPlatform = …; }`, with no per-host duplication and no per-game branching in the common case.
- **Maintainability first**, for a single maintainer scaling toward ~60 titles over years, whose only test host is a 16K-page Asahi `aarch64-linux` box. Every abstraction must be readable cold by a nixpkgs contributor, debuggable by copy-edit-run, and impossible to silently regress.
- **Hand-tuned performance** that generic solutions (stock proton, un-configured box64) cannot reach: per-game emulator knobs carried as reviewable data with rationale attached.
- **Preserve everything hardware-verified**: the wine engine, the store-seeded per-launch prefix, the three-way `user.reg` merge, the `{value;reason;}` tuning discipline, the Rust launcher, the DLC overlay framework. The module system and registries are the surface *over* these engines, not a rewrite of them.

## Non-goals

- A universal wrapper IR / layer algebra. Rejected (see below): net-adds complexity onto a repo that is overwhelmingly wine, regresses debuggability, and its type system catches only compositions nobody writes.
- Submodule-typed knobs that merge per-field. The module system (D16) uses **custom leaf types** that merge each knob as a whole `{value;reason;}` record — a submodule would materialize field defaults into every row and reintroduce reason-bleed (an override changing `value` inheriting a stale `reason`).
- Upstreaming to nixpkgs as a design driver. The credential-gated fetchers cannot go upstream (nixpkgs forbids account-gated auto-download; its answer is `requireFile`). We opportunistically shape the 1–2 generic hooks to be liftable, but we do **not** contort the tuning/prefix architecture around a review that will not accept the core.
- box86 / native 32-bit x86 Linux on aarch64. Dead on 16K pages. (32-bit *Windows* titles work — the wine engine's WoW64 path with `wowbox64`.)
- muvm as a default path. Its rendering is broken on this host; it is an opt-in escape hatch only.

---

## Decisions

Each is a commitment. Superseded entries have been rewritten to the current decision (the D-number is stable).

**D1 — The wine engine and the launcher are the preserved core.** `mkWineApp` (`lib/builders/wine.nix`) plus its satellites — `sealing.nix` (flatten + seal), the platform-aware base tuning layer (`lib/backends/wine/defaults.nix`), `mkStoreSkeleton`, `mkWineReg`, the three-way `user.reg` merge, `setupScript`/`userRegScript`, `extraSystem32`, `brokenVariables`, `PROPNIX_QUALITY`, the DLC read-only multi-lower overlay — and the Rust launcher carry every invariant the maintainer already hit and verified on the only host that can test them. The module system feeds `mkWineApp` a **pre-resolved** wine config; the engine's runtime behaviour (mount table, prefix overlay, HKCU merge) is unchanged by the surface above it.

**D2 — One uniform entrypoint `mkApp`, dispatching through a backend registry.** A game file authors a **module**; `mkApp` (`lib/mk-app.nix`) evaluates it with `lib.evalModules` against the typed option schema (`lib/modules/app-options.nix`) plus every backend's option modules, then dispatches to `backends.${cfg.backend}.build`. The two orthogonal axes are `fetcher` (where the payload comes from — picks the payload source and which store-integration DLL to neutralize) and `emulatedPlatform` (the content's OS+ABI — picks the backend via `resolveStrategy` and most tweaks). The result is a real derivation that also carries the override surface: `.apply` (accumulate a module, re-evaluate), `.extend` (raw eval), `.config` (the resolved config), `.withDlc`/`.withAllDlc`/`.dlc`.

**D3 — One runtime substrate: the launcher.** Every game — wine, box64, fex, native — runs through the Rust launcher. Wine emits `mode = "prefix"` (userns + mount table + prefix overlay); thin backends emit `mode = "thin"` (env-scrub + `LD_LIBRARY_PATH` + game-tree overlay + save-binds + splash + single-instance-focus + window-watcher, then one `execve`). `ModeProbe` reads the `mode` tag and deserializes the matching config struct; every flatten-free struct is `#[serde(deny_unknown_fields)]` and mount rows get an explicit key-validation pass (`validate_mount_rows`), so config↔launcher drift fails loudly — they ship together (the wrapper bakes the exact launcher). **There is no bare-`makeBinaryWrapper` fast path**: a bare path would fork the same game into two feature-unequal substrates, and the solo maintainer can only test aarch64.

**D4 — Backend selection is one pure function; empirical failures are data, not types.** `resolveStrategy` (`lib/strategy.nix`) maps the payload's `{ os; arch; }` × the host system to `wine`/`box64`/`native`/`unsupported` and serves only as the **default** of the typed `backend` option — `.apply { backend = "fex"; }` still wins, and the selection logic stays a unit-testable function outside the module fixpoint. It selects the *emulator for an already-selected payload variant*; which build to run is the game module's judgment, stated as `mkDefault`s on the two axes (Stellaris: the Steam Linux build under box64, because the Windows build hangs under FEX/ARM64EC). Empirical failures (KSP FEX codegen, the thin-FEX 16K walls) are caught by `broken.systems` + the verified manifest, never by a type system — a route table would be pure maintenance surface with near-zero defect-catching power.

**D5 — `pkgsX86` is a lazy scope attribute; combining its outputs runs natively.** In `lib/default.nix`: identity on x86_64 (zero second eval); on aarch64 a second native instantiation of the **same pinned** nixpkgs (`import pkgs.path { system = "x86_64-linux"; … }`), yielding **substitutable** prebuilt Hydra x86_64 `.so` (never `pkgsCross`, which misses cache). **Invariant:** any derivation that *combines* `pkgsX86` outputs is built with the **native** `pkgs` builders taking `pkgsX86` packages as *inputs* — never a `pkgsX86` build step, which would demand qemu/binfmt the Asahi host does not run. `lib.makeLibraryPath` over `pkgsX86` packages is pure eval and always safe. `pkgsX86` is only ever a build-time dependency; every derivation stays host-arch.

**D6 — Guard every nixpkgs bump with an x86 cache-hit gate.** Because the Asahi host cannot build `x86_64-linux` from source, a bump that drops any box64 guest lib from `cache.nixos.org` bricks every box64 game with an unrecoverable "no suitable builder" error. Policy: a bump is accepted only after verifying `narinfo` hits for the closure roots of the box64 guest set at the candidate rev (today a manual check — the mechanical `checkX86GuestCache` in `nix flake check` is backlog; `checks` is currently empty). The guest set is kept deliberately small. binfmt+qemu is documented as emergency-only recovery, not a normal dependency.

**D7 — Per-game library declarations are resolved twice; the union cannot drift.** The box64 backend's option namespace (`box64.bridgingLibs`/`box64.guestLibs`, declared in `lib/backends/box64/options.nix`) holds `pkgs -> [drv]` functions. On aarch64 the entry resolves `bridgingLibs` against **both** `pkgs` and `pkgsX86` (box64 needs the native `.so` to wrap *and* the x86_64 copy for the guest) plus `guestLibs pkgsX86`; on x86_64 it collapses to one native set. The FEX backend **reuses** the same `box64.*` declarations as a pure guest union (no bridging). One declaration, per-backend resolution — the original Hollow Knight wrapper's #1 hazard (native/guest lists drifting) is structurally impossible.

**D8 — box64 supplies interpreter+libs at runtime, invokes box64 explicitly, never autoPatchelfs, never depends on host binfmt.** The spec declares the real x86_64 ELF as `exe` (bypassing GOG's `start.sh` / Paradox's Electron launcher chain); the backend sets `emulator = ${box64}/bin/box64` in the launch block — explicit, reproducible, no `binfmt_misc` reliance. The resolved library union goes on `LD_LIBRARY_PATH` (the **proven** formula) with `BOX64_PREFER_WRAPPED=1` and `BOX64_NORCFILES=1` (a user's `~/.box64rc` can't change behaviour). Foreign-arch payloads are FODs — never stripped, never patchelf'd (except FEX's single-exe `PT_INTERP` overlay, D12); `autoPatchelfHook` is **never** run on them. Exec bits Steam depots lack (0444) are reproduced by a zero-copy metacopy skeleton stacked above the game overlay, not by copying the tree.

**D9 — Tuning stays atomic `{value;reason;}` knobs; the module system is the merge engine.** Every non-default knob justifies itself; the custom leaf types (`lib/modules/types.nix`: `knob`, `lastWins`, `dedupList`) reproduce the historical `sealing` merge algebra exactly — whole-record last-wins scalars (no reason-bleed), per-key maps (`dllOverrides`, `userReg` families, `mounts`), deduped base-first unions (`brokenVariables`, `galaxyStubDlls`). Layers = the wine defaults module + the per-game tuning + `.apply` tweaks, merged by `evalModules` at their natural priorities. `sealing.nix` retains only what runs on the *resolved* config: `flattenTuning` (reason-strip for the runtime JSON) and `mkSeal`; `sealing.defaultScrub` (`["WINE" "FEX_" "BOX64_" "LD_"]`) is **the** single source of the scrub prefixes on every backend.

**D10 — Payloads are credentialed FODs, pinned in `versions.json` as the fetch matrix.** `versions.json` v2 *is* `fetchInfo`: `fetchInfo.<fetcher>.<platform> = [ argset … ]`, each arg-set passed **verbatim** to the fetcher (pname included — FOD names are stable, so re-pinning never re-downloads a multi-GB payload; list order = payload/overlay priority). Credentials live out-of-band in `/var/lib/propnix` (`propnix cred add {gog,steam}`), bound at `/propnix` via `services.propnix` / `--extra-sandbox-paths`, **copied to a writable `$TMPDIR` inside the builder** before invoking the tool (token-refresh write-back can't `EACCES` or race); the shared prologue (credentials.toml check, creddir extraction, no-accounts error) is `lib/fetchers/cred-lib.sh`, sourced by all three fetchers, each keeping its own download body and not-owned fall-through. Never email+password in a derivation; never the token in `impureEnvVars`; never token values/paths printed. Determinism rank: Steam depot `(appId,depotId,manifestId)` > GOG Galaxy `(productId,buildId)` > GOG Linux offline installer (**no** version pin — latest-only).

**D11 — Cache only the payload-free emulator/launcher closure; never games.** A playable game wrapper legitimately references its payload in its runtime closure — you cannot `allowedRequisites` it away, and a "closure proves no payload" test on a stubbed build is a fiction for the artifact you'd actually ship. The private cache push filter selects **only** the emulator/launcher attrs (wine, fexdlls, box64, dxvk, vkd3d, llvmMingw, propnix-launcher), payload-free by construction. Every payload FOD sets `allowSubstitutes = false; preferLocalBuild = true;` and is unfree binary-native-code.

**D12 — Two FEX mechanisms, never conflated; the thin FEX backend is carried-but-broken on 16K.** (A) **FEX ARM64EC DLLs inside wine** (`HODLL64=libarm64ecfex.dll`; 32-bit via `wowbox64.dll`, box64's `-DWOW64=ON` build) — the Hangover backend for Windows guests on aarch64, works today, entirely inside the wine engine. (B) **`FEXInterpreter`** for x86_64 *Linux* guests — the box64 sibling, `lib/backends/fex/default.nix`: it reuses `box64.*` as a pure guest union, patches only the main exe's `PT_INTERP` to the `pkgsX86.glibc` loader (a tiny overlay above the read-only payload), and sets `FEX_ROOTFS=/` so absolute x86_64 store paths resolve as guest files. On 16K hosts (B) reaches Unity/Mono init and then hits fundamental walls (FEX's self-modifying-code tracking is non-functional with 4K-granular mprotect on 16K host pages; sub-host-page mmap emulation), so its launch block carries `brokenSystems` for both systems — kept so a 4K host or an upstream SMC fix flips it on unchanged via `.apply { backend = "fex"; }`. **box64 is the default and only-working Linux-x86-on-aarch64 backend on the author's host.**

**D13 — Unavailable combos and known-broken titles stay evaluable.** `broken.systems`/`broken.reason` → `meta.broken` on the listed systems via `mkLauncherPackage`: the derivation still **evaluates** (discoverable, reason inspectable via `nix eval`); only building is refused. An unpinned `(fetcher, platform)` pair throws only when `payloads` is **forced**, with a legible error enumerating the pinned pairs and the `.apply` line that selects one. `nix flake show`/`check` stay green.

**D14 — Debug and interface ergonomics are first-class.** Every app: CLI-launchable (`bin/<pname>` via the launcher), a `.desktop` entry with an icon (three icon sources — game-data PNG, PE resources, UnityPlayer.png — one hicolor + splash layout), and `PROPNIX_*` env config with the config baking defaults only. `passthru.configFile` exposes the resolved launcher JSON and `.config` the full evaluated module config, both `nix eval`-able. `PROPNIX_DEBUG` tees the game's output; `--shell` gives a sealed shell in the prefix; `--propnix-unseal` skips the scrub; `BOX64_JITGDB`/FEX gdb sit behind `PROPNIX_DEBUG`.

**D15 — Registries and helpers are threaded as scope attributes, not `lib.propnix`.** `lib/default.nix` is a `lib.makeScope` where `callPackage` resolves every edge by argument name (`pkgsX86`, `mkApp`, the builders, the emulator set — arch-aware in the scope, arch-agnostic everywhere else). The two registries live here: `fetchers` = name → (emulatedPlatform → fetch function) — **GOG is per-platform**: Galaxy `buildId`-pinned for Windows builds, the offline installer for Linux (Galaxy has no Linux builds); Steam is platform-uniform — and `backends` = name → `{ modules; build; }`. Extending either is a scope overlay, not an edit to `mk-app.nix`; overriding `scope.wineDefaults` re-bases every game's wine tuning. `lib` stays plain nixpkgs `lib`.

**D16 — The module system: typed options, self-contained backend entries, `.apply` accumulation.** `mkApp` is Lassulus/wrappers-style two-tier: an `evalModules` option surface over plain builders, with `.apply` accumulating modules and re-evaluating. The schema (`lib/modules/app-options.nix`) types every top-level option with a `description`; `pname`/`appid` are deliberately default-less, and the two axes resolve per **D17**. The `fetchInfo` option tree is **generated** from the fetcher registry × the platform enum, so a typo at either level is an "option does not exist" eval error and a non-null value *is* availability (fetchInfo values must never depend on the axes — the matrix is read while they resolve). Each backend is one directory `lib/backends/<name>/` exporting a registry entry `{ modules; build; }` — options + dispatch arm co-located; **all** entries' modules are always imported (a game sets `wine.*`/`box64.*` conditionally, whatever backend wins; laziness makes the unused namespace free); `native` aliases the box64 entry with `modules = []` so shared options aren't declared twice. Reusable engine-family tuning ships as `lib/presets` fragments composed with `presets.mergeTuning` — a knob-aware deep merge that **throws on leaf collision** (fragments must be disjoint; overriding a preset means setting the knob in the game's own layer and letting the module merge win).

**D17 — Build selection: game-ranked platforms × user-ranked fetchers, resolved purely at eval.** The instantiation config (`import propnix { pkgs; config.preferredFetchers = [ "steam" "gog" ]; }`, or `scope.overrideScope (final: prev: { propnixConfig.preferredFetchers = […]; })`) states the user's stores as a ranked **allowlist**; the default is every registered fetcher in registry order — "no account statement made", which reproduces the un-configured selection exactly. Each game states a `platformPreference` — its **quality ranking** of pinned platforms, derived automatically for a single-platform matrix and *required* explicitly the moment a second platform is pinned (the ratchet keeps ordering a stated judgment; Hollow Knight ranks `[ x86_64-linux x86_64-windows ]` — box64 benchmarks ahead of wine+FEX). Resolution is **platform-major lexicographic**: for each game-ranked platform, the first listed fetcher pinning it wins, so an account preference can shift the platform *only along the game's own ranking* (a gog-only user gets HK's sanctioned gog/x86_64-windows fallback; steam-only-linux Stellaris errs legibly, never degrades). The resolution is **pure** — credentials are never probed at eval; a mis-stated config fails at FOD-fetch time exactly as an absent account does. The list shapes defaults, it is not a sandbox: `.apply { fetcher = …; }` selects even an unlisted fetcher, and a game may state a rare, justified `fetcher = lib.mkDefault …` quality exception — every such exception must be listed in `lib/tests/resolution.nix` (the standing `checks.<system>.config-resolution` gate, which also pins every game's resolved `(fetcher, platform, backend)` triple and the guard semantics). Mechanically, the coupled axis defaults are cycle-free via `options.<axis>.highestPrio < (lib.mkOptionDefault null).priority` — an explicit definition constrains the other axis's walk; the injected schema default does not (`isDefined` is unusable here: the module system injects the default *as* a definition). `scope.resolvableGames` filters the catalog by a pure resolvability probe for enumerate-everything consumers.

---

## Directory tree

```
propnix/
├── flake.nix                      # single nixpkgs pin; outputs: legacyPackages(=scope), packages, apps,
│                                  #   lib (mkSeal/flattenTuning/defaultScrub), nixosModules
├── lib/
│   ├── default.nix                # the scope: emulator set (arch-aware), the two REGISTRIES
│   │                              #   (fetchers, backends), builders, icons, presets; auto-discovers pkgs/games/*
│   ├── mk-app.nix                 # the evalModules dispatcher ENGINE: eval + dispatch + the `.apply` surface
│   ├── strategy.nix               # resolveStrategy (pure; the `backend` option default)
│   ├── sealing.nix                # flattenTuning (reason-strip) + mkSeal + defaultScrub (pure lib)
│   ├── modules/
│   │   ├── app-options.nix        # the top-level option schema (fn of the registries; generated fetchInfo tree)
│   │   └── types.nix              # knobTypes: knob / lastWins / dedupList custom leaf types
│   ├── backends/                  # one self-contained REGISTRY ENTRY per backend: { modules; build; }
│   │   ├── wine/                  #   default.nix (entry) + options.nix (wine.* schema) + defaults.nix (base layer)
│   │   ├── box64/                 #   default.nix (entry; also serves `native`) + options.nix (box64.*)
│   │   ├── fex/default.nix        #   reuses box64.*; PT_INTERP patch + FEX_ROOTFS=/; broken on 16K
│   │   └── mk-thin-build.nix      #   shared thin dispatch-arm assembler + the launch-block contract check
│   ├── builders/
│   │   ├── wine.nix               # mkWineApp — resolved config → PREFIX-mode package (the wine engine)
│   │   ├── thin.nix               # mkThinApp — resolved config + launch block → THIN-mode package
│   │   ├── launcher-package.nix   # mkLauncherPackage — the shared packaging tail (wrapper + .desktop + meta)
│   │   ├── desktop-item.nix       # mkDesktopItem
│   │   ├── store-skeleton.nix     # mkStoreSkeleton (data-only overlay skeleton; also the thin exec-bit fix)
│   │   ├── wine-reg.nix           # mkWineReg (declarative HKLM/.Default hives)
│   │   ├── setup-script.nix       # mkSetupScript (pipefail + pinned PATH wrapper) + ini-lib.sh (shared ini_set)
│   ├── icons/
│   │   ├── pipeline.sh            # the shared autocrop/recentre → hicolor theme + splash shell lib
│   │   ├── from-png.nix           # mkAppIcon — a high-res raster from the game data (preferred)
│   │   ├── from-pe.nix            # extractPeIcon — the exe's PE resources, at their TRUE sizes (no fake upscale)
│   │   └── from-unity.nix         # extractUnityIcon — <exe>_Data/Resources/UnityPlayer.png (build-time find)
│   ├── fetchers/
│   │   ├── cred-lib.sh            # the shared credential prologue (sourced by all three)
│   │   ├── fetchGogGalaxyBuild/   # gogdl FOD, (productId,buildId)-pinned — GOG Windows builds
│   │   ├── fetchGogLinuxInstaller.nix  # lgogdownloader FOD, latest-only — GOG Linux builds
│   │   └── fetchSteamDepot.nix    # DepotDownloader FOD, manifest-pinned — reference-grade determinism
│   └── presets/default.nix        # unity.framePacing / unity.fullscreen fragments + mergeTuning
├── emulators/                     # first-class, game-independent, pinned translation layers
│   ├── wine-hangover/             # arm64ec wine (aarch64) / native wine (x86_64) — same source
│   ├── fex-dlls.nix               # FEX-2607 ARM64EC DLLs (HODLL64) + wowbox64 (box64 -DWOW64=ON, HODLL)
│   ├── box64-latest.nix           # regular box64 for Linux-x86 guests (thin backend)
│   ├── dxvk-arm64ec.nix / dxvk-x86_64.nix / vkd3d-proton-arm64ec.nix / vkd3d-proton-x86_64.nix
│   ├── galaxy-stub/               # graceful no-op GOG Galaxy SDK DLLs (bound over bundled copies)
│   ├── llvm-mingw/  wine-prefix-lower.nix
├── pkgs/
│   ├── propnix-launcher/          # Rust — PREFIX + THIN modes; links propnix-mount/-prefetch as crates;
│   │                              #   splash, single-instance-focus, window-watcher, seal, HKCU merge
│   ├── propnix-cli/               # `propnix cred add {gog,steam}` — out-of-band token store in /var/lib/propnix
│   └── games/                     # auto-discovered; one dir per title { default.nix, versions.json, setup.sh?,
│       │                          #   wine-tuning.nix? / box64-tuning.nix? }
│       ├── hollow-knight/         # the two-axis exemplar (gog/steam × windows/linux; see Worked examples)
│       ├── stellaris/             # Steam Linux two-depot build under box64/native
│       └── …                      # 17 titles
├── nixos/propnix.nix              # services.propnix: cred-dir bind into the FOD sandbox; ntsync udev;
│                                  #   cachix substituter+key (useCache); `propnix` CLI in systemPackages;
│                                  #   declarative cred store from sops/agenix paths (credentials.<t>.<u>);
│                                  #   groups: `propnix` = manage (humans, dirs 2775 → cred add/rm sudo-free),
│                                  #   `propnix-fetch` = read (those humans + the nix build users, tokens 0640)
├── docs/
│   ├── verified/<game>.json       # committed hand-test manifest (host/kernel/mesa/fex/box64/wine/fps/status)
│   └── DESIGN.md → (this file)
├── DOCS.md                        # user/operator reference (requirements, layout, adding a game)
└── README.md
```

---

## `lib/` API

All helpers are scope attributes (D15); a game file receives them by name through `callPackage`.

### The registries (lib/default.nix)

```nix
# fetcher name → (emulatedPlatform → fetch function). GOG is PER-PLATFORM (D15).
fetchers = {
  gog = platform: if lib.hasSuffix "-linux" platform then fetchGogLinuxInstaller else fetchGogGalaxyBuild;
  steam = _platform: fetchSteamDepot;
};

# backend name → { modules; build; }. `native` reuses the box64 entry's build with no modules.
backends = {
  wine   = callPackage ./backends/wine { };
  box64  = box64Entry;
  native = { modules = [ ]; build = box64Entry.build; };
  fex    = callPackage ./backends/fex { inherit pkgsX86; };   # research / meta.broken on 16K
};
```

Adding a fetcher or backend = one registry entry (plus, for a backend with tuning, its `options.nix`); the enums, dispatch, and availability errors all derive from the registries.

### `resolveStrategy` (lib/strategy.nix)

```nix
# need = { os = "windows"|"linux"; arch = "x86_64"|"i386"; }; system = the host
# → "wine" | "box64" | "native" | "unsupported"
resolveStrategy = need: system:
  if need.os == "windows" then "wine"          # wine picks native vs ARM64EC+HODLL (and the 32-bit DLL) internally
  else if need.os == "linux" then (if isAarch then "box64" else "native")
  else "unsupported";
```

Pure and outside the module fixpoint; used only as the `backend` option's default, so `.apply { backend = … }` wins (D4).

### `mkApp` (lib/mk-app.nix)

`mkApp spec` evaluates `[ app-options ] ++ concatMap (b: b.modules) backends ++ [ spec ] ++ applied`, resolves the DLC selection (`dlc.enabled` names against `dlc.available`, unknown name = legible error), and dispatches `backends.${cfg.backend}.build { inherit cfg enabledDlc executables; }`. The returned derivation is extended (top-level **and** `passthru`) with the override surface:

- `.apply m` — accumulate a module and rebuild (`hollow-knight.apply { fetcher = "steam"; emulatedPlatform = "x86_64-linux"; }`);
- `.extend m` — the raw re-eval (for inspecting `config` without building);
- `.config` — the resolved config; `.withDlc [names]` / `.withAllDlc` / `.dlc`.

### The option schema (lib/modules/app-options.nix)

Top-level options, each typed and described: `pname`, `appid`, `name`, the two axes (`fetcher`, `emulatedPlatform` — enum over the registry / the platform list `x86_64-windows | i386-windows | x86_64-linux`), `backend` (enum over the registry, default `resolveStrategy`), the generated `fetchInfo.<fetcher>.<platform>` matrix, `payloads` (default: fetch the selected pair or throw the availability error enumerating the pinned pairs), `exe`, `exeArgs`, `executables` (thin exec-bit list), `maskFiles` (runtime whiteouts — true absence for dlopen'd store DLLs like `steam_api`; a statically-imported SDK needs the opposite, `wine.galaxyStubDlls` stubs), `workingDir`, `saveBinds`, `icon = { png; symbolic; auto; }`, `broken = { systems; reason; }`, `dlc = { available; enabled; }`, `env`.

Two options are **unified across backends**:

- **`env`** — extra child environment, values `$VAR`-expanded at launch on every backend. On thin backends applied *after* the launcher/backend defaults (a game can override `BOX64_*`); on wine folded into `seal.setEnv` *before* the launcher's computed `WINEPREFIX`/`WINEDLLOVERRIDES`/`DXVK_*` (which always win). The launcher-owned names (`WINEDEBUG`, `USER`, `LOGNAME`, `WINEPREFIX`, `WINEDLLOVERRIDES`, `LD_LIBRARY_PATH`, `LD_PRELOAD`) are an **eval-time error** on wine, not a silent no-op.
- **`saveBinds`** — `{ src; dst; ro ? false; create ? true; }` with `dst` **HOME-relative on both backends**: the ephemeral `$HOME` view on thin, the wine profile home (`drive_c/users/<wineUser>/`) on wine, where each bind derives one mount row merged *before* the tuning's `mounts` (a game's `wine.mounts` can still override per-target). Binds only: overlay-style save persistence (KSP's writable game dir with a `$PROPNIX_SAVE_DIR` upper) stays a hand-written `wine.mounts` row — the documented exception.

### Backend entries (lib/backends/<name>/)

**wine** (`backends/wine/default.nix`): imports `options.nix` (the `wine.*` schema) plus the base-layer module `config.wine = wineDefaults { platform = config.emulatedPlatform; wine = config.wine; }` — a config-*function* of the fixed point, so derived mount rows (`galaxyStubDlls`/`extraSystem32` → rows) recompute against the final knob values and the `d3d` default follows the platform (`i386-windows` → `wined3d`: DXVK is ARM64EC-only, a 32-bit process can't load it). `build` calls `mkWineApp` with the identity, payloads, and the pre-resolved `config.wine`.

**box64/native** (`backends/box64/default.nix`): computes the launch block — `emulator` (`${box64}/bin/box64` on aarch64, `null` = direct exec on x86_64), the library union per D7, backend env (`BOX64_NORCFILES=1`, `BOX64_PREFER_WRAPPED=1`; the game's `env` merges over) — and assembles via `mkThinBuild`.

**fex** (`backends/fex/default.nix`): `modules = []` (reuses `box64.*`); guest-only library union from `pkgsX86`; the `PT_INTERP`-patched exe as an `extraLowers` overlay with `executables = []`; `FEX_ROOTFS = "/"`; `brokenSystems` for the 16K walls (D12).

**mkThinBuild** (`backends/mk-thin-build.nix`): the shared thin dispatch-arm assembler. It enforces the **launch-block contract** — required `backend/emulator/env/ldLibraryPath/mangohud`, optional `extraLowers/executables/brokenSystems/brokenReason`; a misspelled or undeclared field is a named eval error — merges backend `broken*` into the app's, stacks enabled DLC above any backend overlay, and calls `mkThinApp`.

### Builders (lib/builders/)

**`mkWineApp`** (wine.nix) — resolved config → PREFIX-mode package. Emits the config JSON with `mode = "prefix"`: the complete WINEPREFIX mount table (read-only hive binds from `mkWineReg`, the game at `drive_c/game` — a plain read-only bind, or a read-only **multi-lower overlay** when DLC and/or co-base payload trees are present (DLC first, then payloads in declared order; the tail of a multi-payload build is never dropped) — the derived save-bind rows, the tuning's `mounts` (which carry the derived de-Galaxy stubs and staged `extraSystem32` DLLs), `maskFiles` whiteouts over the game dir, and the root mount of the persistent prefix dir seeded with wine's game-agnostic `user.reg`); every store-backed `overlay` row gets a `mkStoreSkeleton` data-only skeleton by default (explicit `skeleton = null` opts out); the seal (`WINEDEBUG=-all`, `USER`/`LOGNAME` = the store lower's user, + the unified `env`); the flattened `userReg`/`fpsUserReg`/`vsyncUserReg`, `setupScript`, `userRegScript`, `brokenVariables`, and the emulator store paths. `passthru`: `payload`, `payloads`, `backend` (`"winefex"` on aarch64, `"wine"` on x86_64 — informational; the launcher never branches on it), `dlc`.

**`mkThinApp`** (thin.nix) — resolved config + launch block → THIN-mode package. Owns everything emulator-independent: the read-only game-tree union (`payloads`, leftmost wins; `extraLowers` above), the metacopy exec-bit skeleton, `maskFiles` whiteouts, save binds, icon, splash/single-instance/window-watcher flags, and the `mode = "thin"` config JSON. `scrubPrefixes` defaults to `sealing.defaultScrub` — the same constant the wine seal uses.

**`mkLauncherPackage`** (launcher-package.nix) — the shared packaging tail both builders delegate to: the `bin/<pname>` makeWrapper around `propnix-launcher --config <configFile>`, the `.desktop` entry (`startupWMClass` = the exe basename lowercased; `Icon` only when a raster theme is installed), `meta.broken` from `broken.{systems,reason}`, and the final `symlinkJoin` with `passthru.configFile`/`.launcher` + the builder's `extraPassthru`. `iconName = "org.propnix.${appid}"` is computed per-builder; the icon *source* choice stays per-builder (PE vs Unity vs `icon.png`), all three emitting one layout (hicolor theme + `share/propnix/<id>.png` splash) via the shared `icons/pipeline.sh`; `from-pe` keeps its per-true-size install (no fake upscaled theme).

**`mkSetupScript`** (setup-script.nix) — wraps a game's `setup.sh` as the store-path executable behind `wine.setupScript`: `set -euo pipefail` + a pinned coreutils/sed/awk/grep PATH; `withIniLib = true` prepends the shared `ini_set` INI editor (`ini-lib.sh`, parameterized `INI_SEP`/`INI_CRLF`/`INI_SKIP_COMMENTS` — the three variants the games need).

### Fetchers (lib/fetchers/)

```
fetchGogGalaxyBuild    :: { pname; productId; buildId; version; outputHash; … }   -> FOD   # Windows Galaxy depots
fetchGogLinuxInstaller :: { pname; productId; …; outputHash; }                    -> FOD   # Linux offline installer (no pin)
fetchSteamDepot        :: { pname; appId; depotId; manifestId; outputHash; title }-> FOD   # manifest-pinned, permanent
```

All download-only, arch-independent NARs, `allowSubstitutes = false`, `impureEnvVars` = TLS/proxy only. Each sources `cred-lib.sh` for the credential prologue, copies the bound `/propnix` store to `$TMPDIR` (D10), tries each stored account of its type until one owns the pinned content, and never prints token values or paths.

---

## Tuning data model (D9/D16)

Per-game wine tuning is one attrset in the `{value;reason;}` shape (typically `wine-tuning.nix`, or inline), set as `config.wine`; box64 library triage as `config.box64` (typically `box64-tuning.nix`). The wine option types map each knob to its historical merge semantics:

| type | options | merge |
|---|---|---|
| `knob` | `d3d`, `graphics` | whole `{value;reason;}` record, last-wins |
| `attrsOf knob` | `dllOverrides` | per-DLL, whole-knob last-wins |
| `attrsOf (attrsOf knob)` | `userReg`, `fpsUserReg`, `vsyncUserReg`, `systemReg`, `userdefReg` | per-key/per-name knob |
| `attrsOf lastWins` | `extraSystem32` | per-DLL, whole-value |
| `attrsOf (attrsOf lastWins)` | `mounts` | per-target/per-field (no submodule — field defaults must not materialize, and a bind→overlay replacement must swap the whole row) |
| `dedupList str` | `brokenVariables`, `galaxyStubDlls` | union + dedup, base-first |
| `lastWins` | `setupScript`, `userRegScript` | whole-value replace |

No wine option has a `default`: `wineDefaults` defines every knob as the base layer, so nothing is ever materialized from an option default and the resolved config carries exactly the keys the flatten expects. Engine-family fragments (`presets.unity.framePacing <hkcuKey>`, `presets.unity.fullscreen <hkcuKey>`) compose with `presets.mergeTuning` (throws on collision; override by setting the knob in the game's own layer instead).

```nix
# a per-game delta — atomic override; changing `value` can never carry a stale `reason`
wine = presets.mergeTuning [
  (presets.unity.framePacing "Software\\Team Cherry\\Hollow Knight")
  { galaxyStubDlls = lib.mkIf (config.fetcher == "gog") [ "Galaxy64.dll" ]; }
];
box64 = import ./box64-tuning.nix;   # { bridgingLibs = p: [ … ]; guestLibs = p: [ … ]; }
```

---

## Worked examples

### 1. Hollow Knight — the two-axis exemplar

One module covers three pinned combos; the axes' `mkDefault`s pick gog/windows, and `.apply` selects the rest:

```
nix run .#hollow-knight                                                                  # gog/x86_64-windows (wine)
nix run '.#hollow-knight.apply { fetcher = "steam"; }'                                   # steam/x86_64-windows (wine)
nix run '.#hollow-knight.apply { fetcher = "steam"; emulatedPlatform = "x86_64-linux"; }'# steam/x86_64-linux (box64)
```

The spec (`pkgs/games/hollow-knight/default.nix`, abridged) sets everything conditionally on the axes:

```nix
mkApp ({ config, ... }: let
  onLinux = config.emulatedPlatform == "x86_64-linux";
  onSteam = config.fetcher == "steam";
in {
  pname = "hollow-knight"; appid = "hollow-knight"; name = "Hollow Knight";
  fetcher = lib.mkDefault "gog";
  emulatedPlatform = lib.mkDefault "x86_64-windows";
  fetchInfo = (lib.importJSON ./versions.json).fetchInfo;      # the whole fetch matrix, one line

  exe = if onLinux then "hollow_knight.x86_64"
        else if onSteam then "hollow_knight.exe" else "Hollow Knight.exe";

  # fetcher axis: Steam builds MASK the dlopen'd steam_api (true absence — an empty stub faults the
  # loader); the GOG build instead STUBS its statically-imported Galaxy SDK (wine.galaxyStubDlls below).
  maskFiles = lib.optionals onSteam
    [ (if onLinux then "hollow_knight_Data/Plugins/libsteam_api.so"
                  else "hollow_knight_Data/Plugins/x86_64/steam_api64.dll") ];

  saveBinds = [{
    src = "$PROPNIX_SAVE_DIR/$PROPNIX_APPID";
    dst = if onLinux then ".config/unity3d/Team Cherry/Hollow Knight"
                     else "AppData/LocalLow/Team Cherry/Hollow Knight";
  }];

  # platform axis: box64 lib triage + the two box64-specific dynarec workarounds
  box64 = import ./box64-tuning.nix;
  exeArgs = lib.optionals (config.backend == "box64") [ "-force-opengl" ];
  env.SDL_VIDEODRIVER = lib.mkIf (config.backend == "box64") "x11";

  wine = presets.mergeTuning [
    (presets.unity.framePacing "Software\\Team Cherry\\Hollow Knight")
    { galaxyStubDlls = lib.mkIf (config.fetcher == "gog")
        [ "Galaxy64.dll" "Hollow Knight_Data/Plugins/x86_64/Galaxy64.dll" ]; }
  ];
})
```

`versions.json` is verbatim `fetchInfo` — `gog.x86_64-windows` (one Galaxy `buildId`-pinned arg-set) and `steam.{x86_64-windows,x86_64-linux}` (manifest-pinned depots).

### 2. Stellaris — Steam Linux two-depot build under box64

The Windows/Clausewitz build hangs under FEX/ARM64EC (a genuine early-init stack overflow the transition overhead inflates), so the module defaults to `steam`/`x86_64-linux`: the binaries depot and the data depot are two `fetchInfo` arg-sets, **unioned read-only by overlayfs at launch** (binaries first — arg-set order = overlay priority; no build-time merge, no store copy). `exe = "stellaris"` bypasses `start.sh` → dowser → the Electron Paradox launcher; `box64.bridgingLibs`/`guestLibs` state the library union (zlib in both — box64 needs the native copy, `libPDXSDK` links the guest one); the save bind lands on the exact XDG path Clausewitz writes.

It is also the DLC framework's **thin-path** case (§4 is the wine one). Paradox ships each DLC as its own Steam depot of the base app — the depotId *is* the DLC's store appid — so every `dlc` row in `versions.json` is an ordinary manifest-pinned `fetchSteamDepot` and `dlc.available = lib.mapAttrs (_: fetchSteamDepot) versions.dlc`. `mkThinBuild` stacks the enabled trees as `extraLowers` above the base depots, which is safe here for a structural reason: each DLC tree is only `dlc/dlcNNN_<slug>/…`, the binaries depot mirrored by the exec-bit skeleton (the one layer that outranks `extraLowers`) has no `dlc/` at all, and the data depot's `dlc/` is empty — a pure directory union with nothing to shadow.

**A store-entitlement wall sits behind that, and closing it is the second half — done by the FRAMEWORK, not the game.** Stellaris's *Steam* build asks the Steam client whether each DLC is owned rather than trusting the `.dlc` descriptor, and Valve ships no client for 16K-page aarch64: with the depots merely mounted, `SteamAPI_Init` finds nothing, `dlc.cpp` logs `Could not find item in store backend.`, and Additional Content lists every DLC as unowned. Every Steam-fetched game gets `steam.emu.enable` by default (modules/steam-emu.nix, the `steam.*` namespace), which wires `lib/builders/steam-offline-entitlement.nix` — the LGPL **gbe_fork** shim (emulators/gbe-fork.nix: the maintained Goldberg successor tracking current Steamworks SDKs; a prebuilt release pin, from-source packaging is backlog) *copied* beside a generated settings tree (`configs.app.ini` with an explicit `unlock_all=0` + the owned list; upstream's default is "unlock everything"). The list is a projection of `dlc.enabled` through the depot derivations' own identity (fetchSteamDepot passthru: `dlcAppId` when a row states one, else `depotId` — the Paradox convention), and a depot only exists at all because Steam issued this account a decryption key for it (eresult 15 otherwise), so the shim cannot assert ownership of anything unowned; the list is always emitted, empty for a vanilla or DLC-less build. Placement is per-loader: THIN preloads the tree's `.so` via `box64.guestPreload` (translated to `BOX64_LD_PRELOAD` / `LD_PRELOAD`; the beside-the-library probe resolves into the settings tree on native, and box64 — which never file-maps guest libraries — falls back to the CWD, where `extraLowers` unions the tree into the game dir), with `.so` entries of `steam.emu.libPaths` additionally BOUND OVER for engines that dlopen by explicit path (Unity plugins; no preload interposes those). WINE needs no preload machinery at all: a declared `steam_api(64).dll` path is MIRRORED inside the settings tree with settings beside it, and the tree union-replaces the shipped dll (extra lowers outrank the payload); the PE loader file-maps DLLs, so the beside-the-dll probe just works — verified live on hollow-knight steam/windows ("Steam logged in", stats received). Enabling the emu on wine with no `.dll` path declared is a legible eval error (the shim would be silently inert). Remaining limit: the shim answers only the SDK surface of its pin — a game built against a newer SDK fails as lib-loads-init-throws (worse than absence; how goldberg-emu 0.2.5's missing `SteamInternal_SteamAPI_Init` black-screened SDK-1.60 hollow-knight before the gbe_fork switch), so triage a new game's genuine lib with `nm -D` against the pin first.

### 3. Don't Starve — 32-bit Windows PE

`emulatedPlatform = "i386-windows"` → wine on both hosts; the engine runs native WoW64 on x86_64 and arm64ec Hangover wine + `wowbox64.dll` (box64's i386 backend) on aarch64. The platform-aware defaults layer supplies `d3d = wined3d` (DXVK is ARM64EC-only; a 32-bit process can't load it) — the game states only what is its own: `workingDir = "bin"` (Klei resolves the data root from CWD), its `setup.sh` via `mkSetupScript { withIniLib = true; }` (fullscreen lives in `settings.ini`, not the registry), and its save bind.

### 4. Factorio — the DLC framework

The DLC framework on the **wine** path (Stellaris, §2, is the thin one): `versions.json` carries the Space Age tree under a `dlc` key; the module maps it into `dlc.available`. `factorio.withDlc [ "space-age" ]` / `.withAllDlc` flips the `drive_c/game` row from a read-only bind to a read-only multi-lower overlay (DLC first), merging at mount time with no store copy of the base. GOG may reship base files inside a DLC depot; the duplication is accepted.

---

## FEX strategy (the two mechanisms)

- **(A) FEX ARM64EC DLLs inside wine** — the Hangover backend. On aarch64 the wine loader is arm64ec wine; `HODLL64=libarm64ecfex.dll` translates 64-bit Windows guest code, `HODLL=wowbox64.dll` (box64 `-DWOW64=ON`; a **separate** build from the thin-backend box64 — the repo keeps both) translates 32-bit. No rootfs, no `FEXInterpreter`. Works today on 16K; entirely inside the wine engine (D1/D12).
- **(B) `FEXInterpreter`** — the thin FEX backend for x86_64 *Linux* guests (`lib/backends/fex/`). No rootfs assembly and no thunks: the guest stack is the game's own x86_64 libraries plus a `pkgsX86` guest union on `LD_LIBRARY_PATH`, `FEX_ROOTFS=/` (unset hangs) making absolute store paths resolve as guest files, and a single-file overlay patching the exe's `PT_INTERP` to the `pkgsX86.glibc` loader. **Status: research / `meta.broken` on 16K** — guest Mono/JIT init crashes on the SMC-tracking and sub-host-page-mmap walls (D12). Carried unchanged for a 4K host or an upstream fix; box64 is the working path.

---

## Testing & the "verified working" manifest

**Tier 1 — eval (CI-safe, no payload).** All 17 games' `configFile` + `backend` evaluate on aarch64 **and** x86_64 (the launcher-config JSON is `nix eval`-able via `passthru.configFile` without fetching anything). `nixfmt-rfc-style` over `lib/` + `pkgs/games` + `flake.nix`. The refactor was gated by a **golden semantic diff** of all 20 config JSONs against the pre-refactor tree (only intended diffs: wine configs gained `mode:"prefix"`; thin `scrubPrefixes` reordered to the canonical `sealing.defaultScrub` order); the standing gate is the launcher's own strictness (D3) — a drifted config fails deserialization loudly. `flake.checks` is currently empty; the strategy golden table and `checkX86GuestCache` are backlog.

**Tier 2 — launch smoke (payload-gated, local only).** `nix run` the title; the window-watcher confirms the window **maps**; screenshot-stddev catches a black window. Not in CI (CI cannot legally fetch payloads).

**Tier 3 — the verified manifest (source of truth).** `docs/verified/<game>.json`, committed as data: `{ date, hostArch, kernel, mesa, box64/fex/wine versions, graphicsBackend, fps, resolution, status, notes }`. This is what actually enforces "hand-tested," is diffable on every emulator bump, and is the authoritative input to `broken.systems` (KSP/Homeworld precedent). It is the maintainable substitute for a perf CI that cannot legally fetch payloads.

---

## Binary-cache legality

- **Payloads** (game bytes) are never offered to or pushed to any substituter: `allowSubstitutes = false; preferLocalBuild = true;`, unfree.
- **Cacheable** = the payload-free emulator/launcher closure (`wine`, `fexdlls`, `box64`, `dxvk`, `vkd3d`, `llvmMingw`, `propnix-launcher`, `propnix-cli`) — game-independent by construction, the expensive-to-build part, worth a private attic.
- **Not cacheable** = any game output. A *playable* wrapper legitimately references its payload store path in its runtime closure; the push filter therefore selects only the emulator/launcher attrs by name, and a closure-leak test on *those* attrs (no `fetchGog*`/`fetchSteamDepot` requisites) is the real guard.

---

## Status

- **aarch64-linux (16K Asahi)** is the primary, hardware-tested host: the wine path (native + i386 WoW64) and the box64 thin path are verified across the 17 packaged titles (per-title status in `docs/verified/` and `broken.systems`).
- **x86_64-linux** is structured and evaluates (same wine source native, standard DXVK/vkd3d, `native` thin backend) but is unbuilt/untested on real hardware.
- The thin **fex** backend is research/`meta.broken` (D12). **muvm** remains an unshipped escape hatch.

---

## Risks & open questions (with the experiment that resolves each)

1. **box64 `BOX64_LD_LIBRARY_PATH` split (unverified).** We put the whole union on `LD_LIBRARY_PATH` (proven). *Experiment:* guest-only on `BOX64_LD_LIBRARY_PATH`, native-only on `LD_LIBRARY_PATH`; adopt only if it renders identically.
2. **`pkgsX86` cache durability across bumps (fatal if missed).** *Experiment:* at each candidate rev, narinfo-HEAD the box64 guest closure roots; hold the bump on any miss (D6). Mechanize as `checkX86GuestCache` in `flake.checks`; if misses become frequent, split the guest libs onto a separate rarely-bumped pin.
3. **The x86_64-linux host path.** Evaluates but unbuilt. *Experiment:* build + launch-smoke Hollow Knight (steam/linux, `native` backend) and one wine title on real x86_64 hardware.
4. **FEX SMC tracking on 16K.** The thin-FEX wall (D12) is upstream. *Experiment:* re-run `.apply { backend = "fex"; }` on each FEX release (or any 4K host); a mapped, rendered window reactivates the backend by deleting its `brokenSystems`.
5. **`wowbox64.dll` vs `libwow64fex.dll` per title (unverified which wins).** *Experiment:* A/B the 32-bit backend DLL on an i386 title; watch for mis-JIT.
6. **box64 BOX32 for 32-bit Linux on 16K (unverified).** *Experiment:* run a 32-bit x86 ELF under BOX32 on the Asahi host; if it works, extend the platform enum + `resolveStrategy` (today `i386-linux` is simply not a platform).
7. **wine-11 4K-on-16K per-title reliability.** Per-game boot test on the 16K host; titles that fault get `broken.systems` (KSP) or a muvm variant.

---

## Rejected alternatives

- **RtEnv IR / layer monoid / single-exec collapse.** Elegant on paper; net-adds a wide weakly-typed record + `mergeRtEnv` monoid + `abi.route` + a 3-mode `realise` *on top of* the entire existing wine stack (nothing deleted). Debuggability regresses (invert a fold across N layers + the Rust launcher); the ABI cursor rejects only compositions nobody writes while every real failure is "reachable but broken"; `mergeRtEnv` is claimed commutative but `LD_LIBRARY_PATH` order is load-bearing. **Kept:** layer-namespaced tuning, the resolve-twice library pairing, the 3-rung fetcher idea.
- **evalModules with submodule-typed knobs and a mandated big-bang generic renderer** (the original draft-B proposal). What was wrong with it — per-field knob merge reintroducing reason-bleed, opaque deep-type errors, materialized field defaults, dispatch inside the fixpoint — is exactly what the shipped module system (D16) avoids: **custom leaf types** merge each knob whole and reproduce the `sealing` algebra byte-for-byte (gated by a golden diff during the port), `resolveStrategy` stays a pure function outside the fixpoint, wine options carry no defaults (the base layer defines every knob), and the builders under the surface are plain functions a nixpkgs contributor can read cold.
- **"No framework" boring nixpkgs clone.** Its `wineApp` *is* the wine engine minus DLC, fixed-point tuning, the three-way `user.reg` merge, `extraSystem32`, galaxy stubs — the deletions get re-invented ad-hoc per game; its mutable-`$HOME` first-run prefix + non-idempotent DXVK staging reintroduce exactly the stale-prefix heisenbugs the store-seeded overlay was built to kill; it forgets `dontStrip` on foreign ELFs. **Kept:** the nixpkgs-shaped `makeScope`/`callPackage` skeleton, auto-discovery, `versions.json`, the verified manifest.
- **A payload/dlcPayloads split.** `payloads` stays a **list** — Stellaris's two co-equal base depots justify it; DLC is a separate axis (`dlc.available`/`dlc.enabled`).
- **Open `attrsOf` typing for the fetch matrix.** Trades away eval-time typo safety; the option tree is generated from the registries instead (D16), so a misspelled fetcher or platform is an "option does not exist" error.
- **`pkgsCross.gnu64` for guest libs** — cache-miss world rebuild the Asahi host can't perform. **`autoPatchelfHook` on foreign-arch payloads** — arch-gated `SkipFile`; needs qemu. **box86 on 16K** — dead. **vuizvui `fetchGog`** — Cloudflare/reCAPTCHA-dead, interactive by construction. **Nested box64∘wine as default for Windows x86_64 on aarch64** — two translation layers vs Hangover's one, and box64 is i386-only (it cannot drive x86_64 ARM64EC); use arm64ec wine + `HODLL64`. **muvm as default** — rendering broken on this host. **Two nixpkgs pins for guest libs** — rejected for single-source-of-truth; revisit only if D6's gate trips often.
