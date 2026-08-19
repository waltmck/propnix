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
  (token stored in `/var/lib/propnix`, readable by the `propnix-fetch` group — `nixbld` off NixOS); the token is
  **never** copied into the store or printed (download-only). Multiple accounts are supported — the fetcher
  tries each until one owns the pinned content. See **Credentials** in the README. `--extra-sandbox-paths`
  requires a **trusted Nix user**.
- **Nix's classic build users (`auto-allocate-uids = false`).** The builder reads the token through group
  membership; an auto-allocated build runs as a per-build synthetic uid/gid that is in no host group (and its
  user namespace doesn't map root), so only a world-readable token would work — which propnix declines to
  install. `services.propnix.enable` warns when the setting is on.
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
| `nixos/propnix.nix` | host module: binds the credential dir into the build sandbox, loads `ntsync`, trusts `propnix.cachix.org`, installs the `propnix` CLI, materializes declared credentials (sops-nix/agenix) |
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
  (modules/steam-emu.nix), which places the gbe_fork shim (emulators/gbe-fork.nix, prebuilt release
  artifacts — packaging its deps from source is backlog) and projects the offline entitlement list from
  those SAME rows (`dlcAppId`, else `depotId`) — engines that ask the (absent) Steam client whether a DLC
  is owned get the answer automatically, DLC-less and vanilla builds included (empty list = "own
  nothing"). Thin (Linux-build) games are served by a preload; an engine that dlopens the `.so` by
  explicit path (Unity plugins) declares the copy in `steam.emu.libPaths` and gets the shim bound over
  it. Steam **Windows** builds declare the shipped `steam_api(64).dll` path(s) there instead — the
  matching gbe_fork dll is union-replaced over them with settings beside it (required on wine: PE has no
  preload; enabling the emu there with no `.dll` declared is an eval error). One wall: a game built
  against a newer Steamworks SDK than the gbe_fork pin (currently 1.64) needs the pin bumped first —
  triage with `nm -D` on the game's genuine lib (modules/steam-emu.nix documents the method).

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
    computed against. `fetchGogGalaxyBuild` accepts it but deliberately ignores it — gogdl always fetches
    whatever the repository currently serves, so drift shows up as an FOD hash mismatch, which is the loud
    failure we want. The tool inserts and updates it; nobody needs to write it by hand.
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
build under box64; Steam DLC, where each DLC is its own depot of the base app), `pkgs/games/outlast/`
(`extraSystem32`), `pkgs/games/factorio/` (GOG DLC, via `dlcId`), and `pkgs/games/kerbal-space-program/`
(writable game-dir overlay + a seeded tmpfs).

## Keeping pins current

Two workflows keep `versions.json` honest, and both lean on the fact that *detecting* a new upstream
version is anonymous while only *hashing* one needs an account. (On the GOG side that is GOG's own build
list; on the Steam side it reads **api.steamcmd.net**, a third-party appinfo mirror — Valve publishes no
unauthenticated appinfo endpoint, and the credential-free alternative is an anonymous CM PICS session,
which is the fallback if that mirror ever goes away. What a bad mirror could do is bounded: the
never-move-backwards guard rejects a rollback, and Steam itself issues the manifest request codes, so a
fabricated manifest id simply fails to download.)

- **`.github/workflows/auto-update.yml`** (weekly, plus `workflow_dispatch`) builds and pushes the CLI to
  cachix, then substitutes it (`--max-jobs 0`, so it fails loudly rather than quietly recompiling) and runs
  `ci/pin-refresh.sh`. Stage 1 checks all 17 games anonymously in a few seconds; only a game that moved
  reaches stage 2, which streams the payload to recompute hashes. Every game it updates goes into one pull
  request — never a direct push, so `eval.yml` gates the result. Set the `PROPNIX_APP_ID` variable and
  `PROPNIX_APP_PRIVATE_KEY` secret if you want that PR to trigger CI by itself; a `GITHUB_TOKEN` PR does
  not.
- **`.github/workflows/pin-issues.yml`** (after every push-triggered `cachix` run completes — ordered
  behind it because it substitutes the CLI with `--max-jobs 0`, and a push touching the CLI's sources
  would otherwise race the very build that publishes it) re-checks every game and closes its "pin is
  behind upstream" issue once the pin genuinely matches upstream. It re-verifies rather than trusting the
  repo state, because editing the file is not the same as being current.

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
on a plain checkout without evaluating any Nix — `--check` stays a few seconds for all 17 games. (`dlc` is
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
GOG + Steam fetchers, 17 games — hardware-tested on **aarch64-linux**; **x86_64-linux** is structured +
evaluates (unbuilt/untested on real hardware). **Backlog:** building/testing the x86_64 target on real
hardware; a mechanical x86-guest cache-hit gate in `flake.checks`; MS-Store; MangoHud on non-DXVK
backends; a winewayland **xdg-activation** patch (would let the game open on the splash's
monitor/workspace, and extend focus-on-duplicate to GNOME/KDE). The thin FEX backend is
carried but `meta.broken` on 16K hosts (see `docs/DESIGN.md` D12).
