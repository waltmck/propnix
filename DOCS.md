# propnix — documentation

Detailed reference for propnix. See **[README.md](README.md)** for the overview, the `PROPNIX_*` runtime
knobs, how it runs, and credentials.

## To run a game

- **Unprivileged user namespaces.** `propnix-mount` does `unshare(CLONE_NEWUSER | CLONE_NEWNS)` and maps
  your own uid/gid to gain `CAP_SYS_ADMIN` *inside* the namespace so it can bind-mount the prefix. The
  launcher probes for this first (`mount::userns_supported`) and refuses to start otherwise. You need a
  kernel with `CONFIG_USER_NS=y` and `user.max_user_namespaces > 0`; on distros that gate it behind a
  sysctl, enable `kernel.unprivileged_userns_clone=1` (Debian/Ubuntu — persist under `/etc/sysctl.d`).
  NixOS and Asahi enable this by default.

- **Unprivileged overlayfs in a user namespace, with `userxattr`.** The writable parts of the prefix (the
  user profile, `ProgramData`, the `HKCU` hive, and any per-game writable game dir such as KSP's) are
  **copy-on-write overlays over the read-only Nix store**, mounted with the `userxattr` option and the
  `user.overlay.metacopy` / `user.overlay.redirect` xattrs (see `lib/builders/store-skeleton.nix` and
  `mount_overlay` in `pkgs/propnix-mount/src/lib.rs`). This needs a kernel that allows overlayfs mounts
  inside a user namespace and supports `userxattr` + metacopy/redirect — mainline **Linux 5.11+**.

- **User xattrs (and overlay-upper support) on the state/save filesystems.** The persistent overlay
  *uppers* live under `$XDG_STATE_HOME/propnix/<appid>` (and overlay-based saves under
  `$PROPNIX_SAVE_DIR`). That filesystem must support the `user.*` xattr namespace **and** be usable as an
  overlayfs upperdir — ext4 / xfs / btrfs / tmpfs all qualify; **ZFS needs OpenZFS ≥ 2.2**.

- **`ntsync` — the in-kernel Windows sync driver (`/dev/ntsync`).** wine 11 auto-detects and uses it for
  fast, correct synchronization (no wine env knob — it is enabled purely by the device being present and
  accessible). The NixOS module (`services.propnix.enable`) loads the module for you. On other hosts, ensure
  the char device exists and is readable by your user (`sudo modprobe ntsync`) — it needs a kernel with the
  `ntsync` driver, **mainlined in Linux 6.14**. If `/dev/ntsync` is absent wine falls back to slower
  server-side synchronization, so this is strongly recommended rather than strictly required.

- **A Vulkan driver.** The default D3D backend is **DXVK/vkd3d-proton**, which renders D3D9/10/11/12
  through Vulkan (via winevulkan). You need a working Vulkan ICD (e.g. Mesa on Asahi). To avoid Vulkan
  entirely, set `PROPNIX_WINE_D3D=wined3d` (wine's GL/GDI path). On Asahi, MangoHud's GPU stats are blank
  (driver unsupported) but fps/frametime/CPU render.

- **A display: Wayland (with Xwayland), or X11.** The default wine display driver is **winewayland**
  (`graphics=wayland`); `PROPNIX_WINE_GRAPHICS=x11` selects the X11 driver (native X or Xwayland). The GTK4
  splash and the game window both need a display server.

- **(Optional) a `wlr-foreign-toplevel-management` compositor.** `focus.rs` uses this protocol to (a) raise
  the running window when you launch a game that's already open, (b) dismiss the splash for OpenGL titles
  that emit no first-frame log marker, and (c) force teardown when you close the game window (some wine
  games hang on shutdown). It's present on the wlroots family (Hyprland/sway/Wayfire/river) and COSMIC. On
  GNOME/KDE or plain X11 it degrades gracefully: single-instance raise falls back to X11 EWMH
  (`_NET_ACTIVE_WINDOW`), and the splash falls back to the first-present marker / timeout.

## To build a game payload

- **An account that owns the title (GOG or Steam), and its token.** Payloads are fetched as
  content-addressed FODs pinned in `versions.json` — GOG Windows builds by Galaxy `buildId`, Steam builds by
  `(appId, depotId, manifestId)`. Add an account with `propnix cred add gog` / `propnix cred add steam`
  (token stored in `/var/lib/propnix`, `nixbld`-readable); the token is **never** copied into the store or
  printed (download-only). Multiple accounts are supported — the fetcher tries each until one owns the
  pinned content. See **Credentials** in the README. `--extra-sandbox-paths` requires a **trusted Nix user**.
- **Build closure.** aarch64 builds the full emulator closure the first time (Hangover wine ~1 h, FEX
  DLLs, ARM64EC DXVK/vkd3d, llvm-mingw); pin nixpkgs to the flake's rev so these substitute rather than
  rebuild. x86_64 builds the same wine source natively (no FEX).

## Configuration — which store, which build

State your stores ONCE, nixpkgs-config-style; every game resolves its `(fetcher, platform)` from that,
purely at eval (credentials are **never** probed — a mis-stated config fails at fetch time exactly like a
missing account):

```nix
# instantiate a configured scope …
(propnix.lib.mkScope {
  inherit pkgs;
  config.preferredFetchers = [ "steam" "gog" ];   # ranked ALLOWLIST, best first
}).hollow-knight
# … or re-base an existing one:
scope.overrideScope (final: prev: { propnixConfig.preferredFetchers = [ "gog" ]; })
```

Semantics (D17): each game ranks its pinned **platforms** by quality (`platformPreference`; derived
automatically for single-platform games); resolution is platform-major — for each game-ranked platform,
the first of your `preferredFetchers` that pins it wins. Your account preference can shift a game's
platform only along the game's own ranking (a gog-only user gets Hollow Knight's sanctioned
gog/x86_64-windows fallback; a game with no reachable pair errs legibly, never degrades silently). The
default — all fetchers, registry order — makes no account statement. The list shapes *defaults*:
`.apply { fetcher = …; }` still selects anything pinned. `scope.resolvableGames` filters the catalog by a
pure resolvability probe. The standing gate `checks.<system>.config-resolution` pins every game's resolved
triple + the guard semantics.

## Layout

| path | what |
|---|---|
| `flake.nix` | pins nixpkgs 26.11; exposes `packages`/`legacyPackages`/`lib`/`apps` + `nixosModules` for `aarch64-linux` and `x86_64-linux` |
| `lib/default.nix` | the package set — a `lib.makeScope` where `callPackage` wires every edge by arg name, branching on host arch for the emulator set; holds the two registries (`fetchers`, `backends`) and auto-discovers `pkgs/games/*` |
| `lib/mk-app.nix` | `mkApp` — the `evalModules` dispatcher: a game module (two orthogonal axes: `fetcher` × `emulatedPlatform`) → the selected backend's builder, plus the `.apply`/`.extend`/`.config`/`withDlc` override surface |
| `lib/modules/` | `app-options.nix` (the typed top-level option schema, incl. the generated `fetchInfo.<fetcher>.<platform>` fetch matrix) + `types.nix` (the `knob`/`lastWins`/`dedupList` custom leaf types) |
| `lib/strategy.nix` | `resolveStrategy` — the pure backend-selection function (the `backend` option default) |
| `lib/backends/<name>/` | one self-contained backend registry entry each (`{ modules; build; }`): `wine/` (options + the platform-aware base tuning layer `defaults.nix`), `box64/` (also serves `native`), `fex/` (research; `meta.broken` on 16K), plus `mk-thin-build.nix` (the shared thin dispatch-arm assembler + launch-block contract) |
| `lib/builders/` | `wine.nix` (`mkWineApp` — resolved config → PREFIX-mode package), `thin.nix` (`mkThinApp` — THIN mode), `launcher-package.nix` (the shared packaging tail: wrapper + `.desktop` + meta), `store-skeleton.nix`, `wine-reg.nix`, `desktop-item.nix`, `setup-script.nix` (+ the shared `ini-lib.sh`) |
| `lib/icons/` | three icon sources over one shared pipeline: `from-png.nix` (game-data raster, preferred), `from-pe.nix` (exe PE resources), `from-unity.nix` (UnityPlayer.png) → hicolor theme + splash |
| `lib/sealing.nix` | pure-lib data model: the tuning flatten (reason-strip) + the env-seal record + `defaultScrub` |
| `lib/presets/` | reusable tuning fragments (`unity.framePacing`, `unity.fullscreen`) + `mergeTuning` (collision-throwing compose) |
| `lib/fetchers/` | `fetchGogGalaxyBuild/` (gogdl FOD, buildId-pinned), `fetchGogLinuxInstaller.nix` (lgogdownloader, latest-only), `fetchSteamDepot.nix` (DepotDownloader, manifest-pinned) + the shared `cred-lib.sh` prologue |
| `emulators/` | `wine-hangover` (same source both arches), `fex-dlls` + `galaxy-stub` + `llvm-mingw` + `box64` (aarch64), `dxvk-arm64ec`/`dxvk-x86_64`, `vkd3d-proton-arm64ec`/`vkd3d-proton-x86_64`, `wine-prefix-lower` (the read-only system tree) |
| `pkgs/propnix-launcher/` | the Rust launcher (GTK4 splash + single-instance + env-seal + mount-table orchestration, PREFIX + THIN modes); links `pkgs/propnix-mount/` (the userns bind/overlay layer) and `pkgs/propnix-prefetch/` (the `posix_fadvise` page-cache warmer — run by the wine INNER over the assembled prefix, PE modules only: `.dll`/`.drv`/`.exe`) as library crates — they are not separate packages |
| `pkgs/games/<name>/` | one game per directory — `default.nix` (the `mkApp` module) + pinned `versions.json` (the `fetchInfo` fetch matrix) + optional `wine-tuning.nix`/`box64-tuning.nix`/`setup.sh`; auto-discovered into the scope + a flake package/app |
| `nixos/propnix.nix` | host module: binds the credential dir into the build sandbox + loads `ntsync` |
| `config/` | credential model + host-capability facts (reference) |
| `docs/DESIGN.md` | the architecture decision record |
| `preliminaries/` | the validated POCs + historical design docs (`PLAN2.md`, `RESEARCH.md`) |

## Adding a game

Drop a directory under `pkgs/games/<name>/` — it's auto-discovered into the scope and exposed as
`.#<name>`. A minimal game is two files:

- **`versions.json`** — the fetch matrix, verbatim: `fetchInfo.<fetcher>.<platform> = [ argset … ]`, each
  arg-set passed as-is to that fetcher (GOG Windows: `pname`/`productId`/`buildId`/`version` + the
  recursive SRI `outputHash`; Steam: `pname`/`appId`/`depotId`/`manifestId`/`outputHash`; several arg-sets
  = several depots, unioned read-only at launch, first wins). Obtain the hash by running the credentialed
  fetch once and copying the reported hash. A populated pair *is* availability — an unpinned selection is
  a legible eval error.
- **`default.nix`** — a **module** passed to `mkApp`: `pname`/`appid`/`name`, `fetcher` and
  `emulatedPlatform` set with `lib.mkDefault` (so `.apply { fetcher = …; emulatedPlatform = …; }` can
  select any other pinned pair), `fetchInfo = (lib.importJSON ./versions.json).fetchInfo;`, and `exe`.
  Everything else is optional and may be set conditionally on the axes: `exeArgs`, `workingDir`,
  `saveBinds` (HOME-relative `dst` on every backend), `maskFiles` (runtime whiteouts for dlopen'd store
  DLLs), `env`, `icon.{png,symbolic,auto}`, `broken.{systems,reason}`, `dlc.available`, plus the
  backend namespaces below.
- **`wine-tuning.nix`** (as `wine = import ./wine-tuning.nix;`, or inline) — per-game knobs layered over
  the base layer in `lib/backends/wine/defaults.nix`: scalar knobs authored `{ value; reason; }` (the
  reason is enforced at eval), `galaxyStubDlls`, `extraSystem32`, `userReg`/`systemReg`/`userdefReg`,
  `setupScript` (via `mkSetupScript`), and `mounts` rows (add an entry, override one field of a default,
  or disable one). Unity titles compose `presets.unity.*` fragments with `presets.mergeTuning`.
- **`box64-tuning.nix`** (as `box64 = import ./box64-tuning.nix;`) — for Linux builds: the
  `bridgingLibs`/`guestLibs` library triage (`pkgs -> [drv]` functions).

See `pkgs/games/hollow-knight/` (the two-axis exemplar), `pkgs/games/stellaris/` (multi-depot Steam Linux
build under box64), `pkgs/games/outlast/` (`extraSystem32`), `pkgs/games/factorio/` (DLC), and
`pkgs/games/kerbal-space-program/` (writable game-dir overlay + a seeded tmpfs).

## Scope & backlog

**In:** the wine path (x86_64 + i386 Windows builds) and the box64/native thin path (x86_64 Linux builds),
GOG + Steam fetchers, 17 games — hardware-tested on **aarch64-linux**; **x86_64-linux** is structured +
evaluates (unbuilt/untested on real hardware). **Backlog:** building/testing the x86_64 target on real
hardware; a mechanical x86-guest cache-hit gate in `flake.checks`; MS-Store; MangoHud on non-DXVK
backends; a winewayland **xdg-activation** patch (would let the game open on the splash's
monitor/workspace, and extend focus-on-duplicate to GNOME/KDE); `updateScript`/CI. The thin FEX backend is
carried but `meta.broken` on 16K hosts (see `docs/DESIGN.md` D12).
