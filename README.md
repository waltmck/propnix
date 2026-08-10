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
emulator closure; subsequent launches are warm. A GTK splash covers the cold start and dismisses on DXVK's
first frame.

## Layout

| path | what |
|---|---|
| `flake.nix` | pins nixpkgs 26.11; exposes `packages`/`legacyPackages`/`lib`/`apps` for `aarch64-linux` |
| `lib/default.nix` | the package set — a `lib.makeScope` where `callPackage` wires every edge by arg name |
| `lib/{sealing,desktop-item,makeAppWine}.nix` | §7 env-seal model · `.desktop`/symbolic-icon builder · the arch-transparent app wrapper |
| `lib/extract-pe-icon.nix` | pull the app icon from the exe's PE resources → a freedesktop hicolor theme (all sizes) |
| `lib/winefex-defaults.nix` | global tuning base every game inherits: d3d/graphics, DLL overrides, and `userReg` HKCU overrides (e.g. the black window background) re-applied each launch |
| `lib/fetchers/fetchGogGalaxyBuild/` | GOG Galaxy depot fetcher (gogdl FOD, buildId-pinned; arch-independent) |
| `emulators/` | `wine-hangover` (same source both arches), `fex-dlls` (aarch64), `dxvk-arm64ec`+`dxvk-x86_64`, `vkd3d-proton-arm64ec`+`vkd3d-proton-x86_64`, `wine-prefix-lower`, `llvm-mingw/` (aarch64), `box64-latest` |
| `pkgs/propnix-launcher/` | the Rust launcher (GTK4 splash + single-instance + env-seal + prefix orchestration) |
| `pkgs/propnix-prefetch/` | cold-launch page-cache warmer (`posix_fadvise`) |
| `pkgs/games/hollow-knight/` | the game package: `default.nix` + pinned `versions.json` + `tuning.nix` |
| `config/` | credential model + host-capability facts (reference) |
| `preliminaries/` | the validated POCs + design docs (`PLAN2.md`, `RESEARCH.md`) — the spec the tree ports from |

## How it runs

`makeAppWine` turns a game spec into `bin/<name>` — a wrapper around `propnix-launcher` with a baked
JSON config (store paths + defaults + the seal). The scope injects the arch-appropriate emulator set
(aarch64 → wine+FEX+ARM64EC DXVK/vkd3d; x86_64 → native wine + standard DXVK/vkd3d), but the launcher,
config, and game spec are identical. At launch the launcher:

1. **single-instance** — an flock keyed on the appid; a duplicate launch focuses the running window and
   exits. Focus works via EWMH `_NET_ACTIVE_WINDOW` on X11/Xwayland, and via `wlr-foreign-toplevel-management`
   on Wayland (matching the game's app_id, or — while the game is still cold-starting — this game's startup
   splash) — portable across the wlroots family (Hyprland/sway/Wayfire/river) + COSMIC; a graceful no-op on
   GNOME/KDE, which don't advertise it.
2. **prefix** — assembles a symlink-farm `WINEPREFIX`: read-only content symlinked from the store
   `wine-prefix-lower` (wineboot + FEX DLLs + Wow64 keys), writable content (HKCU, the profile) real and
   persistent. On the DXVK backend, `system32` is rebuilt as per-file symlinks with the native ARM64EC
   DXVK/vkd3d DLLs dropped in.
3. **saves** — binds the declared save out of the prefix to a host dir (created, or launch refuses).
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
| `PROPNIX_BENCH` | on-screen DXVK HUD (fps/frametime/GPU/driver/version) |
| `PROPNIX_SAVE_DIR` | global saves root, namespaced per app (`$PROPNIX_SAVE_DIR/<appid>`) |
| `PROPNIX_WINEDEBUG` | override `WINEDEBUG` (default `-all`) |
| `PROPNIX_NO_PREFETCH` | skip the cold-launch prefetch |
| `PROPNIX_WINE_BIND` | extra `;`-separated `GUESTREL|HOSTPATH` binds |

Debug escape hatches: `--shell` (sealed shell in the prefix), `--propnix-unseal` (skip the scrub).

## Credentials

The credentialed fetch needs a GOG token, kept **out of the store**. Put the token dir path in
`/propnix/credentials.toml` (`credentialDir = "…"`), make it `nixbld`-readable, and bind `/propnix` into the
build sandbox. See `config/credentials.nix` for the full model.

## Scope & backlog

**In:** the wine path on **aarch64-linux** (validated by Hollow Knight) + **x86_64-linux** (structured +
evaluates; unbuilt/untested). **Backlog:** building/testing the x86_64 target on real hardware; the box64
Linux-guest path (+ a `makeAppWine` emulator arg to pick FEX vs box64); MS-Store; MangoHud on non-DXVK
backends; a `propnix login` credential helper; a winewayland **xdg-activation** patch (would let the game
open on the splash's monitor/workspace, and extend focus-on-duplicate to GNOME/KDE); `updateScript`/CI.
See `preliminaries/PLAN2.md` §Backlog.
