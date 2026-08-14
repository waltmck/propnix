# propnix

Reproducible Nix packaging of proprietary games/apps (GOG, MS Store) to run on Linux **without muvm** —
via `wine`, with the x86_64-Windows CPU emulated transparently per host:

- **aarch64-linux** (primary/tested): `wine` (Hangover ARM64X-hybrid) + `FEX` + native ARM64EC DXVK/vkd3d.
- **x86_64-linux**: the **same wine source** built native (no FEX) + standard x86_64 DXVK/vkd3d.

The two hosts run the SAME game package with identical external behavior (every `PROPNIX_*` knob); the
emulation is handled below the launcher. First title: **Hollow Knight** (Windows build). The x86_64 target
is structured + evaluates but is so far **unbuilt/untested** (no x86_64 builder on hand).

```
nix run .#hollow-knight --extra-sandbox-paths /propnix=/var/tmp/propnix   # aarch64-linux or x86_64-linux
```

The first launch fetches the pinned GOG build (credentialed FOD — see **Credentials**) and builds the
emulator closure; subsequent launches are warm. A GTK splash covers the cold start and dismisses on the
game's first frame.

## Requirements

propnix assembles a throwaway `WINEPREFIX` per launch out of **kernel bind/overlay mounts in a private
user+mount namespace** — no root, no setuid helper, no persistent prefix. That design leans on several host
capabilities. The launcher hard-fails with an actionable message when unprivileged user namespaces are
missing; the other capabilities surface as a mount error at launch if absent.

**At a glance** (details below):

| requirement | needed for | required? |
|---|---|---|
| Unprivileged user namespaces (`CONFIG_USER_NS`, `user.max_user_namespaces > 0`) | assembling the prefix (`propnix-mount`) | **hard** — launcher refuses to start without it |
| Unprivileged overlayfs + `userxattr` in a userns (Linux **5.11+**) | copy-on-write prefix/game/save overlays over the store | **hard** — mount error at launch without it |
| `user.*` xattrs + overlay-upper support on `$XDG_STATE_HOME` & saves fs (ext4/xfs/btrfs/tmpfs; ZFS **≥ 2.2**) | persisting the overlay *uppers* | **hard** |
| A Vulkan ICD (e.g. Mesa on Asahi) | the default DXVK/vkd3d D3D backend | hard *unless* `PROPNIX_WINE_D3D=wined3d` |
| Wayland (+ Xwayland) or X11 | the GTK4 splash + the game window | **hard** |
| `/dev/ntsync` (Linux **6.14+**) | fast wine synchronization | strongly recommended (wine falls back to server-sync) |
| `wlr-foreign-toplevel-management` compositor | single-instance raise, splash dismiss, close-to-quit | optional (degrades gracefully) |
| GOG account owning the title + Galaxy token | **building** a game payload (FOD fetch) | build-time only |

### To run a game

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

### To build a game payload

- **A GOG account that owns the title, and its Galaxy token.** Payloads are fetched as content-addressed
  FODs pinned by GOG `buildId`. You supply `galaxy_tokens.json` (lgogdownloader's token) via a bind into
  the build sandbox; the token is **never** copied into the store or printed (download-only). See
  **Credentials**. `--extra-sandbox-paths` requires a **trusted Nix user**.
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

## How it runs

`makeAppWine` turns a game spec into `bin/<name>` — a wrapper around `propnix-launcher` with a baked
JSON config (store paths + defaults + the seal + the mount table). The scope injects the arch-appropriate
emulator set (aarch64 → wine+FEX+ARM64EC DXVK/vkd3d; x86_64 → native wine + standard DXVK/vkd3d), but the
launcher, config, and game spec are identical. At launch the launcher:

1. **single-instance** — an flock keyed on the appid; a duplicate launch focuses the running window and
   exits. Focus works via EWMH `_NET_ACTIVE_WINDOW` on X11/Xwayland, and via `wlr-foreign-toplevel-management`
   on Wayland (matching the game's app_id, or — while the game is still cold-starting — this game's startup
   splash) — portable across the wlroots family (Hyprland/sway/Wayfire/river) + COSMIC; a graceful no-op on
   GNOME/KDE, which don't advertise it.
2. **prefix** — assembles the `WINEPREFIX` from a **declarative mount table** (there is no symlink farm and
   no seeding step): `propnix-mount` unshares a private user+mount namespace and lays a fresh tmpfs at the
   view root, then binds the read-only system tree (`wine-prefix-lower`: `C:\Windows`, Program Files,
   dosdevices, the HKLM/`.Default` hives) and stacks **CoW overlays over the store** for the writable parts
   (the user profile, `ProgramData`, the `HKCU` hive) so writes persist to `$XDG_STATE_HOME` without any
   copy. On the DXVK backend, the native ARM64EC DXVK/vkd3d DLLs are bound over the matching `system32`
   builtins.
3. **saves** — the declared save location is a mount row binding a host dir out of the prefix (created on
   first launch, or the launch refuses if you pointed `PROPNIX_SAVE_DIR` somewhere missing).
4. **seal** — a *targeted* env scrub (unset only `WINE*`/`FEX_*`/`BOX64_*`/`LD_*`, keep the rest of the
   session env) then sets the meant vars. Never `env_clear()`.
5. **run** — spawns wine in its own process group; tears down **prefix-scoped** (`wineserver -k`) on exit —
   never a global process-name kill.

### `PROPNIX_*` — global runtime knobs

Every default the config bakes is overridable by an env var, so a user or NixOS module can set one once to
steer **all** games:

| var | effect |
|---|---|
| `PROPNIX_WINE_D3D` | `dxvk` (default) or `wined3d` |
| `PROPNIX_WINE_GRAPHICS` | `wayland` (default for HK) or `x11` |
| `PROPNIX_FPS` | frame cap (any positive int) → `DXVK_FRAME_RATE`, **and forces vsync off** (`dxgi.syncInterval=0`) so the cap paces via timer instead of FIFO vblank quantization. DXVK/vkd3d only (no-op on wined3d). Unset → the game's own vsync/cap are left untouched. |
| `PROPNIX_BENCH` | on-screen **MangoHud** overlay on the Vulkan backend (DXVK + vkd3d) — fps/frametime/CPU/versions (GPU stats need a MangoHud-supported driver; blank on Asahi). On wined3d there is no overlay — fps prints to the console via wine's `+fps` channel. Also tees the game's output to the console. |
| `PROPNIX_DEBUG` | tee the game's merged stdout+stderr to the launcher's stdout (no bench overlay) — for troubleshooting a launch |
| `PROPNIX_SAVE_DIR` | global saves root, namespaced per app (`$PROPNIX_SAVE_DIR/<appid>`). Set-but-missing is a hard error; unset → `$XDG_DATA_HOME/propnix-saves`. |
| `PROPNIX_WINEDEBUG` | override `WINEDEBUG` (default `-all`) |
| `PROPNIX_NO_PREFETCH` | skip the cold-launch prefetch |
| `PROPNIX_EXTRA_BINDS` | extra `;`-separated `TARGET\|SOURCE` bind rows (TARGET prefix-relative or `$`-expandable; SOURCE an absolute/`$`-expandable host path) — an ad-hoc redirect (e.g. a secondary saves/mods dir) without a rebuild |

Debug escape hatches: `--shell` (sealed shell in the prefix), `--propnix-unseal` (skip the scrub).

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

## Credentials

The credentialed fetch needs a GOG token, kept **out of the store**. Put the token dir path in
`/propnix/credentials.toml` (`credentialDir = "…"`), make it `nixbld`-readable, and bind `/propnix` into the
build sandbox (`--extra-sandbox-paths /propnix=…`, or `services.propnix.enable` + `credentialsPath`). The
token dir should contain **exactly** `galaxy_tokens.json` and nothing else — every download parameter is
pinned in `versions.json`, so the bind can only make a fetch succeed or fail, never change *what* is
fetched. See `config/credentials.nix` for the full model.

## Scope & backlog

**In:** the wine path on **aarch64-linux** (validated by Hollow Knight) + **x86_64-linux** (structured +
evaluates; unbuilt/untested). **Backlog:** building/testing the x86_64 target on real hardware; the box64
Linux-guest path (+ a `makeAppWine` emulator arg to pick FEX vs box64); MS-Store; MangoHud on non-DXVK
backends; a `propnix login` credential helper; a winewayland **xdg-activation** patch (would let the game
open on the splash's monitor/workspace, and extend focus-on-duplicate to GNOME/KDE); `updateScript`/CI.
See `preliminaries/PLAN2.md` §Backlog.
