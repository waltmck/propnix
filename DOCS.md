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
  `user.overlay.metacopy` / `user.overlay.redirect` xattrs (see `lib/mkStoreSkeleton.nix` and
  `mount_overlay` in `pkgs/propnix-mount/src/main.rs`). This needs a kernel that allows overlayfs mounts
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

- **A GOG account that owns the title, and its Galaxy token.** Payloads are fetched as content-addressed
  FODs pinned by GOG `buildId`. Add an account with `propnix cred add gog` (browser login → token stored in
  `/var/lib/propnix`, `nixbld`-readable); the token is **never** copied into the store or printed
  (download-only). Multiple accounts are supported — the fetcher tries each until one owns the pinned build.
  See **Credentials** in the README. `--extra-sandbox-paths` requires a **trusted Nix user**.
- **Build closure.** aarch64 builds the full emulator closure the first time (Hangover wine ~1 h, FEX
  DLLs, ARM64EC DXVK/vkd3d, llvm-mingw); pin nixpkgs to the flake's rev so these substitute rather than
  rebuild. x86_64 builds the same wine source natively (no FEX).

## Layout

| path | what |
|---|---|
| `flake.nix` | pins nixpkgs 26.11; exposes `packages`/`legacyPackages`/`lib`/`apps` + `nixosModules` for `aarch64-linux` and `x86_64-linux` |
| `lib/default.nix` | the package set — a `lib.makeScope` where `callPackage` wires every edge by arg name, branching on host arch for the emulator set |
| `lib/makeAppWine.nix` | the arch-transparent game wrapper: a spec → a package invoking `propnix-launcher` with a baked JSON config (the launcher↔wrapper interface) |
| `lib/wine-defaults.nix` | global tuning base every game inherits: d3d/graphics defaults, DLL-override hygiene, HKCU `userReg`, and the **mount-table model** (read-only system tree + CoW profile overlays) |
| `lib/sealing.nix` | pure-lib data model: typed-tuning (`{ value; reason; }`) flatten/merge + the §7 env-seal record |
| `lib/mkStoreSkeleton.nix` | data-only overlay skeleton (sparse sized stubs → reproducible tar) so an unprivileged overlay can CoW over a root-owned store tree |
| `lib/mkWineReg.nix` | declarative per-game registry hive (wine-generated base + overrides via `wine reg add`) |
| `lib/desktop-item.nix` · `lib/extract-pe-icon.nix` | the `.desktop`/symbolic-icon builder · pull the app icon from the exe's PE resources → a freedesktop hicolor theme |
| `lib/fetchers/fetchGogGalaxyBuild/` | GOG Galaxy depot fetcher (gogdl FOD, buildId-pinned; arch-independent NAR) |
| `emulators/` | `wine-hangover` (same source both arches), `fex-dlls` + `galaxy-stub` + `llvm-mingw` + `box64` (aarch64), `dxvk-arm64ec`/`dxvk-x86_64`, `vkd3d-proton-arm64ec`/`vkd3d-proton-x86_64`, `wine-prefix-lower` (the read-only system tree) |
| `pkgs/propnix-launcher/` | the Rust launcher (GTK4 splash + single-instance + env-seal + mount-table orchestration) |
| `pkgs/propnix-mount/` | the Rust mount helper: unshares a private user+mount ns, lays the declarative bind/overlay table, and re-execs the launcher inside it |
| `pkgs/propnix-prefetch/` | cold-launch page-cache warmer (`posix_fadvise`) |
| `pkgs/games/<name>/` | one game per directory — `default.nix` + pinned `versions.json` + `tuning.nix`; auto-discovered into the scope + a flake package/app |
| `nixos/propnix.nix` | host module: binds the credential dir into the build sandbox + loads `ntsync` |
| `config/` | credential model + host-capability facts (reference) |
| `preliminaries/` | the validated POCs + design docs (`PLAN2.md`, `RESEARCH.md`) — the spec the tree ports from |

## Adding a game

Drop a directory under `pkgs/games/<name>/` — it's auto-discovered into the scope and exposed as
`.#<name>`. A minimal game is three files:

- **`versions.json`** — the pinned GOG payload: `productId` (numeric), `buildId`, `version`, and the
  recursive `outputHash` (SRI). Obtain the hash by running the credentialed fetch once and copying the
  reported hash.
- **`default.nix`** — calls `makeAppWine` with `pname`/`appid`/`name`, the `payload` (a
  `fetchGogGalaxyBuild` of the pins), and `exe` (the executable relative to the payload). Optional:
  `exeArgs`, `galaxyStubDlls` (payload-relative paths of bundled GOG Galaxy SDK DLLs to stub on aarch64),
  `extraSystem32` (stage a genuine MS runtime DLL over a builtin), `systemReg`/`userdefReg` (declarative
  HKLM/`.Default` overrides), `iconSymbolic`, and `brokenSystems`/`brokenReason`.
- **`tuning.nix`** — per-game overrides layered over `lib/wine-defaults.nix`. Typically just the **save
  mount** (bind the game's Windows save path out to `$PROPNIX_SAVE_DIR/$PROPNIX_APPID`). Scalar knobs are
  authored `{ value; reason; }` (the reason is enforced at eval). Mount rows can add an entry, override one
  field of a default, or disable one. See `pkgs/games/hollow-knight/` (simple), `pkgs/games/outlast/`
  (`extraSystem32`), and `pkgs/games/kerbal-space-program/` (writable game-dir overlay + a seeded tmpfs).

## Scope & backlog

**In:** the wine path on **aarch64-linux** (validated by Hollow Knight) + **x86_64-linux** (structured +
evaluates; unbuilt/untested). **Backlog:** building/testing the x86_64 target on real hardware; the box64
Linux-guest path (+ a `makeAppWine` emulator arg to pick FEX vs box64); MS-Store; MangoHud on non-DXVK
backends; a `propnix login` credential helper; a winewayland **xdg-activation** patch (would let the game
open on the splash's monitor/workspace, and extend focus-on-duplicate to GNOME/KDE); `updateScript`/CI.
See `preliminaries/PLAN2.md` §Backlog.
