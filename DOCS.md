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

- **A Wayland compositor.** Every game runs inside **gamescope** (its Wayland backend), which is one
  Wayland client of your compositor: a window whose app_id is the game's `.desktop` id
  (`org.propnix.<appid>`, so it gets the game's icon and taskbar entry) and whose title is the game's name,
  fullscreen at `PROPNIX_WIDTH×PROPNIX_HEIGHT` (default: the primary output's mode). The game itself draws
  into gamescope's own Xwayland — wine through winex11 (`graphics=x11`), SDL through its x11 driver — so the
  compositor needs no Xwayland, and every game presents the same way whatever API it uses. gamescope needs
  the usual modern globals (`linux-dmabuf` v3+, `wp_viewporter`, `wp_presentation`, relative-pointer +
  pointer-constraints, `wl_seat` v8+) and composites with Vulkan. HDR reaches an HDR output through
  gamescope's color management when the compositor offers `wp_color_management_v1`; a title still opts in
  with `env.DXVK_HDR`. The GTK4 splash stays a native window of the compositor.

- **(Optional) `xdg_activation_v1`, for a duplicate launch focusing the running game.** No window is
  raised from outside: the duplicate hands its activation token (`XDG_ACTIVATION_TOKEN`, which a desktop
  sets for an entry with `StartupNotify=true` — every game's has it) to the running launcher over
  `$XDG_RUNTIME_DIR/propnix/<appid>/activate`, and the window being shown presents it itself — the GTK
  splash, or the game through gamescope (patch 0004, a root property on gamescope's X server). A shell
  launch has no token: gamescope then requests one stamped with its own last input, and the compositor's
  focus-stealing policy decides — Hyprland focuses with `misc:focus_on_activate = true` (otherwise it
  marks the window urgent), GNOME and KDE show their attention hint. Every major compositor implements
  the protocol, so no compositor-specific window management is involved.

  *Seeing* the game's window needs nothing from the compositor: the launcher reads gamescope's own nested
  X server (the window gamescope is showing) to dismiss the splash for titles that emit no first-frame
  marker and to tear down a game that hangs on shutdown after its window closes. Closing gamescope's window
  shuts the game down directly.

## To build a game payload

- **An account that owns the title (GOG or Steam), and its token.** Payloads are fetched as
  content-addressed FODs pinned in `versions.json` — GOG Windows builds by Galaxy `buildId`, Steam builds by
  `(appId, depotId, manifestId)`. Add an account with `propnix cred add gog` / `propnix cred add steam`
  (token stored in `/var/lib/propnix`, mode 0640 and **group-owned by the build-users group** `nixbld`,
  which is how a sandboxed fetch reads it); the token is **never** copied into the store or printed
  (download-only). Multiple accounts are supported — the fetcher tries each until one owns the pinned
  content. See **Credentials** in the README. `--extra-sandbox-paths` requires a **trusted Nix user**.
- **Nix's classic build users (`auto-allocate-uids = false`).** The builder reads the token through group
  membership; an auto-allocated build runs as a per-build synthetic uid/gid that is in no host group (and its
  user namespace doesn't map root), so only a world-readable token would work — which propnix declines to
  install. `services.propnix.enable` warns when the setting is on.
- **Build closure.** aarch64 builds the full emulator closure the first time (Hangover wine ~1 h, FEX
  DLLs, ARM64EC DXVK/vkd3d, llvm-mingw); pin nixpkgs to the flake's rev so these substitute rather than
  rebuild. x86_64 builds the same wine source natively (no FEX).

### What the credential store looks like on disk

`ls -la /var/lib/propnix` looks alarming on purpose, so here is the map before an audit flags it. The
type-level dirs (`gog/`, `steam/`) are `3777 root:nixbld` — the `/tmp` model, setgid + sticky +
world-writable — because any human must be able to `cred add` without privilege, while the token they
create must come out **group-owned by the build-users group** (`nixbld`): a sandboxed builder keeps only
that one primary gid (supplementary groups are dropped in its user namespace, and a POSIX ACL entry is
ignored on ZFS), and a human must never *be* in `nixbld`, so the group can only arrive by setgid
inheritance from the directory. World-writability stops at that level, which holds no secrets — only
account-dir names, and the sticky bit keeps one user from removing another's. Below it every account dir
is `2750 <owner>:nixbld` and every token `0640`, so a token has exactly two readers: the human who added
it and the build sandbox. The `cache/` sibling (`0777`, its `cache/steam` leaf `2777`) holds no secrets
by that standard either — Steam depot keys and manifest snapshots, each verified against a
`versions.json` hash before use, so anything a local user or a malfunctioning builder scribbles there is
just a cache miss. On NixOS the `propnix-credentials` unit re-converges the whole layout at every
activation.

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
| `lib/builders/` | `wine.nix` (`mkWineApp` — resolved config → PREFIX-mode package), `thin.nix` (`mkThinApp` — THIN mode), `launcher-package.nix` (the shared packaging tail: wrapper + `.desktop` + meta), `store-skeleton.nix`, `wine-reg.nix`, `desktop-item.nix`, `setup-script.nix` (+ the always-supplied `payload-lib.sh` and the opt-in `ini-lib.sh`) |
| `lib/icons/` | three icon sources over one shared pipeline: `from-png.nix` (game-data raster, preferred), `from-pe.nix` (exe PE resources), `from-unity.nix` (UnityPlayer.png) → hicolor theme + splash |
| `lib/sealing.nix` | pure-lib data model: the tuning flatten (reason-strip) + the env-seal record + `defaultScrub` |
| `lib/presets/` | reusable tuning fragments (`unity.framePacing`, `unity.fullscreen`) + `mergeTuning` (collision-throwing compose) |
| `lib/fetchers/` | `fetchGogGalaxyBuild/` (`propnix download gog` FOD, buildId-pinned), `fetchGogLinuxInstaller.nix` (lgogdownloader, latest-only), `fetchSteamDepot.nix` (`propnix download steam` FOD, manifest-pinned) + the shared `cred-lib.sh` prologue |
| `emulators/` | `wine-hangover` (same source both arches), `fex` (the ARM64EC DLLs wine loads) + `galaxy-stub` + `llvm-mingw` + `box64-latest` (aarch64), `fex-linux` (FEXInterpreter — a *different* target from `fex`: it runs i386/x86_64 **Linux** ELFs for the thin backend, and carries our large-host-page patches), `gbe-fork` (the offline Steam-entitlement shim, built per ABI), `dxvk-arm64ec`/`dxvk-x86_64`, `vkd3d-proton-arm64ec`/`vkd3d-proton-x86_64`, `wine-mono` (the .NET CLR every MANAGED title needs, pinned to wine's own `WINE_MONO_VERSION`), `wine-prefix-lower` (the read-only system tree — installs the CLR at `C:\windows\mono\mono-2.0`) |
| `pkgs/propnix-launcher/` | the Rust launcher (GTK4 splash + single-instance + env-seal + mount-table orchestration, PREFIX + THIN modes); links `pkgs/propnix-mount/` (the userns bind/overlay layer) and `pkgs/propnix-prefetch/` (the `posix_fadvise` page-cache warmer — run by the wine INNER over the assembled prefix, PE modules only: `.dll`/`.drv`/`.exe`) as library crates — they are not separate packages |
| `pkgs/games/<name>/` | one game per directory — `default.nix` (the `mkApp` module) + pinned `versions.json` (the `fetchInfo` fetch matrix) + optional `wine-tuning.nix`/`box64-tuning.nix`/`setup.sh`; auto-discovered into the scope + a flake package/app |
| `nixos/propnix.nix` | host module: binds the credential dir into the build sandbox, loads `ntsync`, trusts `propnix.cachix.org`, installs the `propnix` CLI, materializes declared credentials (sops-nix/agenix) |
| `ci/` | the gate scripts CI runs, each usable by hand: `eval-matrix.sh <system>` (one `nix eval` per pinned game × fetcher × platform), `cache-audit.sh <system>` (nothing non-unfree is left for users to compile), `pin-refresh.sh` + `pin-issue.sh` (weekly pin refresh and its issue lifecycle, with an offline `pin-issue-test.sh`), `gbe-interface-check.sh <system>` (every Steam pin's recorded `steamApiInterfaces` fingerprint held against the pinned gbe_fork by *asking the shim* — `gbeFork.interfaceOracle` runs it — no credential, so it runs on every push and every PR including forks (`eval.yml` for branches and PRs, `cachix.yml` for master pushes, after the shim is pushed); a row without the field is reported unverified, the fix being `propnix pin <game> --fingerprint`; `gbe-interface-check-test.sh` drives every verdict of it against stubs), `readme-tables.sh` (the README's two supported-games tables regenerated from the resolver and diffed; `--write` rewrites them, which is how you add a game to them) |
| `tools/` | `unwind-guest-stack.py` — an exact x86_64 guest-stack unwinder for FEX-under-ARM64EC-wine, where neither winedbg nor FEX can produce a backtrace and stack-scanning yields false frames |
| `config/` | credential model + host-capability facts (reference) |
| `docs/DESIGN.md` | the architecture decision record |
| `preliminaries/` | the validated POCs + historical design docs (`PLAN2.md`, `RESEARCH.md`) |

## Adding a game

Drop a directory under `pkgs/games/<name>/` — it's auto-discovered into the scope and exposed as
`.#<name>`. A minimal game is two files:

- **`versions.json`** — the fetch matrix, verbatim: `fetchInfo.<fetcher>.<platform> = [ argset … ]`, each
  arg-set passed as-is to that fetcher (GOG Windows: `pname`/`productId`/`buildId`/`version` + the
  recursive SRI `outputHash`; Steam: `pname`/`appId`/`depotId`/`manifestId`/`outputHash`; several arg-sets
  = several depots, unioned read-only at launch, first wins). A populated pair *is* availability — an
  unpinned selection is a legible eval error.

  Every Steam row also carries **`steamApiInterfaces`**: the interface-revision strings the depot's
  shipped `steam_api` libraries name (the union over all of them — per-arch copies included), captured
  by `propnix pin` while the bytes are in hand and held against the pinned gbe_fork by a CI check on
  every push and pull request (`ci/gbe-interface-check.sh`, a job of `eval.yml`). The check asks the
  shim itself: `gbeFork.interfaceOracle` runs the pinned build and requests each revision the way a
  game would, because the shim's dispatcher routes by prefix and exact ladders with fatal exits in
  some families and NULL in others, which no reading of its source reproduces. It is the pin-time
  answer to a runtime wall that is otherwise silent — a game whose SDK names a revision the shim lacks
  exits 73 at Steam init. The library names a *superset* of what the game requests, so a revision the
  shim lacks in a family the game never uses is declared per game in `steam.emu.neverRequested` (with
  the evidence) and reported as tolerated; a game with `steam.emu.enable = false` is exempt. Rows
  pinned before the field existed are backfilled, without moving them, by `propnix pin <game>
  --fingerprint`; a depot that ships no such library records `[]`. The scanner's pattern list
  (`pkgs/propnix-cli/steam-api-interface-patterns.txt`) is diffed against the pinned generator's on
  every run, so a new interface family upstream fails CI instead of going unrecorded. The gate covers
  interface revisions only: the flat `SteamAPI_*` export surface is not fingerprinted, so a game
  binary importing an export the shim lacks (a load-time failure, not the exit-73 init failure) is
  still caught only by a run.

  Two optional sibling sections: **`dlc`** (name → one arg-set per pack, mounted above the base when
  enabled — see the DLC framework) and **`extra`** (name → one arg-set for an upstream artifact that is a
  BUILD-TIME INPUT rather than payload content, never mounted). `extra` exists because a game may need
  bytes from a depot it does not run: civilization-5's Linux depots ship no icon at all, so it pins the
  Windows exe depot as `extra.icon` and lifts the icon out of that exe's PE resources. A `fetchInfo` row
  would instead declare that Windows build *available*, which it is not (it is CEG-stripped and cannot
  execute). `propnix pin` walks and advances `extra` with everything else, so such a pin moves as part of
  the same all-or-nothing unit.

  **Generate it with `propnix pin --new`** rather than by hand: it resolves the newest build and computes
  the hash by STREAMING the payload, so it needs no disk for the game (the old way — fetch with
  `lib.fakeHash` and copy the reported hash — needs free space equal to the title, which for a modern AAA
  game is hundreds of GB). It writes `pkgs/games/<name>/versions.json` itself, creating the directory.

  ```sh
  # GOG, plus any DLC (repeat --dlc).
  propnix pin <name> --new --gog --product-id 1238653230 --dlc space-age=1831417704

  # Steam: one --depot per depot you want (the platform is read from the depot's oslist).
  propnix pin <name> --new --steam --app 281990 --depot 281994 --depot 281991
  ```

  The `pname`s and the GOG `version` string it emits are correct-but-generic placeholders (`<name>-win`,
  `<name>-<depotId>`) — rename them to house style. Add `--gog-branch Experimental` to pin a named GOG
  release track (Factorio is pinned that way), `--branch <name>` for a Steam beta branch, `--os
  linux`/`--lang`, or `--platform i386-windows` when the build is 32-bit, which nothing upstream tells us.

  **DLC lives under a sibling top-level `dlc` key**, one named row per DLC, and `--new` only scaffolds the
  GOG form (`--dlc <name>=<dlcId>`, a second fetch of the same build). A Steam DLC has no `dlcId`: Steam
  ships it as its own DEPOT of the base app, so its row is an ordinary Steam arg-set (`appId` stays the
  BASE app; a DLC appid's appinfo lists no depots at all) placed under `dlc` rather than in `fetchInfo`.
  Paradox-style titles make the depotId the DLC's own store appid; when a game's DLC appid DIFFERS from
  its depot, state it in the row as `dlcAppId` (optional; unknown keys round-trip through `propnix pin`
  untouched). Write those rows by hand, with `propnix hash steam --app --depot --manifest` for each
  `outputHash`; that command also *is* the ownership probe, since Steam refuses the depot key (eresult 15)
  before a byte is downloaded for a DLC the account does not own. `pkgs/games/stellaris/` is the worked
  example. Re-pinning needs no extra flag either way — a `dlc` row carrying `appId` is classified as a
  Steam pin and refreshed from the same appinfo snapshot as the base depots.

  Declaring the rows is the whole job: every Steam-fetched game gets `steam.emu.enable` by default
  (modules/steam-emu.nix), which places the gbe_fork shim (emulators/gbe-fork, built from
  source once per ABI — natively for the host's arch, by cross-compilation for every foreign one, since
  the shim runs inside the game's own process; the Windows PE shims are still the pinned prebuilt) and projects the offline entitlement list from
  those SAME rows (`dlcAppId`, else `depotId`) — engines that ask the (absent) Steam client whether a DLC
  is owned get the answer automatically, DLC-less and vanilla builds included (empty list = "own
  nothing"). Thin (Linux-build) games are served by a preload; an engine that dlopens the `.so` by
  explicit path (Unity plugins) declares the copy in `steam.emu.libPaths` and gets the shim bound over
  it. Steam **Windows** builds declare the shipped `steam_api(64).dll` path(s) there instead — the
  matching gbe_fork dll is union-replaced over them with settings beside it (required on wine: PE has no
  preload; enabling the emu there with no `.dll` declared is an eval error). One wall: a game built
  against a newer Steamworks SDK than the gbe_fork pin (currently 1.64) needs the pin bumped first —
  triage with `nm -D` on the game's genuine lib (modules/steam-emu.nix documents the method).

  Two further knobs. `steam.emu.extraDlc` — entitlement rows merged into the set projected from
  `dlc.enabled` — for an engine that gates content on an appid the pin rows do not carry: Civ V reads a
  `<SteamApp>` out of each `.civ5pkg` descriptor and asks about THAT (34495 for the Mongols pack, whose
  depot's `dlcappid` is 16865), so claiming only the store id leaves every mounted pack inactive with no
  error anywhere. And `steam.emu.offline` (default `true`), needed only by titles that block on logon
  state, decides whether the shim reports the Steam client as sitting in offline mode. It is a statement about
  LOGON STATE and nothing else — in the pinned gbe_fork it reaches exactly `ISteamUser::BLoggedOn()`,
  `BConnected()` and `GetLogonState()`, while what the shim does on the wire stays governed by the
  untouched `disable_networking` / `disable_lan_only` keys. `true` is the honest answer wherever there is
  an offline path to take; set it `false` only where a run shows the game waiting forever on a "Steam
  client is coming back" that never does (`pkgs/games/victoria-3` is the worked example: flipping it alone
  turns "no log at all" into the engine's full log set and a D3D11 device — and note that the game there
  has a first-class single-player mode, so "is it online-only?" is NOT the test; a run is). Do not reach
  for it just because a title stops at its Steam step: `pkgs/games/rust` stops INSIDE `SteamAPI_Init`,
  before this key is ever consulted, and flipping it there changes nothing.

  Afterwards, `propnix pin <name>` moves a game to the newest build on the branch it already sits on,
  rewriting `versions.json` **in place** (temp file + same-directory rename, so an interrupted run can
  never leave a half-written pin; an up-to-date run writes nothing at all, not even an mtime). `--stdout`
  emits the document instead, for a caller that wants to validate before swapping — `ci/pin-refresh.sh`
  does. `propnix pin <name> --check` reports whether upstream has moved *without needing any credential*.
  Two repair modes exist for when a pin looks wrong: `--recompute` keeps the pinned version and recomputes
  only its `outputHash`, and `--latest` ignores the recorded build and branch entirely. Re-pinning is
  all-or-nothing per game — base payloads and every DLC together — because moving a base game without its
  DLC is exactly the mismatch that breaks at runtime.

  A re-pin of a large title runs for hours and **cannot be resumed** — the NAR is hashed strictly in tree
  order — so every network request it makes is retried: chunks get 13 retries, metadata 7, spaced
  exponentially (1s, 2s, 4s … capped at 32s). That is enough to ride out a laptop changing networks, a
  suspend/resume, or a CDN recycling a pooled connection, all of which arrive as a body that ends early.
  The budget is counted in **attempts**, never as a wall-clock deadline, precisely so time the machine
  spends asleep does not consume it. Anything the server answered deliberately — 401/403, a withdrawn
  manifest, a refused depot key — is *not* retried: those are answers, not accidents.

  Multi-account hosts need no per-game selection: `pin` tries every stored account of the relevant type
  until one owns the title, exactly as the fetchers do. Force one with `--gog-account <name>` /
  `--steam-account <name>`, or the `PROPNIX_GOG_ACCOUNT` / `PROPNIX_STEAM_ACCOUNT` environment variables
  (flag beats env beats try-all). A named account the store does not hold is an error listing the ones it
  does — never a silent fall-through to somebody else's.

  Three row keys are written by `propnix pin` itself rather than by you:

  - **`depsBuildId`** (GOG) — some builds install a dependency *into the game directory* (homeworld-rm's
    `language_setup`) from GOG's **global** dependency repository, which `buildId` does not pin: the tree
    can change without the build changing. This records which repository build the pinned `outputHash` was
    computed against, and `fetchGogGalaxyBuild` passes it to the download, which ASSERTS the repository
    still serves that build. So drift is reported as "the dependency repository moved" rather than as an
    unexplained FOD hash mismatch. The tool inserts and updates it; nobody needs to write it by hand.
  - **`version`** (Steam) — Steam publishes no human version strings, so this carries the branch **build
    id** from appinfo. It is provenance only (the fetcher ignores it), but it is what fills the version
    column of the PR table, the commit message and the update issue. A human may overwrite it with a
    marketing string ("1.5.78.11"); that survives until the pin next *moves* — and a `pin.version.steam`
    hold never moves, so a held label is stable.
  - **`branch`** (Steam, optional) — the Steam branch this manifest came from; absent means `public`. `pin`
    uses it as the default for both discovery and manifest request codes, so a beta-pinned game
    auto-updates *on its branch* without anyone remembering a flag (the explicit analogue of GOG's branch
    inference, which Steam manifests do not support). `--branch` overrides it for one run; the update flow
    never rewrites it. `fetchSteamDepot` appends `-beta <name>` only when it is not `public`, so existing
    pins are byte-identical. Passworded/hidden branches are out of scope: appinfo does not list them, and
    `pin` refuses rather than guessing.
- **`default.nix`** — a **module** passed to `mkApp`: `pname`/`appid`/`name`, `fetcher` and
  `emulatedPlatform` set with `lib.mkDefault` (so `.apply { fetcher = …; emulatedPlatform = …; }` can
  select any other pinned pair), `fetchInfo = (lib.importJSON ./versions.json).fetchInfo;`, and `exe`.
  Everything else is optional and may be set conditionally on the axes: `exeArgs`, `workingDir`,
  `saveBinds` (HOME-relative `dst` on every backend), `maskFiles` (runtime whiteouts for dlopen'd store
  DLLs), `env`, `icon.{png,symbolic,auto}`, `broken.{systems,reason}`, `allowBroken`, `x87ReducedPrecision` (one knob, every emulator's spelling), `maintainers` (bare GitHub
  usernames — see *Keeping pins current*), `dlc.available`, plus the backend namespaces below.
- **`wine-tuning.nix`** (as `wine = import ./wine-tuning.nix;`, or inline) — per-game knobs layered over
  the base layer in `lib/backends/wine/defaults.nix`: scalar knobs authored `{ value; reason; }` (the
  reason is enforced at eval), `galaxyStubDlls`, `extraSystem32`, `userReg`/`systemReg`/`userdefReg`,
  `setupScript` (via `mkSetupScript`), and `mounts` rows (add an entry, override one field of a default,
  or disable one). Unity titles compose `presets.unity.*` fragments with `presets.mergeTuning`.
- **`box64-tuning.nix`** (as `box64 = import ./box64-tuning.nix;`) — for Linux builds: the
  `bridgingLibs`/`guestLibs` library triage (`pkgs -> [drv]` functions).

See `pkgs/games/hollow-knight/` (the two-axis exemplar), `pkgs/games/stellaris/` (multi-depot Steam Linux
build under box64; Steam DLC, where each DLC is its own depot of the base app), `pkgs/games/outlast/`
(`extraSystem32`), `pkgs/games/factorio/` (GOG DLC, via `dlcId`), and `pkgs/games/kerbal-space-program/`
(writable game-dir overlay + a seeded tmpfs).

### Two steps CI will fail you on

Packaging the game is not the whole change — a new title is not "just discovered", because two standing
gates enumerate the games and both refuse an entry they have never been told about:

1. **Pin its resolution** in `lib/tests/resolution.nix`: add `<name> = "<fetcher>/<platform>/<backend>";`
   to `expected`, with a comment saying *why* that triple is the right one for this title. The check
   fails on a game that is missing from that list as loudly as on one that resolves wrongly — being
   unlisted is the failure, since an unpinned resolution is exactly what silently drifts. Host-dependent
   answers are written as a conditional (see `factorio` and `civilization-5`).
2. **Regenerate the README's tables**: `ci/readme-tables.sh --write`. They are generated data living in
   prose — Table 1 is (runnable platforms × the resolved default) per host, Table 2 the pinned fetch
   matrix — so never hand-edit a cell; the script rewrites both from the resolver and is diffed in CI.
   A hand-written note on a `—` cell (the human reason a build cannot run there) is preserved.

Run both before pushing: `nix eval --raw '.#checks.<system>.config-resolution.drvPath'` and
`ci/readme-tables.sh`. Note the resolution check is per system and CI runs **both**, so an
aarch64-only local run can still miss an x86_64 failure.

## Keeping pins current

Two workflows keep `versions.json` honest, and both lean on the fact that *detecting* a new upstream
version is anonymous while only *hashing* one needs an account. (On the GOG side that is GOG's own build
list; on the Steam side it reads **api.steamcmd.net**, a third-party appinfo mirror — Valve publishes no
unauthenticated appinfo endpoint, and the credential-free alternative is an anonymous CM PICS session,
which is the fallback if that mirror ever goes away. What a bad mirror could do is bounded: the
never-move-backwards guard rejects a rollback, and Steam itself issues the manifest request codes, so a
fabricated manifest id simply fails to download.)

Every `propnix` subcommand distinguishes "a human must act" from "the tool broke" in its **exit code**:
`4` means a credential or ownership problem — no stored token, a stale/revoked login, an account that
does not own the title, or a construct the tool refuses to guess at — while `1` is an unexpected failure
(transport, parse, a bug). CI keys on `4` to open an issue instead of failing the run, and scripts can
rely on the same distinction from every subcommand (`pin`, `hash`, `steam-probe`, `download`, `verify`).

- **`.github/workflows/cachix.yml`** (push to master) builds every redistributable package and pushes it
  to `propnix.cachix.org`. The policy it serves: **anything non-unfree that cache.nixos.org does not
  already serve must be built here**, so installing propnix never means compiling an emulator from
  source. Game payloads are the deliberate exception — credentialed and unfree, so caching them would be
  redistribution. Packages nixpkgs already builds (box64) are simply substituted and not re-pushed.
  `ci/cache-audit.sh <system>` holds that policy as a gate in `eval.yml`: it walks the scope, asks
  cache.nixos.org about each non-unfree package, and fails naming anything neither cached upstream nor
  reachable from a job in this workflow — by name in its `attrs` or through its closure (wineMono rides
  inside prefixLower). It reads the expectations out of the workflow, per system, so there is one list
  rather than two; the per-system precision is the point, since a package like `galaxyStub` is a
  different derivation on each host and was once covered on only one of them. After the tools leg has
  pushed `gbeFork`, the same run performs the Steam-SDK-vs-gbe_fork check (`ci/gbe-interface-check.sh`,
  whose oracle runs the just-pushed shim), so a master push never has two runners compiling the shim.
- **`.github/workflows/auto-update.yml`** (weekly, plus `workflow_dispatch`) builds and pushes the CLI to
  cachix, then substitutes it (`--max-jobs 0`, so it fails loudly rather than quietly recompiling) and runs
  `ci/pin-refresh.sh`. Stage 1 checks every packaged game anonymously in a few seconds; only a game that moved
  reaches stage 2, which streams the payload to recompute hashes. Every game it updates goes into one pull
  request — never a direct push, so `eval.yml` gates the result. Set the `PROPNIX_APP_ID` variable and
  `PROPNIX_APP_PRIVATE_KEY` secret if you want that PR to trigger CI by itself; a `GITHUB_TOKEN` PR does
  not.
- **`.github/workflows/pin-issues.yml`** (after every push-triggered `cachix` run completes — ordered
  behind it because it substitutes the CLI with `--max-jobs 0`, and a push touching the CLI's sources
  would otherwise race the very build that publishes it) re-checks every game and closes its "pin is
  behind upstream" issue once the pin genuinely matches upstream. It re-verifies rather than trusting the
  repo state, because editing the file is not the same as being current.
- **`.github/workflows/eval.yml`** (every push to any branch, every pull request including forks) is
  the pure gate: the resolution checks, the `ci/eval-matrix.sh` sweep and `ci/cache-audit.sh` per
  system, the README tables, the pin-issue lifecycle test, and — on branches and PRs, master pushes
  getting it from `cachix.yml` after the shim is pushed — `ci/gbe-interface-check.sh` (each Steam
  row's recorded `steamApiInterfaces` held against the pinned gbe_fork by running it, so the commit
  that moves a pin past the shim goes red naming the game, the row and the revisions). Three rules keep
  "every push" cheap without ever letting a skipped run outrank a real one: a newer push to the same
  branch or PR cancels the superseded run; a `memo` job looks for a *push* run of the same commit
  (a same-repo PR's head was pushed first; a fork's never was) and skips if it passed, waits if it is
  still going, and runs if it failed, so the newest check on a commit is always a real verdict; and
  it then skips when HEAD's *tree* already passed a recent push run — a fast-forward to master or a
  no-op rebase is not re-evaluated. A manual `workflow_dispatch` is never memoized.

The issue lifecycle (`ci/pin-issue.sh`) gives each game **exactly one open issue, ever**: it is edited in
place when upstream moves again — and only then, so a long-stale game does not notify anyone weekly — and
closed when the pin catches up. A closed issue is **never reopened**; a later regression opens a fresh one.
That invariant has a single home: the lookup only ever asks for `--state open`, and nothing calls
`gh issue reopen`. Identity is a hidden `<!-- propnix-pin: game=… target=… -->` marker rather than the
title, so issues can be retitled freely, and lookup uses the immediately-consistent list API rather than
the eventually-consistent search API — a stale search index would mean a duplicate issue.

A game the CI account does not own (or whose DLC it does not own) is reported **blocked**, not failed: the
run stays green and the issue tells whoever owns it to run one command. So is a game whose upstream cannot
be resolved at all — an aged-out GOG build, a retired Steam depot — and in that case the check emits a stub
report carrying the tool's own explanation, so the issue still opens and says why. A game that genuinely
**fails** does not abort the run either: it is recorded, every other game's work still lands, and a final
step turns the run red afterwards. Every game it does update becomes its **own commit** in the PR
(`pkgs/games/<game>: pin -> <version>`), so one bad pin can be reverted without touching the rest.

A game that names `maintainers` (bare GitHub usernames, in its `default.nix`) has them tagged wherever
its pin surfaces: **@mentioned** on their game's row of the weekly PR when it was refreshed, and **cc'd
on its issue** when only a human can move it — on open and on a genuine upstream move, never on the
weekly no-op re-check. A maintainer who is also a repository **collaborator** additionally gets a review
request on the PR; GitHub refuses review requests to anyone else, so non-collaborators are reached by the
mention alone. The lookup is one pure eval of `ci.<system>.maintainers` and is best-effort: if it fails,
the refresh still runs, just without the tags.

### Opting a game out, or holding it at a version

An optional top-level `pin` object in the game's `versions.json` overrides the follow-upstream default. A
`reason` is required whenever either field is set — the same discipline the tuning knobs enforce, because a
frozen pin with no stated reason is indistinguishable from an oversight six months later.

```json
{
  "pin": { "freeze": true, "reason": "2.1.x Experimental is deliberate; do not follow the default branch" },
  "fetchInfo": { … }
}
```

`freeze` takes the game out of automatic updating entirely — it is reported **frozen** (distinct from
up-to-date, so the summary tells the truth) and never gets an issue.

`version` instead names the exact upstream version to sit at. It is **per store**, because a version
string means different things to different stores and a game may pin more than one — hollow-knight has
both a GOG build and two Steam depots:

```json
{
  "pin": {
    "version": { "gog": "1.5.12620", "steam": "1.5.78.11" },
    "reason": "1.6 regressed the mod loader"
  },
  "fetchInfo": { … }
}
```

A bare string is shorthand, legal **only** when the game pins exactly one fetcher (Factorio:
`"version": "2.0.77"` means `gog`); on a mixed-store game it is an error that shows you the object form.
A store with no entry simply follows upstream, so the two are independent. Unknown store keys, and
non-string values, are errors — a typo must never quietly mean "follow upstream". `freeze` and `version`
are mutually exclusive.

What the value *means* is the store's business:

- **GOG** — it is resolved against the builds list, matching a `version_name` or a `buildId`, and the
  named build is selected. Because that may be *behind* the newest, this also expresses a deliberate
  **downgrade**, and it suppresses the never-move-backwards guard for exactly that reason. A value
  upstream does not list is an error naming the versions it does list.
- **Steam** — a **hold**, not a lookup. Steam publishes no version→manifest mapping, so nothing can
  resolve `"1.5.78.11"` to a manifest; the value instead asserts that every Steam row's `version` field
  already equals it. When they all match the pins are simply held (reported up to date, pinned to that
  version) and the appinfo request is skipped entirely. When one does not, the game goes **blocked** with
  an issue saying what to do: look the build up (SteamDB), edit that row's `manifestId` and `version` by
  hand, run `propnix pin <game> --recompute` — or drop `pin.version.steam`.

This lives in `versions.json` rather than the game's `default.nix` on purpose: it is the file
`propnix pin` already reads and rewrites, so consulting the policy costs nothing and the tool keeps working
on a plain checkout without evaluating any Nix — `--check` stays a few seconds across every packaged game. (`dlc` is
the existing precedent for a non-`fetchInfo` key there.) The rewriter preserves it untouched.

### A GOG pin can age out, and that is the intended outcome

GOG's builds API returns only its most recent builds, paginated. A pin that stays put for long enough —
a `freeze`, a `pin.version.gog` holding an old release, or simply a game nobody has touched in a year —
eventually names a build the list no longer contains. `propnix pin` then **refuses**: a build's release
track is inferred from the build itself, so with it gone there is no honest way to tell which track the
pin belonged to, and guessing could silently move a game from `Experimental` to the default branch (or
the reverse). The game is reported **blocked**, the run stays green, and the issue asks a human to re-pin
by hand. That is by design, not a gap: the alternative is a tool that quietly changes which release track
a game follows.

Credentials reach CI as repository secrets — `PROPNIX_GOG_TOKENS` (the `galaxy_tokens.json` text),
`PROPNIX_STEAM_STORE_B64` (base64 of the credential tar) and optionally `PROPNIX_STEAM_USERNAME`. A missing
secret is a skip, not a failure. Note a Steam refresh token is **not** a scoped download token: a client
session yields steamcommunity cookies, so treat it as full account access.

## Scope & backlog

**In:** the wine path (x86_64 + i386 Windows builds) and the box64/native thin path (x86_64 Linux builds),
GOG + Steam fetchers, every game in the README's tables — hardware-tested on **aarch64-linux**; **x86_64-linux** is structured +
evaluates (unbuilt/untested on real hardware). **Backlog:** building/testing the x86_64 target on real
hardware; a mechanical x86-guest cache-hit gate in `flake.checks`; MS-Store; handing the splash's
activation to gamescope when the game window first maps (would open the game on the splash's
monitor/workspace and keep focus on GNOME). The thin FEX backend SHIPS — it is what
runs the i386-linux platform (`pkgs/games/civilization-5`); what remains `meta.broken` is per-title, on
the engines whose walls were measured (hollow-knight's Mono/SMC crash on 16K), and `allowBroken` is how
such an entry gets retested (see `docs/DESIGN.md` D12).
