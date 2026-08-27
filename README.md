# propnix

Reproducible Nix packaging of proprietary games/apps to run on Linux. The goal is to provide sensible 
defaults that make apps run well (i.e. constructing a WINE prefix, overriding certain DLLs, choosing an
emulator/emulator options), abstracting the details of emulation to provide a consistent experience
between platforms.

Supported fetchers are GOG and Steam. You will need to initialize your credentials (see
**Credentials**). Quick start:

```sh
nix run .#propnix -- cred add steam   # And follow the instructions to login
nix run .#factorio --extra-sandbox-paths /propnix=/var/lib/propnix
```

This is fully reproducible (every download is pinned in the game's `versions.json` — GOG Windows builds
by Galaxy `buildId`, Steam builds by depot manifest); it downloads the game using your credentials as a
FOD, then wraps it so that it looks like a native linux application.

Tell propnix which stores you have (a ranked preference; resolved purely at eval — credentials are never
probed): `propnix.lib.mkScope { inherit pkgs; config.preferredFetchers = [ "steam" "gog" ]; }` — see
**Configuration** in [DOCS.md](DOCS.md).

## Supported games

Two views of the same fetch matrix. The first answers **"what will run on my machine?"**; the second
answers **"which store do I need an account with, and what does it give me?"**

**How to read these tables.** Every game is packaged along two orthogonal axes — `fetcher` (which store the
payload comes from) and `emulatedPlatform` (the OS+ABI of the build being run) — and a cell lists the
`emulatedPlatform` values valid for that row and column. **Bold** marks what you get by default, with no
flags: propnix picks it from the game's own quality ranking, filtered by what your host can run. Anything
else in the cell is selectable explicitly:

```sh
nix run .#hollow-knight                                                        # the default
nix run '.#hollow-knight.apply { emulatedPlatform = "x86_64-windows"; }'       # any other entry
nix run '.#hollow-knight.apply { fetcher = "steam"; emulatedPlatform = "x86_64-linux"; }'
```

### Table 1 (by host): which builds run on my machine?

Rows are games, columns are the architecture you are running on, and cells are the `emulatedPlatform` values 
that work there.

| game | on an `aarch64-linux` host | on an `x86_64-linux` host |
|---|---|---|
| `baby-steps` | **x86_64-windows** | **x86_64-windows** |
| `baldurs-gate-3` | **x86_64-windows** | **x86_64-windows** |
| `dont-starve` | **i386-windows** | **i386-windows** |
| `factorio` | **aarch64-linux**, x86_64-linux, x86_64-windows | **x86_64-linux**, x86_64-windows |
| `fallout-nv` | **i386-windows** | **i386-windows** |
| `hollow-knight` | **x86_64-linux**, x86_64-windows | **x86_64-linux**, x86_64-windows |
| `hollow-knight-silksong` | **x86_64-windows** | **x86_64-windows** |
| `homeworld-rm` | — | **i386-windows** |
| `iron-lung` | — | **x86_64-windows** |
| `iron-nest` | **x86_64-windows** | **x86_64-windows** |
| `kerbal-space-program` | — | **x86_64-windows** |
| `no-mans-sky` | **x86_64-windows** | **x86_64-windows** |
| `outlast` | **x86_64-windows** | **x86_64-windows** |
| `outlast-2` | **x86_64-windows** | **x86_64-windows** |
| `papers-please` | **x86_64-windows** | **x86_64-windows** |
| `prison-architect` | **x86_64-windows** | **x86_64-windows** |
| `skyrim-se` | **x86_64-windows** | **x86_64-windows** |
| `stellaris` | **x86_64-linux** | **x86_64-linux** |

### Table 2 (by store): which fetcher provides a given game build?

Rows are games, columns are stores. A cell lists the `emulatedPlatform` values propnix has **pinned** from
that store, independent of any host. This is the table to read when deciding which account you need: a
game with entries under only one column can only be built by someone who owns it there.

| game | `gog` | `steam` |
|---|---|---|
| `baby-steps` | x86_64-windows | — |
| `baldurs-gate-3` | x86_64-windows | — |
| `dont-starve` | i386-windows | — |
| `factorio` | x86_64-windows | aarch64-linux, x86_64-linux, x86_64-windows |
| `fallout-nv` | i386-windows | — |
| `hollow-knight` | x86_64-windows | x86_64-linux, x86_64-windows |
| `hollow-knight-silksong` | x86_64-windows | — |
| `homeworld-rm` | i386-windows | — |
| `iron-lung` | x86_64-windows | — |
| `iron-nest` | x86_64-windows | — |
| `kerbal-space-program` | x86_64-windows | — |
| `no-mans-sky` | x86_64-windows | — |
| `outlast` | x86_64-windows | — |
| `outlast-2` | x86_64-windows | — |
| `papers-please` | x86_64-windows | — |
| `prison-architect` | x86_64-windows | — |
| `skyrim-se` | x86_64-windows | — |
| `stellaris` | — | x86_64-linux |

When a game is pinned from both stores, the default fetcher follows your `preferredFetchers` config
(every registered fetcher in registry order, unless you narrow it) — so a gog-only setup automatically
falls back to the GOG build of a game whose Steam build would otherwise win, provided the game's own
ranking sanctions that platform. Nothing outside that ranking is ever selected silently.

## Requirements

propnix assembles a throwaway `WINEPREFIX` per launch out of kernel bind/overlay mounts in a private
user+mount namespace, so it does not need any privileges while still maintaining the performance/cache
benefits of native kernel mounts. That design leans on several host capabilities.

**At a glance** (full detail — plus the repo layout, how to add a game, and the backlog — is in **[DOCS.md](DOCS.md)**):

| requirement | needed for | required? |
|---|---|---|
| Unprivileged user namespaces (`CONFIG_USER_NS`, `user.max_user_namespaces > 0`) | assembling the prefix (`propnix-mount`) | yes |
| Unprivileged network namespaces (`CONFIG_NET_NS`) | the kernel-enforced offline guarantee for a game that declares `online = false` — the launcher adds `CLONE_NEWNET` to the *same* `unshare` as the userns, so the game gets loopback and nothing else | yes *for those games* (most of them) |
| Unprivileged overlayfs + `userxattr` in a userns (Linux **5.11+**) | copy-on-write prefix/game/save overlays over the store | yes |
| `user.*` xattrs + overlay-upper support on `$XDG_STATE_HOME` & saves fs (ext4/xfs/btrfs/tmpfs; ZFS **≥ 2.2**) | persisting the overlay *uppers* | yes |
| A Vulkan ICD (e.g. Mesa on Asahi) | the default DXVK/vkd3d D3D backend | hard *unless* `PROPNIX_WINE_D3D=wined3d` |
| Wayland (+ Xwayland) or X11 | the GTK4 splash + the game window | yes |
| `/dev/ntsync` (Linux **6.14+**) | fast wine synchronization | recommended |
| `wlr-foreign-toplevel-management` compositor | single-instance raise, splash dismiss, close-to-quit | optional (degrades gracefully) |
| GOG/Steam account owning the title + its token | **building** a game payload (FOD fetch) | yes (build-time) |
| Nix's classic build users, i.e. `auto-allocate-uids = false` | reading that token inside the FOD sandbox — an auto-allocated build runs as a synthetic uid/gid in no host group, so a 0640 token is unreadable and only a world-readable one would work | yes (build-time) |

## How it runs

`mkApp` evaluates a game's module (two orthogonal axes: `fetcher` × `emulatedPlatform`) and dispatches to
the selected backend's builder (`mkWineApp` / `mkThinApp`), producing `bin/<name>` — a wrapper around
`propnix-launcher` with a baked JSON config (store paths + defaults + the seal + the mount table). The
scope injects the arch-appropriate emulator set (aarch64 → wine+FEX+ARM64EC DXVK/vkd3d; x86_64 → native
wine + standard DXVK/vkd3d), but the launcher, config, and game spec are identical. At launch the launcher:

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
| `PROPNIX_NO_PREFETCH` | skip the cold-launch prefetch (the wine path warms the assembled prefix's PE modules — `.dll`/`.drv`/`.exe`, system32 + the game's own — into the page cache while wine starts) |
| `PROPNIX_EXTRA_BINDS` | extra `;`-separated `TARGET\|SOURCE` bind rows (TARGET prefix-relative or `$`-expandable; SOURCE an absolute/`$`-expandable host path) — an ad-hoc redirect (e.g. a secondary saves/mods dir) without a rebuild |

Debug escape hatches: `--shell` (sealed shell in the prefix), `--propnix-unseal` (skip the scrub).

## Credentials

The credentialed fetchers need an account token, kept **out of the store**. Add an account with the
`propnix` CLI (`gog` for GOG payloads, `steam` for Steam depots):

```
propnix cred add gog             # opens a browser login; paste back the redirect URL
propnix cred add steam           # DepotDownloader's Steam Guard 2FA login (one-time)
propnix cred list                # accounts, grouped by type, labelled by username
propnix cred rm <username>       # or, if a username exists under >1 type:
propnix cred rm --type steam <username>
```

`cred add gog` opens GoG's login in your browser (GoG blocks headless password login — captcha/2FA happen
there); you paste the resulting `…/on_login_success?code=…` URL back, and it mints + stores the token.
`cred add steam` drives DepotDownloader through Steam's one-time Steam Guard 2FA and stores the reusable
refresh token. Both populate the store at **`/var/lib/propnix`** — `credentials.toml` (a non-secret pointer)
plus `<type>/<username>/<tokenfile>` (`gog/…/galaxy_tokens.json`, `steam/…/depotdownloader-store.tar`),
mode 0640 and group-owned by **`propnix-fetch`** so the build sandbox can read it. On NixOS the whole flow is
unprivileged — the store dirs are group-writable by `propnix`, so no step prompts for a password. Without the
module (or with a group it names absent) the CLI falls back to the historical layout: dirs 0755, group
`nixbld`, and the `/var/lib` write via `sudo` — the login itself always runs as you. Multiple accounts are
supported everywhere: a fetcher tries each of its type until one owns the pinned content, and **so does
`propnix pin`** — it advances to the next stored account on an ownership refusal and settles the question
before a byte of content is fetched. Force one account with `--gog-account <name>` / `--steam-account
<name>`, or with `PROPNIX_GOG_ACCOUNT` / `PROPNIX_STEAM_ACCOUNT` (flag beats env beats try-all). `cred rm`
takes `--type` to disambiguate when the same username is stored under two backends.

Bind the store into the build sandbox with the NixOS module (`services.propnix.enable`) or manually
(`--extra-sandbox-paths /propnix=/var/lib/propnix`, requires a trusted Nix user). The store holds only the
pointer + tokens; every download parameter is pinned in `versions.json`, so the bind can only make a fetch
succeed or fail, never change *what* is fetched. See `config/credentials.nix` for the full model.

Prefer keeping the token in your (encrypted) config repo? The module also builds the store **declaratively**
from any secret manager that decrypts to a path — sops-nix, agenix, a hand-rolled unit:

```nix
sops.secrets."propnix/gog/alice" = {
  sopsFile = ./secrets/gog-alice.json;                # the encrypted galaxy_tokens.json
  format = "binary";                                  # keep the file verbatim
  restartUnits = [ "propnix-credentials.service" ];   # re-copy when you rotate it
};
services.propnix.credentials.gog.alice.source = config.sops.secrets."propnix/gog/alice".path;
```

`propnix-credentials.service` copies each declared token into the same `<type>/<username>/<tokenfile>` layout
at activation (it copies rather than symlinks because sops-nix's `path` points into `/run/secrets.d/…`, which
doesn't exist inside the build sandbox). Declared and `cred add`-ed accounts coexist; set
`services.propnix.credentialsPath = "/run/propnix"` for a fully declarative host and no token ever touches
the disk. A declared credential stays the config's: `cred list` marks it `(declarative)` and `cred rm`
refuses it, naming the option to edit.

```
$ propnix cred list
GOG:
  - alice (declarative)
  - dave
Steam:
  - bob (declarative)
```

Either way, managing credentials means being in the **`propnix`** group the module creates. Its members
default to `nix.settings.allowed-users` — i.e. `*`, every human account, unless you've narrowed who may use
the daemon — so `cred add`, `cred rm` and `propnix pin` all work without sudo out of the box. Restrict or
extend it with:

```nix
services.propnix.allowedUsers = [ "you" ];     # or [ "@wheel" ], or [ ] to opt out entirely
users.users.you.extraGroups = [ "propnix" ];   # equivalent, honoured alongside the option
```

There are two groups, because read and write have to be separable: `propnix` owns the store *directories*
(2775, so members write without sudo), while a derived `propnix-fetch` holds those same humans **plus** the
Nix build users and owns the token *files* (0640). That way a build can read a credential — nix passes a
build user's supplementary groups to the builder, which is what keeps the sandboxed fetcher working — but
never write one. You only ever touch `propnix`; `propnix-fetch` is kept in sync for you. Adding yourself to
`nixbld` instead would be a mistake — its members are exactly who nix runs builds as.

