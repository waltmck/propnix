# propnix — measured platform facts

The evidence base for [PLAN2.md](./PLAN2.md). Every claim here was measured on the target machine —
NixOS/Asahi, `aarch64-linux`, kernel 7.1.5, **16K pages**, nixpkgs 26.11, nix 2.34.8 — unless marked
`(unverified)`. Source citations are file:line into the nixpkgs 26.11 checkout or the upstream tree of
the tool in question.

`PLAN2.md` cites these sections as `RESEARCH §n`. Nothing here is a design decision; where a fact
forced one, the decision lives in `PLAN2.md` and is cross-referenced from it.

**Why this file exists separately.** Several of these findings contradict the obvious design, and a few
are silent-failure traps — a mechanism that reports success while doing nothing. Keeping the evidence
apart from the design makes it possible to re-verify a fact after a toolchain bump without re-reading
the plan, and to see at a glance which decisions rest on measurement rather than reasoning.

---

## 1. Emulators on 16K pages

| Fact | Evidence |
|---|---|
| **stock nixpkgs `fex-2605` cannot execute x86 code on 16K pages** | `<jemalloc>: Unsupported system page size`; FEXServer dies, `FEXInterpreter` hangs |
| The 4K assumption is fixable — the `fex-portable` fork (§14) | ~295-line patch: `FEX_PAGE_SIZE=4096` is correct as the *guest* page and stays; the ~9 sites that also used it as the *host* page are re-derived from `sysconf(_SC_PAGESIZE)`. Runs x86_64 on this 16K host, so muvm is not required for x86_64 emulation |
| nixpkgs disables FEX's tests when `PAGESIZE != 4096` | `fex/package.nix:229-233` — a green build proves nothing |
| **box64 0.4.2 works on 16K pages** | ran x86_64 binaries natively, no VM |
| **muvm gives a 4K guest sharing the host `/nix/store`** | guest `PAGESIZE=4096`, kernel 6.12.91, 132,268 store entries visible |
| Hardware TSO is available on this CPU | `FEXGetConfig --tso-emulation-info`: GPR/memcpy/vector/unaligned all "Hardware TSO" |
| Split-lock atomics are **not** free | same output: 16- and 64-byte both "Tearing CAS loops" |
| `box86` is armv7l-only in nixpkgs → unusable on aarch64 | `box86-armv7l-unknown-linux-gnueabihf-0.3.8` |

## 2. Loading foreign binaries — and the end-to-end result

| Fact | Evidence |
|---|---|
| **box64 ignores the ELF interpreter — it is the loader** | a binary whose interpreter `/lib64/ld-linux-x86-64.so.2` does not exist on this host ran fine |
| **box64 + patchelf'd payload + zero rootfs runs the real game** | Hollow Knight reached the **main menu**: `Renderer: Apple M2 (G14G B0)`, `Mesa 26.1.5`, `Creating OpenGL 4.6 graphics device`, PlayerPrefs written |
| **FEX honors the interpreter** — it emulates the real `ld.so` | unpatched foreign binary under `FEX_ROOTFS=/` → `Invalid or Unsupported elf file`; patchelf'd → works |
| `FEX_ROOTFS=/` resolves ELFs fine when interpreter+RPATH are absolute store paths | x86_64 `uname -a` under FEX reported `x86_64` |
| Unset `FEX_ROOTFS` hangs forever | defaults to `~/.fex-emu/RootFS/`; FEXServer cannot start |
| FEX **re-roots absolute symlink targets** under the rootfs | `GetEmulatedPath`'s FollowSymlink loop rebuilds `Path = RootFSPath + <absolute target>`; a store-path symlink vanishes unless the rootfs has a `nix → /nix` passthrough, and chained `buildEnv`-of-`buildEnv` still failed |
| `patchelf` works cross-arch (x86_64 ELFs from aarch64) | `--set-interpreter`/`--set-rpath` both succeed |

## 3. The x86_64 package set

| Fact | Evidence |
|---|---|
| `import nixpkgs { system = "x86_64-linux"; }` on aarch64 is **substitutable** | Hollow Knight's library closure: **62 paths fetched, 0 built** |
| `allowUnsupportedSystem` is **not** needed | `x86_64-linux` is supported, merely not the host |
| `inherit (pkgs) config` round-trips safely | no `_module` in `pkgs.config`; a user `allowUnfreePredicate` survives; `zlib.drvPath` byte-identical to a plain second instance |
| A second evaluation is unavoidable — nixpkgs does the same | `pkgsi686Linux` is `nixpkgsFun` with `localSystem` overridden, `stage.nix:237` |
| `pkgsCross` is **also** a second evaluation, differing only in axis | `crossSystem` → different hashes → cache misses |
| `pkgsCross.gnu64` derivations build **natively on aarch64** | `system = aarch64-linux`, `hostPlatform = x86_64-linux` |
| Hydra caches cross **partially** — 9/15 needed libraries | misses cairo, pango, glib, dbus, SDL2, libpulseaudio, libxcursor, pipewire |
| The **native** `pkgsi686Linux` throws on aarch64 | `i686 Linux package set can only be used with the x86 family` |
| But **`pkgsX86.pkgsi686Linux` works** — the correct i686 source here | its `stdenv.hostPlatform.system` → `"i686-linux"` |
| Second-instance eval cost | +0.5 s wall, +175 MB RSS for a 17-library set |

## 4. box64 mechanics

- **455** wrapped-library sonames compiled in (`libGL`, `libX11`, `libvulkan`, `libSDL2*`, `libudev`,
  `libpulse*`, `libasound`, …).
- box64 **dlopens the native aarch64 library** to bridge it — reproduced as
  `Error initializing native libXss.so.1`. Load-bearing: an incomplete native set cost the real game
  `libXss` and `libXxf86vm`.
- **`essential_libs[]` (57 entries, `library.c:456-467`) is the set box64 *refuses to emulate***,
  consumed by `isEssentialLib()` to force `precise = 0`. It contains `libc.so.6`,
  `ld-linux-x86-64.so.2` — libraries box64 bridges internally and never dlopens natively. It is
  **not** a native-bridge list; derive `nativeLibs` from the wrapped-soname set *minus* these.
- `UnityPlayer.so` dlopens **17** sonames that appear in no `DT_NEEDED` entry.

**Verifying the native/emulated split: read `/proc/<pid>/maps`, not the log.** box64's
`Using native(wrapped) %s` line at `BOX64_LOG=1` covers only the initial `DT_NEEDED` walk — runtime
`dlopen`s are not logged at that level, so Hollow Knight's log shows 9 bridged libraries while the
process actually maps 69. The reliable check is the ELF machine byte (offset 18: 183 = AArch64,
62 = x86-64) of every file-backed `.so` mapping:

```sh
awk '{print $NF}' /proc/$pid/maps | grep -E '\.so($|\.)' | sort -u |
  while read -r f; do printf '%s %s\n' "$(od -An -tu1 -j18 -N1 "$f" | tr -d ' ')" "$f"; done
```

Measured at the frontend, both box64 packages map **zero x86-64 nixpkgs libraries** — Stellaris 64
AArch64 objects plus the vendor-bundled `libnakama-cpp.so`; Hollow Knight 69 AArch64 and none. GL,
Mesa/gallium, X11/xcb, PulseAudio, dbus, udev, zlib, systemd and LLVM are all native. The only
emulated code is the game's own binary and its vendor-bundled libraries, which have no native
equivalent by construction. This is the assertion PLAN2 §11's Tier 2 wants: it is specific, cheap, and
fails loudly when a bridge silently regresses to emulation.

**`BOX64_PREFER_WRAPPED=1` makes a missing native library a *new* failure mode.** It replaces
vendor-bundled copies of wrapped sonames with the host's, so a soname the payload ships but the
wrapper does not supply natively produces `Error initializing native <soname>`. Measured on Hollow
Knight's wayland path, which loads the bundled `libdecor-0.so.0` that x11 never touches:
`libdecor-0.so.0`, `libdbus-1.so.3` and `libz.so.1` all failed to bridge. Supplying the native
`libdecor`, `dbus` and `zlib` cleared all three — and changed nothing else, so the errors were not
the cause of that path's crash (§17).

**rcfile semantics — every one of these is a silent-failure trap:**

| Behaviour | Consequence |
|---|---|
| `[name]` matches the lowercased **process basename**; `[/basename]` is a **per-mapping** section (note the leading slash — `RecordEnvMappings` does `strrchr(fullname,'/')`, which points *at* the slash) | two different mechanisms; a library section without the slash silently never matches |
| A per-mapping section honours only **6** knobs: `DYNAREC_{BIGBLOCK,CALLRET,DUMP,SAFEFLAGS,SEP,STRONGMEM}` | anything else in `[/lib.so]` is silently ignored |
| `*sub*` globs need **both** stars; `[hell*]`, `[*ello]`, `[*]`, `[**]`, `[global]` do **not** apply | there is **no global/catch-all section** |
| `Applied settings from rcfile` means *a file was parsed*, not *a section matched* | useless as a test assertion — it prints for `[global]`/`[*]`/`[**]` which apply nothing |
| `~/.box64rc` **outranks** `BOX64_RCFILE` and **replaces the whole matching section** | a user section wipes propnix's entire block for that binary; no merge |
| rcfile entries silently override **env vars** | tuning in the rcfile beats tuning in the environment |
| `BOX64_NORCFILES=1` suppresses propnix's own `BOX64_RCFILE` too | it is not a way to seal propnix's tuning while keeping it |
| box64 ships a **13-section compiled-in** default rcfile (`env.c` `default_rcfile[]`, via `shm_open("/box64_rcfile")`); `BOX64_RCFILE` **replaces** it | not upstream's 274-section `system/box64.box64rc`, which nixpkgs drops entirely |
| There is **no working `--rcfile` flag** in 0.4.2 | `box64 --rcfile f prog` → `Warning, unrecognized option '--rcfile'` |
| Auto-heuristics each have a gate knob | `BOX64_DYNAREC_BLEEDING_EDGE` (Mono), `BOX64_UNITYPLAYER`, `BOX64_DYNAREC_TBB`, `BOX64_JVM`, `BOX64_LIBCEF`. Mono fires on a library named `libmonobdwgc-2.0.so`, **not** a `MonoBleedingEdge` directory |

## 5. FEX mechanics (FEX-2605)

- Ships `ThunksDB.json`, `GuestThunks/` (asound, drm, EGL, GL, VDSO, vulkan, wayland-client),
  `GuestThunks_32/`, `HostThunks/`, and `AppConfig/` (2 files).
- **AppConfig is two separate files, not one union**: `client.json` = `{"Config":{"HideHypervisorBit":"1"}}`,
  `steamwebhelper.json` = `{"Comment":…,"ThunksDB":{"GL":0}}`. The union is legal but is not what ships.
- **nixpkgs bakes the thunk paths**: `ThunkGuestLibs`/`ThunkHostLibs` renamed to `Unused*` and
  hardcoded to `$out`, so `FEX_THUNKGUESTLIBS` **silently does nothing**. nixpkgs' fex carries **17**
  `--replace-fail` calls.
- **`FEX_THUNKCONFIG` is parsed for exactly one property, `"ThunksDB"`** — an enable map `{name: 0|1}`.
  `DB`/`Library`/`Overlay` are read **only** from `GetConfigDirectory(Global) + "ThunksDB.json"`
  (`FileManagement.cpp:54,104,200,248-260`). Passing an overlay via `FEX_THUNKCONFIG` is a silent
  no-op, reproduced twice. Overlays need `FEX_APP_CONFIG_LOCATION` (see RESEARCH §14).
- The shipped overlays use `@PREFIX_LIB@`, which only expands to FHS paths and can never match a store
  path. `fex_thunk_test` is a DB key with **no guest `.so`** — enabling it is fatal on 64-bit.
- **Env beats AppConfig**: `LAYER_ENVIRONMENT` is loaded *after* `LAYER_USER_OVERRIDE`
  (`Config.cpp:117-122`). This is **inverted** relative to box64, where the rcfile beats env.
- Already default and therefore not worth setting: `TSOEnabled`, `HalfBarrierTSOEnabled`,
  `KernelUnalignedAtomicBackpatching`, `VolatileMetadata`, `MonoHacks`.
- FEX-2605 has **no** `ParanoidTSO`, `StaticRegisterAllocation`, or `AOTIR*`.
- `FEXGetConfig` never reads `FEX_APP_CONFIG`; it loads only Global/Main/Environment plus app layers
  gated on `is_set_by_user("app")`. So it cannot verify a package's AppConfig took effect.

## 6. Memory model and hardware TSO

| Fact | Consequence |
|---|---|
| A process starts in `PR_SET_MEM_MODEL_DEFAULT` (**weak**) | hardware TSO is not on unless something asks |
| **box64 never requests TSO** — no `PR_*_MEM_MODEL` in its source | under box64 the CPU is in weak mode, so `DYNAREC_STRONGMEM` is the only ordering guarantee |
| The model is **per-thread and reset by `execve`** | a wrapper **cannot** set TSO for the program it launches: set, `exec`, child reads `0` |
| It *is* inherited by threads created after the call, and across `fork` without exec | which is why FEX sets it inside its own process ("gets inherited on thread creation") |
| Probe constants (out-of-tree Asahi prctl, from FEX's `PrctlUtils.h`) | `PR_GET_MEM_MODEL 0x6d4d444c`, `PR_SET_MEM_MODEL 0x4d4d444c`, `DEFAULT 0`, `TSO 1` |

Any propnix use of hardware TSO therefore needs an `LD_PRELOAD` shim, not an environment variable.

## 7. Fetching and credentials

- **`impureEnvVars` reads the nix-daemon's environment, not your shell.** A FOD with
  `impureEnvVars = [ "PROPNIX_GOG_TOKEN" ]` invoked as `PROPNIX_GOG_TOKEN=… nix-build` logged
  `SEEN: []`. Kills the obvious design.
- `__impure = true` needs `impure-derivations` + `ca-derivations` **on the daemon**, and is never
  cached. Ruled out.
- **`--extra-sandbox-paths` works and does not change the `.drv` hash.** Requires a trusted user.
- FODs get network access under `sandbox = true`; ordinary derivations do not.
- **GOG does not rotate refresh tokens.** After a refresh, `refresh_token`/`session_id`/`user_id` are
  byte-identical; only `access_token`/`expires_at` change.
- **Hermetic auth needs the whole credential directory** — `galaxy_tokens.json` **plus** `cookies.txt`
  **plus** `config.cfg`. Token alone falls back to interactive browser login. `config.cfg` holds 44
  plain settings and **no secrets**.
- **`config.cfg`'s `directory = .` silently overrides `--directory`.** Force the output path.
- **The API `size` field is wrong**: 1,214,251,008 reported vs 1,214,513,063 actual. Only the hash is
  an integrity gate.
- **The auth gate on `downlink` is a 302 to `/en##openlogin`, not a 401.** A naive fetcher's only
  symptom is a hash mismatch.
- Metadata is fully public: `api.gog.com/products/<id>?expand=downloads` (200 unauthenticated) and
  `content-system.gog.com/…/os/windows/builds?generation=2` (96 immutable `build_id`s).
- **No Linux builds in the Galaxy content system** (`Unsupported OS`) — Linux payloads come only from
  the auth-gated MojoSetup offline installer.
- **Windows** offline installers are multi-part above ~4 GiB (Cyberpunk: 28 files; Stellaris: an
  `.exe` plus five `.bin`) → `outputHashMode = "recursive"`. **Linux `.sh` installers are not split
  at any size** — Stellaris ships 15.9 GB as one file, so `flat` still holds. Assert the file count
  rather than infer it from size.
- **NAR hashing ignores mtimes and non-exec permission bits**, not the exec bit.
- `innoextract` defaults `withGog = false`, caps at Inno 6.3.3, ~18 months stale → fallback only,
  gated on `innoextract -t`.
- `requireFile` is "an FOD whose builder always fails"; its path depends on **both** hash and `name`.
- **`gogdl` (nixpkgs 1.2.2) is the Galaxy fetcher (D15, §3.2), and its download is deterministic.** Two
  independent full downloads of Hollow Knight windows/x64 build `59545516053866453` produced byte-identical
  recursive NAR hashes (`sha256-zNs+los9+7taVgCKmFrVrKGFHQMqJkB/Pau6nnE5EkU=`, 5.26 GB / 1789 files), and
  the credentialed FOD (`wine-fex/fetchGogGalaxyBuild-gogdl.nix`) reproduces that pin end-to-end from a
  clean download. It publishes the depot tree directly (no InnoSetup/`innoextract`) and takes the
  **numeric** `productId` (`1308320804` for HK), not the slug.
- **gogdl authenticates from `galaxy_tokens.json` ALONE** — unlike lgogdownloader (which needs the whole
  credential dir, above). A `jq` transform writes gogdl's client-id-keyed auth-config with `loginTime:0`,
  forcing a refresh from the non-rotating refresh token; no `cookies.txt`/`config.cfg` → no new credential
  plumbing.
- **`lgogdownloader` 3.18 `--galaxy-install` crashes** (`std::out_of_range`, shared with bulk `--download`;
  only `--download-file` is safe) — the reason the Galaxy fetcher is gogdl, not lgogdownloader.

## 8. Real MojoSetup payload layout

A GOG Linux offline installer is a shell script with a zip appended. Top level: `data/`, `meta/`,
`scripts/`. Under `data/`: `noarch/`, `options/`. Under `data/noarch/`: `game/`, `support/`, `docs/`,
`start.sh`, `gameinfo`. **There is no `data/x86_64` tree** — the x86_64 binaries live in
`data/noarch/game`. `gameinfo` is the version authority: line 1 title, line 2 version, line 3 GOG
build id (Stellaris: `Stellaris` / `4.4.6` / `92219`).

**Reading it: `bsdtar` below 4 GiB, `unzip` above.** Measured with libarchive 3.8.8:

| payload | prologue | archive | `bsdtar -tf` |
|---|---|---|---|
| Hollow Knight 1.5.12620, 1.2 GB, 1867 entries | 795,171 B | zip | **exit 0** |
| Stellaris DLC installers, ≤93 MB, all 11 | 653,743 B | zip | **exit 0** |
| Stellaris 4.4.6, 15.9 GB, 43,954 entries | 653,691 B | **ZIP64** | **`Damaged Zip archive`** |

The prologue is not the cause — Hollow Knight's is the *larger* of the two and reads fine. What
libarchive cannot do is reconcile the **ZIP64** end-of-central-directory locator with a non-zero
archive start offset; streaming the same file in fails differently (`Unrecognized archive format`).
Info-ZIP `unzip` reports the shift as a warning (`End-of-centdir-64 signature not where expected
(prepended bytes?) … (attempting to process anyway)`) and then extracts correctly, preserving the
unix permission bits — verified by extracting the last entries in the central directory, well past
the 4 GiB mark, and checking their sizes against the listing. Two consequences for a builder:
`unzip`'s member selectors are **globs** (`'data/noarch/game/*'`), not bsdtar's prefix form, and the
warning makes `unzip` **exit 1**, so tolerate status 1 and nothing else. `7z x` is the fallback.

Hollow Knight has seven ELF objects; the main executable's RPATH is `$ORIGIN` and it loads its
bundled `UnityPlayer.so` from there. Verified `DT_NEEDED` closure: `glibc`, `gcc-unwrapped.lib`,
`wayland`, `cairo`, `pango`, `glib`, `dbus.lib`, `zlib`.

**DLC is a directory overlay.** Each GOG DLC installer is the same MojoSetup shape, and its
`data/noarch/game/` contains only the DLC's own files plus a `goggame-<dlcProductId>.{info,hashdb}`
pair namespaced by product id — so composing base + DLC is a union of directories with no
filename collisions (verified for all 11 Stellaris DLC). Not every GOG "DLC" is game content: an
entitlement whose API entry has **no installers, only `extras`** is bonus material, and packaging it
means installing data files, not extending the game (Hollow Knight — Gods & Nightmares is two
soundtrack zips and nothing else).

## 9. Wine (wine-wow64-11.0)

| Fact | Evidence |
|---|---|
| `pkgs.wine` **throws** on aarch64; `wineWow64Packages.stable` works | native instance pulls the i686 set |
| Prefix path and wine's store path in the registry | **0 occurrences** each |
| `dosdevices/c:` is `../drive_c` — **relative** | relocating a prefix works |
| Username **is** baked in | 61 refs, plus `drive_c/users/<name>` |
| **A prefix can be built in a Nix derivation** | `wineboot -u` runs in the sandbox; a build-time `reg add` persists; 67 MB output; users dir `nixbld` |
| **A read-only prefix silently loses registry writes** | `reg add` reports success, `user.reg` unchanged, a fresh `wineserver` cannot find the key |
| Hybrid (store bulk symlinked, `.reg` + `users/` writable) | registry write persists |
| **HKCU survives a cross-version `wineboot -u` in place** (measured 2026-08-08) | provisioned on 11.0, set `HKCU\Software\…\Language=ENU`, then ran staging 11.12 `wineboot -u` on the SAME prefix → value persisted |
| **fuse-overlayfs overlay prefix works** (measured 2026-08-08) | HK runs on `overlay(lower=shared system, upper=per-app)` mounted with fuse-overlayfs (unprivileged, `user_id=1000`). FEX DLLs + default hives sit in the read-only lower; user writes (`user.reg`, `system.reg`, `drive_c/users`) copy-up into the upper — lower stays clean. This realized the overlay prefix design (later superseded by the §7.2 symlink farm — see the symlink-farm row below). **Unmount requires `wineserver -k` first** — lingering `winedevice`/`rpcss`/`svchost` hold the mount, so a bare `fusermount3 -u` fails with EBUSY — **and must use the SYSTEM setuid `fusermount3`** (a non-setuid nix-store copy fails EPERM; see the kernel-vs-fuse row below) |
| **Store-resident lower + seeded upper — overlay design, SUPERSEDED by the symlink farm below (the build-time store tree is kept)** (measured 2026-08-08) | The lower is now built into the store (`wine-prefix-lower.nix`: `wineboot -u` + FEX DLLs + Wow64 keys + `.update-timestamp=disable`), removing the ~22 s first-launch `wineboot`. But a raw store path (root:root `0555`/`0444`) **cannot** be a writable overlay lower: copy-up is blocked (can't even `chmod` a root-owned merged dir as non-root), `squash_to_uid` mount fails `EPERM`, and a `unshare -r` userns wouldn't map the real-root store files. **Fix (in `winefex.nix`):** before mounting, seed the writable upper from the lower with the full **dir skeleton** (~130 dirs → every dir resolves to the writable upper; DLL bulk stays read-only in the lower) + the **registry hives** (`system.reg`/`userdef.reg` re-seeded on every lower change to track the build; `user.reg`/HKCU seeded once, preserved across bumps). Seed is **<0.1 s**. Verified: HK launches; upper is a **1.9 M** delta vs the 295 M lower; wine builds its **font cache at runtime into the upper** (`user.reg` gains 364 `Fonts` refs); saves bind out to `PROPNIX_SAVE_DIR/<appid>` |
| **Two overlay backends — kernel default, fuse fallback — SUPERSEDED by the symlink farm below** (measured 2026-08-09) | Kernel `overlay` mounts unprivileged inside `unshare --user --map-root-user --mount` (`userxattr`; ZFS upper OK; `renderD128` is `0666` so GPU works with no host groups) and the mount is **namespace-local** (can never strand a host mount). Cold TTFW **18.8 s vs fuse's 19.0 s**, warm ~5 s both — **equal for HK** (cold is disk-read-bound, not FUSE per-op overhead), but the kernel path has lower per-op overhead so it may win for I/O-heavy titles → **kernel is the default** (`PROPNIX_OVERLAY=kernel`). Since the mount is namespace-local, wine runs INSIDE the ns: the runner re-execs itself under `unshare` (prefetch+seed in the outer pass). **Caveat / why fuse remains** (`PROPNIX_OVERLAY=fuse`): a userns **drops ALL host supplementary groups** — unprivileged you may only self-map one gid with `setgroups=deny`, and `newgidmap` only maps `/etc/subgid` (100000+, not system gids like `video=26`; verified `gid range [1-2) not allowed`). GPU (0666 render node) + PipeWire-socket audio still work, so games are generally fine, but a title opening a group-gated device directly (`card*` `0660 video`, `/dev/kvm`, raw `/dev/snd`) needs fuse, which keeps all groups. **fuse gotcha:** the fuse mount + unmount must use the **system setuid `fusermount3`** (`/run/wrappers/bin` on NixOS, `/usr/bin` else) — a non-setuid nix-store `fusermount3` mounts but **EPERMs on unmount**, stranding the mount + its `fuse-overlayfs` daemon (observed, then fixed by NOT shipping `fuse3` so the inherited-PATH setuid one wins). Both backends verified 2026-08-09: HK runs on native Wayland + SIGTERM tears down clean (no stray mount/proc/dir). |
| **Registry model — system.reg/userdef.reg read-only from the store; user.reg regenerated** (measured 2026-08-09) | The lower ships `system.reg` (HKLM) + `userdef.reg` (HKU\.Default) but **not** `user.reg` (HKCU); winefex seeds **only the dir skeleton**, copies no hive. HKLM/.Default are served **read-only from the store** — Admin-only on Windows so games never write them — and `user.reg` (HKCU, the only user-owned hive) is **regenerated by wine into the writable upper on first run** (~+0.1 s: built-in defaults + font list, **not** a `wineboot`; verified HK launches, `user.reg` ~900 KB persists across runs). **Backend asymmetry + mechanism:** an *in-place* write to the `0444` root-owned store hive is denied on **both** backends (in the userns the store's `root` owner is **unmapped** → shows as `65534`, so even ns-root can't `CAP_DAC_OVERRIDE` it). But wine *replaces* hives (unlink+create / temp+rename), which forces the overlay to **whiteout the root-owned lower entry** — privileged. On the **kernel** backend wine runs as **root-in-userns** (has `CAP_MKNOD`/`DAC_OVERRIDE`/`FOWNER` there) → the replace would succeed → the hive would drift into the upper; on **fuse** wine is **unprivileged** → **EPERM** → the store hive stays truly read-only. **Fix:** on the kernel backend, pin the two hives with **namespace-local read-only bind mounts** of the store copies over the merged paths (fuse needs none — already read-only). Wine's save then fails EROFS (in-place) / EBUSY (rename-over-mountpoint) and is **skipped with no error** — HK unaffected. A defensive pre-mount `rm` also clears any legacy shadow. (Tried + rejected: removing write from the prefix-root dir also blocks the needed `user.reg`; a sticky bit doesn't help — ns-root **owns** that dir and sticky exempts the dir owner, verified `rm` succeeded.) Verified both backends 2026-08-09: HK launches, upper holds **only** HKCU (no `system.reg`/`userdef.reg` shadow even transiently), clean teardown. |
| **Symlink farm supersedes BOTH overlay backends — finalized §7.2 design** (measured 2026-08-09) | Both overlay backends (rows above) are dropped. The prefix is now a plain persistent per-app directory — **no overlay, no mount, no namespace**. Read-only content (`drive_c/windows/*` except temp, `Program Files*`, `system.reg`, `userdef.reg`, `.update-timestamp`) is **symlinked to the store** and recreated each launch; writable content (`user.reg` as a REAL file, `drive_c/users`, `ProgramData`, `windows/temp`, `dosdevices`) is real + persists. Verified: HK runs on native Wayland; `user.reg` is a ~900 KB real file that persists across launches; the store symlinks survive a run (wine writes *through* `drive_c/windows` to the `0444` DLLs → EACCES, never rewriting them); teardown strands nothing. **Why it replaced the overlays:** no mount → nothing can strand and no `fusermount3`/`fuse-overlayfs` dep; **no userns → every host group (`video`/`kvm`/`pipewire`) is preserved** — the userns group-loss that forced the fuse fallback is gone, so there is one backend; direct store access is at least as fast as any overlay. **The one wine subtlety** (why `user.reg` is a real file, not a symlink): wine's save clobbers a symlinked *file* — harmless for the RO hives (discarded + relinked each launch, so they stay authoritative from the store) but it would lose HKCU, so `user.reg` is a real file wine writes in place. (A symlinked `user.reg` write-through held only for a *pre-existing writable* target + a single reg-write; a full run clobbers it — hence the real file.) |
| `WINEESYNC`, `WINEFSYNC`, `WINE_LARGE_ADDRESS_AWARE`, `WINE_CPU_TOPOLOGY` | **zero occurrences** in 11.0 / staging 11.12 — dead knobs. Wine 11 uses `ntsync` automatically on kernel ≥ 6.14 |
| `hangover` is not in nixpkgs | — |

## 10. Microsoft Store delivery (measured 2026-08-06, `9NKSQGP7F2NH` WhatsApp Desktop)

Spike: [`poc/msstore/`](poc/msstore/README.md). Full chain run anonymously, plus a complete download.

| Fact | Evidence |
|---|---|
| **No Microsoft credential of any kind is needed** for a free app | whole chain runs with an empty MSA ticket `<User/>` |
| The tickets token is nonetheless **mandatory and validated** | bare `Timestamp` → `a:InvalidSecurity`; empty `<User/>` → **200**; bogus ticket → **400** |
| FE3 TLS can be **properly verified**, not disabled | pinning *Microsoft Root Certificate Authority 2011* → chain + hostname validation pass, TLS 1.3 |
| That root is in **no** public bundle | `grep -c` in nixpkgs `cacert` ca-bundle.crt → **0**; default client → `unable to get local issuer certificate` |
| Root is stable and cheap to vendor | SHA1 `8F:43:28:8A:D2:72:F3:10:3B:6F:B1:42:84:85:EA:30:14:C0:BC:FE`, valid 2011-03-22 → **2036**-03-22, 2 KB |
| `SyncUpdates` is a **tree walk to a fixpoint**, not 1 or 2 calls | from cold: round 1 → 0 files/110 ids, round 2 → 0 files/60 new ids, round 3 → **20 files** |
| `Extended` must be the **only** `XmlUpdateFragmentType` | adding `LocalizedProperties` → same 30 `UpdateInfo`, **0** `<File>` |
| Identity and file metadata are in **different sections**, joined by numeric `<ID>` | `<NewUpdates><UpdateInfo>` has `UpdateIdentity`; `<ExtendedUpdateInfo><Updates><Update>` has `<Files>` |
| `GetExtendedUpdateInfo2` requires the **`/secured`** endpoint | plain endpoint → `InvalidParameters` regardless of body |
| URLs **must** be HTML-unescaped | escaped → params parsed as `['P1','amp;P2','amp;P3','amp;P4']` → **403**; unescaped → **206**, `bytes 0-31/355088593`, magic `PK` |
| Bytes are verifiable from FE3 alone | full 355,089,031-byte download matched FE3 `Size`, SHA1 `Iad3RiajE2Y2NWctVPp+EZHNcdw=`, and SHA256 `I/MVywKPAIYHPUYmIuhMgpo20O+AjInq5jBMKOiiz0s=` |
| **DisplayCatalog describes a different build than FE3 serves** | catalog: 2.2629.0.0 / 2.2629.100.0 (354,987,964 B); FE3: 2.2630.1.0 / **2.2630.101.0** (355,089,031 B) |
| FE3 publishes the **framework dependency closure** | 8 VCLibs `.appx` (arm64/arm/x64/x86) returned alongside 2 WhatsApp bundles |
| ARM64 Windows payloads are obtainable this way | inner `WhatsApp.Root_2.2630.101.0_arm64.msix` (172 MB); `WhatsApp.Root.exe` PE machine **`0xaa64`** |
| The app is a packaged **Win32** app, not sandboxed UWP | `AppxManifest.xml`: `EntryPoint="Windows.FullTrustApplication"` → §9's extract-and-run applies |
| Chain generalises beyond one product | `9WZDNCRFJ3TJ` → 20 leaves, all with URLs |

Untested: paid or license-gated apps.

## 11. WinUI 3 / .NET under wine on aarch64 (measured 2026-08-06, WhatsApp 2.2630.101.0)

From `poc/whatsapp-arm64.nix`; record in `docs/verified/whatsapp-arm64.json`.

| Fact | Evidence |
|---|---|
| **.NET 8 self-contained CoreCLR starts under wine on aarch64** | CoreCLR 8.0.1525.16413 / .NET 8.0.15 loads and executes managed code |
| WindowsAppSDK activation works | `RoGetActivationFactory` succeeded for `Microsoft.Windows.AppLifecycle.AppInstance` **and** `Microsoft.UI.Xaml.Application` |
| **WinUI 3 then aborts, unconditionally** | `wine: Call from … to unimplemented function ntdll.dll.NtCreateWaitCompletionPacket, aborting`, right after `AppPolicyGetWindowingModel` |
| The reported CLR "unhandled exception" is the same event | `exception code 80000100` = `EXCEPTION_WINE_STUB`, i.e. the stub abort itself, not a second fault |
| The caller is the app's WinUI, **not** the CLR | `CoreMessagingXP.dll` is the only file in the package referencing the symbol |
| They are **static** imports — so no fallback exists | `pefile`: `STATIC ntdll.dll ['NtAssociateWaitCompletionPacket', 'NtCreateWaitCompletionPacket', 'NtCancelWaitCompletionPacket']` |
| wine implements none of them | string `WaitCompletionPacket` absent from the whole wine 11.0 source tree; unexported by stable 11.0, unstable 11.12, staging 11.12 (method validated against `NtCreateFile`) |
| No .NET knob helps | `DOTNET_ThreadPool_UsePortableThreadPoolForIO=0`, `…UsePortableThreadPool=0`, `…UseWindowsThreadPool=0`, and both together — all four gave an identical abort |
| Disabling `mscoree` breaks .NET apps | `err:module:fixup_imports_ilonly mscoree.dll not found, IL-only binary L"System.Runtime.dll" cannot be loaded`, then a hang. Wine's builtin mscoree exists for `aarch64-windows` and suffices |
| A headless `wineserver` leaking into the app kills all windows | `err:winediag:nodrv_CreateWindow`; fixed by ending prefix setup with `wineserver -w`, after which `winewayland.drv` initialises cleanly |
| **A crash strands an unclosable "Wine Debugger" console** | wine's default AeDebug handler is `winedbg --auto`; the crashed process is already dead so the window has no close path and must be killed by PID |
| Suppressing it needs a **non-empty, unresolvable** `AeDebug\Debugger` | an EMPTY value changed nothing: `start_debugger()` only takes `format` when `NtQueryValueKey` returns `STATUS_BUFFER_TOO_SMALL`, which a zero-length value never does, so empty ≡ absent ≡ built-in winedbg |
| A failing handler is the quiet path | non-empty value → used as command line → `CreateProcessW` fails → `start_debugger` returns FALSE with **no fallback**; verified: `Couldn't start debugger … (2)` once, **0** conhost windows |
| `Auto` must be **1**, not 0 | with `Auto=0` wine first tries a MessageBox asking whether to debug — another desktop dialog |

**Triage rule.** Check a Windows app's static imports for the wait-completion-packet family before
adopting it. No tunable can work around a missing *static* import, and implementing these needs a new
wineserver object type whose signalling queues completion packets onto an IO completion port.

## 12. 16K pages vs Windows PE sections (measured 2026-08-06, Zoom 7.1.5.43453)

From `poc/zoom-arm64.nix`; record in `docs/verified/zoom-arm64.json`. Triage tool:
`tools/wine-import-triage.py`.

| Fact | Evidence |
|---|---|
| A **writable + shared** PE section that is not host-page-aligned **cannot** be mapped | `err:virtual:map_file_into_view unaligned shared mapping … not supported` → `import_dll` fails `c000007b` → `loader_init` `c0000135`, exit 53 |
| This is **not** missing large-page support | wine 11.0/11.12, past 10.5; `page_mask` (4K) and `host_page_mask` (16K) are tracked separately and the other **152** binaries load fine |
| Wine has a fallback, but only for read-only | `virtual.c`: mmap only when `host_addr == map_addr`; else `mprotect`+`pread` (copy) — and `if (vprot & VPROT_WRITE)` it errors instead, rather than silently breaking cross-process visibility |
| **NT's 64K allocation granularity does not help** | it aligns image *bases*; sections are only guaranteed `SectionAlignment` (0x1000). `.PROPSEC` at base+`0x65000` ≡ `0x1000 (mod 0x4000)` — no 64K-aligned base can fix it |
| **Windows on ARM64 uses 4K pages** | so the binary is valid on real WoA; the mismatch is created solely by the 16K-page Linux host. WoA needs no large-page support — it has small pages |
| Scope was tiny | **1** writable+shared section in **153** binaries: `zCrashReport64.dll:.PROPSEC` `0xd0000040` |
| Clearing `IMAGE_SCN_MEM_SHARED` works | `0xd0000040` → `0xc0000040`; section becomes private, wine maps it, app starts |
| …but **breaks Authenticode, and the app notices** | Zoom ships `zSafeChecker.exe` and prompts: *"Zoom.exe is using zCrashReport64.dll from an unknown publisher"* — observed, not predicted |
| The wine **variant** is per-package data | `SetThreadpoolTimerEx` (needed by `zLooper.dll`): stable 11.0 **no**, unstable 11.12 **no**, staging 11.12 **yes** |
| `Graphics=wayland` is **not** a safe default | winewayland drew the real window **plus 3 blank white ones**; winex11 drew 1. Zoom's DuiLib uses layered windows. Corrects §9's Slack-derived "no reason to prefer x11" |
| winewayland is a **per-app** choice — HK works but the cursor is undersized (measured 2026-08-09) | Hollow Knight (Windows / wine+FEX) runs on `winewayland.drv` (`HKCU\Software\Wine\Drivers\Graphics=wayland`, `DISPLAY` unset) as a **single native Wayland window** (1600×1040, `xwayland:false`), stable, no `err:` — unlike Zoom. But on a **fractional-scaled output the cursor renders undersized** (≈ desktop-cursor size): winewayland doesn't scale the cursor surface to the output's fractional scale, whereas Xwayland scaled it to match the game. Game content renders/plays fine — it's a cosmetic cursor-scale gap. So x11/Xwayland stays the safer per-app default (correct cursor; needs `PROPNIX_DPI` for content scaling — §5), and winewayland is opt-in per title (native fractional content scaling, undersized cursor) |
| Wine **never** auto-detects DPI | only `HKCU\Control Panel\Desktop\LogPixels` (`sysparams.c: DWORD_ENTRY(LOGPIXELS, 0, DESKTOP_KEY, …)`); `winex11.drv` has **no** `Xft.dpi` handling |
| DPI scaling then works exactly | `LogPixels=154` on a `scale=1.6` monitor: window 546×392 → **876×631** (1.6×), user-confirmed readable |
| Predictive triage is cheap and correct | cross-checking imports against wine's exports cleared Zoom in seconds and named the 3 real gaps; it would have avoided 4 wasted WhatsApp experiments |

**Rule.** Run `tools/wine-import-triage.py` before packaging any Windows app. It reports missing
imports (fatal if the importer loads at startup, survivable if it is a lazy plugin) and flags
unaligned writable+shared sections.

### 12.1 EL0 PMU access — `mrs Xt, pmccntr_el0` traps on Linux

| Fact | Evidence |
|---|---|
| Windows-on-ARM64 binaries read the PMU cycle counter directly from user space | `mrs x22, pmccntr_el0` at zlt.dll+0x2ddd68; MSVC emits it for `__rdtsc`-style intrinsics |
| **Linux does not permit EL0 PMU access**, so it traps | crash a few seconds after joining a meeting, `ExceptionCode 0xc000001d` = `STATUS_ILLEGAL_INSTRUCTION` |
| The host sysctl route does not exist here | `/proc/sys/kernel/perf_user_access` (arm64, Linux ≥ 6.1) is **absent** on kernel 7.1.5 — Apple's PMU driver does not implement it |
| Substituting the virtual timer counter fixes it | `mrs Xt, pmccntr_el0` (`0xd53b9d00\|Rt`) → `mrs Xt, cntvct_el0` (`0xd53be040\|Rt`); CNTVCT_EL0 **is** EL0-readable (the vDSO clock reads it) |
| Scope was small and mechanical | **15** instructions in **6** binaries; scan 4-byte aligned only, since every A64 instruction is a naturally aligned word |
| Verified | faulting word now `d53be056 mrs x22, cntvct_el0`; 0 remaining `pmccntr_el0`; a later meeting ran with 0 illegal-instruction faults and produced no new crash dump |
| Caveat | CNTVCT ticks at the timer frequency (~24 MHz), not the CPU clock — code reading the delta as *cycles* is ~100× low. Still preferred over `mov Xt, #0`, which invites divide-by-zero and unbounded spin loops |

**An app's own crash reporter can beat wine's diagnostics.** Wine reported only
`Unhandled page fault ... at address <addr>` with no module, and enabling `winedbg` made it *worse*
(deadlock on `console_section`, no backtrace). Zoom's `logs/zoomcrash_*/crashrpt.xml` gave module,
module base, fault address and exception code directly — and the `.dmp` filenames name the module too.
**Look for the app's own crash artifacts before instrumenting wine.**

**Sealing can defeat debugging.** The D13 scrub glob `WINE*` also eats `WINEDEBUG`, so
`WINEDEBUG=+loaddll ./app` silently does nothing. Provide a namespaced passthrough
(`PROPNIX_WINEDEBUG`) rather than widening the glob — this is PLAN2 §7's `--propnix-unseal` in its
narrowest form, and it cost one wasted crash-reproduction round to learn.

### 12.2 Re-signing patched PE modules so an app's own integrity check passes

Any byte-level payload fixup (§12, §12.1) breaks the file's Authenticode digest, and apps that
verify their own modules notice. Tool: `tools/wine-trust-cert.py`.

| Fact | Evidence |
|---|---|
| A patched module fails the app's check with a specific, legible code | Zoom logs to `AppData\Roaming\Zoom\appsafecheck.txt`: `error code 2148098064` = **0x80096010 TRUST_E_BAD_DIGEST** |
| `osslsigncode` re-signs ARM64 PEs fine | `verify` goes from `Signature verification: failed` to `ok` against our CA |
| Signing **preserves** earlier byte fixups | after signing, `.PROPSEC` is still `0xc0000040` and `pmccntr_el0` count is still 0 — checked, because signing rewrites PE headers |
| Wine has **no working tool** to install a trust anchor | `programs/certutil` implements only `-decodehex`; `cryptext`'s PFX entry points are stubs |
| The registry store works instead | `dlls/crypt32/regstore.c` reads REG_BINARY `Blob` from a subkey named after the SHA1 thumbprint, under `…\SystemCertificates\{Root,TrustedPublisher}\Certificates\` |
| Blob = property records | `dlls/crypt32/serialize.c`: `{ DWORD propID; DWORD unknown=1; DWORD cb; }` + `cb` bytes |
| **`CERT_FIRST_USER_PROP_ID` (0x8000) is REQUIRED** | without it `rootstore.c check_and_store_certs()` logs `CERT_FIRST_USER_PROP_ID property absent for cert` and `continue`s — the cert lands in `system.reg`/`user.reg` and is then **silently ignored** |
| Store `is_new = 0` in that record | marks the cert already-vetted, so wine leaves it rather than re-validating/pruning it |
| End result | Zoom's verification error code went **2148098064 → 0**: WinVerifyTrust succeeds |

**The limitation that matters.** This makes a signature *valid and trusted*; it does not make it
belong to a *particular publisher*. An app that pins its own publisher still rejects the module at
error code 0. Zoom does exactly that — its binaries embed `Zoom Communications, Inc.` /
`Zoom Video Communications, Inc.`, and the shipped signature's subject is
`CN=Zoom Communications, Inc.` (issuer DigiCert Trusted G4 Code Signing) — so its dialog persists
even with a perfectly valid signature.

**How Zoom's module check actually works** (proven by disassembly, `sub_249b8` in `Zoom.exe`):

```
WinVerifyTrust                   validity — returns 0 for a locally-issued, locally-trusted signature
WTHelperProvDataFromStateData    take the verification state
WTHelperGetProvSignerFromChain   -> the signer
WTHelperGetProvCertFromChain     -> the signer's CERTIFICATE
   then, per certificate in the chain:
CertGetNameStringW (flag 4)      -> the cert's display name
   strcmp against four embedded strings, and return w0=1 (trusted) iff BOTH:
     leaf name == "Zoom Communications, Inc."  OR  "Zoom Video Communications, Inc."
     AND a CA  == "DigiCert"                   OR  "Entrust Root Certification Authority"
```

So the check is on NAMES in a validating chain, and it **pins the CA as well as the publisher**. The
log line `didn't pass the verification, error code 0` means WinVerifyTrust succeeded (0) and Zoom's own
name comparison then failed.

**A flip-flop, owned.** This section went: (1) "pins DigiCert/Entrust" — correct, but argued from
string proximity; (2) retracted to "no name check, only WinVerifyTrust" — **wrong**, over-corrected off
the TLS binaries (`XmppDll`/`zNet`/`tp`/`zKBCrypto` call `CertGetCertificateChain` /
`CertVerifyCertificateChainPolicy` to validate Zoom's **server** certificates — unrelated to module
checking); (3) disassembly is ground truth and confirms (1). Twice this session a mechanism was
asserted from inference and walked back — disassemble before asserting.

**Consequence:** no locally issued certificate can pass, at any subject name. A build with an exact
`O`/`CN=Zoom Communications, Inc.` subject was tested and still prompted, because a self-signed cert
supplies the leaf name but no DigiCert/Entrust-named CA in its chain. Passing would need a certificate
genuinely issued by DigiCert/Entrust in Zoom's name — impersonating a public CA — which is out of
scope, as is naming a self-signed cert after a CA to fool the name compare.

**Two dialog-suppression workarounds were tried and abandoned** (walked back from the package):
synthetic dismissal via `xdotool` (unreliable under Xwayland — the keystroke lands in the focused
window), and binary-patching the check out of `Zoom.exe`/`Cmmlib.dll` (the finder locates `sub_249b8`
via its `WTHelperGetProvCertFromChain` call site and rewrites the entry to `mov w0,#1; ret`, but it is
version-fragile and disables an anti-tamper defence). For an advisory prompt you can click through,
neither is worth it; on Zoom the dialogs are accepted.

**The signing technique is worth keeping regardless:** most apps that verify modules check validity,
not publisher identity, and for those this fully removes the warning and leaves the patched binaries
honestly signed. Retained as infrastructure (`tools/wine-trust-cert.py`, `tools/mk-codesign-cert.py`).

### 12.3 Generating the signing identity deterministically

Tool: `tools/mk-codesign-cert.py`. Committing a key is one option; generating one in the sandbox is
more legible but must not be *random*, because a random key in an **input-addressed** store path
means the `.drv` hash is fixed while the contents are not — after a GC and rebuild the same path can
hold a different key while an already-built payload still carries the old signatures, desynchronising
trust anchor and signatures with nothing looking wrong. `ca-derivations` would fix it structurally
but is not enabled here (`experimental-features = fetch-tree flakes nix-command pipe-operators`).

| Fact | Evidence |
|---|---|
| **`libredirect` cannot make OpenSSL deterministic** | it rewrites *paths*; OpenSSL 3's seed source calls `getrandom(2)`, often via `syscall()`, so no `LD_PRELOAD` path shim sees it — and its DRBG personalises with time/pid regardless |
| Controlling the random *function* works | `pycryptodome` `RSA.generate(randfunc=…)` fed an HMAC-SHA512 counter stream: same pubkey sha256 across runs |
| The certificate needs three more things pinned | **fixed serial**, **fixed notBefore/notAfter** (any `now()` breaks it), and **PKCS#1 v1.5** signing — PSS is randomised. Result: byte-identical DER across runs |
| **`osslsigncode` embeds a `signingTime`** | without `-time`, two signings of one input gave different sha256; with `-time <epoch>`, identical. An invisible landmine — the cert can be perfectly deterministic and the *signature* still not be |
| Verified at the nix level | `nix-store --realise --check` on the generator derivation rebuilt and matched |

**Capabilities to issue, and to assert.** The generator both sets and then *checks*:

```
basicConstraints critical CA:FALSE            not a CA
keyUsage         critical digitalSignature    no keyCertSign -> cannot mint identities
extendedKeyUsage critical codeSigning         not usable for TLS, e-mail, anything else
```

**`nameConstraints` does not help.** RFC 5280 §4.2.1.10 defines it as constraining subject names in
*subsequent* certificates in a path, and it MUST appear only in a CA certificate. With `CA:FALSE` and
no `keyCertSign`, issuance is already impossible — strictly stronger than limiting issuance. And no
X.509 extension expresses "may only sign these files"; the only remaining lever is **time**, so keep
validity short and add no timestamp countersignature so signatures expire with the certificate.

**What determinism buys, and what it does not.** Legibility (constraints live in the expression) and
reproducibility (honest store paths, no key in git). *Not* secrecy: everyone building the same subject
derives the same key, so the exposure matches a committed key. Genuine per-user keys require
generating outside the store (state dir, mode 0600), which forces runtime signing and a writable
application directory — a different design, not a tweak.

## 13. Fixed-output derivations and CA certificates

| Fact | Evidence |
|---|---|
| **`pkgs.cacert` must be a real build input, not just interpolated into `SSL_CERT_FILE`** | with it only in the string, Python's default context loaded **0** CA certs |
| nix does set `SSL_CERT_FILE` itself in a FOD sandbox, at that same store path | measured: attribute value and `$SSL_CERT_FILE` matched exactly, yet the file was unreadable |
| The failure is badly misleading | `CERTIFICATE_VERIFY_FAILED … self-signed certificate in certificate chain` — reads as a proxy/server fault, not a missing file |
| With cacert as a build input | 166 certs loaded, DisplayCatalog returned 200 |

---

## 14. FEX on large host pages — the `fex-portable` bring-up (measured 2026-08-06)

Packaged as `preliminaries/fex-portable/` (`pkgs.fex.overrideAttrs` + `fex-portable.patch`).
`flake:nixpkgs`'s `fex.src` is byte-identical to the 2605 source the patch was cut against, so it
applies clean and builds in the pure sandbox (validated). Runs x86_64 static ELFs correctly:
`hello`, `coreutils sha256sum` (correct digests), `factor` (correct factorisation), `uname -a`
(guest reports `x86_64`), stable across runs.

**The mismatch.** The guest sees 4K pages; the host kernel only accepts `mmap`/`mprotect` on 16K
boundaries. `FEX_PAGE_SIZE=4096` is correct as the *guest* page and must stay — the bug is the ~9
sites that used it as the *host* page. Fix = derive the host page from `sysconf(_SC_PAGESIZE)`.

**Diagnosis method that worked.** `strace -f -e mprotect,rt_sigreturn,mmap` on the storming run.
Each wall showed as either a `... = -1 EINVAL` `mprotect`, or a tight `SIGSEGV → rt_sigreturn`
loop on one address; mapping that address back to its owning `mmap` region named the culprit.
Two methods that did **not** work: `gdb -p` attach (empty backtrace), and `write()` probes inside
the C++ signal handler (never fired — FEX routes these faults through signal fast-paths).

| Fact | Evidence |
|---|---|
| jemalloc refuses to start unless compiled-page ≥ system-page | `LG_PAGE` 12 → 16 (not 14): a 64K-compiled jemalloc runs on 16K/32K/64K. Verified LG_PAGE=16 runs on this 16K host |
| ELF `PT_LOAD` segments are 4K- but not 16K-aligned | static `hello`: loads at `0x400000` (16K-ok) but `0x401000`/`0x412000` (4K-only) → per-segment `MAP_FIXED` is impossible on 16K; span-reserve + `pread` instead |
| VDSO placement spun, not hung | unaligned `MAP_FIXED_NOREPLACE` hint `EINVAL`s every attempt; top-down scan runs ~2³³ iterations |
| **The dominant storm was the CALLRET stack** | one `mprotect(AllocBase+4096, 4MB, RW) = -1 EINVAL` — the 4K guard page left the base 4K past a 16K boundary; the 4 MB stack never committed, so every guest `CALL` faulted `SEGV_ACCERR` at the same address 100k+×/sec, the overflow handler resetting the SP and returning into the same fault |
| The overflow handler does **no** `mprotect` | strace showed pure `SIGSEGV → rt_sigreturn` with nothing in between — proof the page was never being fixed, only re-entered |
| SMC / on-demand commit needs the whole host page | after CALLRET, a second storm: `mprotect(0x43d000, 4096, RW) = -1 EINVAL`. The write-fault handler commits the faulting 4K page; snapping it to the enclosing 16K page (granting RW) resolves it — the *most-lenient* answer to mixed sub-page permissions |
| Guard/PROT_NONE removal must **not** widen | an early over-eager `VirtualProtect` that widened a PROT_NONE to the host page clobbered live neighbours (self-inflicted `SEGV_ACCERR`); the fix is asymmetric — widen when adding access, shrink-to-contained when removing it |
| SMC (`MTRACK`) works on 16K once both its `mprotect`s are host-page-snapped | the on-write handler (`UnprotectRegionCallback`) and the protect side (`MarkGuestExecutableRange`, `mprotect(PROT_READ)`) both snap out to the enclosing host page; upstream's `MTRACK` default is kept and all regressions pass. Cost: RO-protecting a code page also protects its 16K-page neighbours, so writes there fault (correct, but slow for mixed code/data pages) |
| A JIT that patches code in place is still not fully working | Hollow Knight (Unity/Mono) loads Mono and inits Unity under fex-portable, then a guest `SIGSEGV {SEGV_MAPERR, si_addr=NULL}` (a null jump) during early Mono runtime init — beyond the SMC fix. Likely needs per-4K shadow permissions (exact large-page SMC + guest `mprotect`), since Mono's Boehm GC (`libmonobdwgc`) also does its own 4K `mprotect`-based dirty tracking that FEX can only apply at 16K. box64 runs this game today (hardware GL, native bridging) |
| **Dynamic linking needs sub-host-page mmap emulation** | static ELFs run once walls 1–8 are cleared, but any *dynamically*-linked guest fails at `libc.so.6: failed to map segment` — the guest `ld.so` maps each shared-library PT_LOAD with a file-backed `MAP_FIXED` at 4K granularity (`mmap(0x…2bf000, …, fd, 0x1a7000)`), which the 16K kernel rejects when the address or offset is sub-host-page |
| `vaddr ≡ offset` holds only mod 4K, not mod host page | a segment at addr%16K=0x2000, offset%16K=0x1000 breaks the naive "align both to host page" fix; the emulation splits into a leading in-place fragment plus an anonymous, `pread`-filled aligned remainder |
| The linker reserves the whole file first | so the leading fragment's host page is already mapped — it can be made writable (COW) and filled in place without disturbing the neighbouring segment sharing that host page |

Portability: only `LG_PAGE` is compile-time; everything else is runtime `sysconf`, so one
`fex-portable` binary is page-size portable across 4K/16K/32K/64K. Static and dynamically-linked
x86_64 both run (dynamic verified: glibc, libstdc++, libm, libgcc_s).

## 15. x86_64 Windows on 16K via wine+FEX (measured 2026-08-07)

The Linux FEX path (§14) runs static/dynamic x86_64 but Mono's JIT + graphics defeat it on 16K.
The **Windows** path sidesteps that entirely and runs a real game. Packaged in
`preliminaries/wine-fex/` (`llvm-mingw.nix`, `fex-dlls.nix`, `wine-hangover.nix`, `winefex.nix`,
`hollow-knight-win.nix`).

| Fact | Evidence |
|---|---|
| Native-ARM64 wine + FEX-as-ARM64EC-emulator runs x86_64 PEs on 16K | `hello.exe`, a compute/FP `wintest.exe`, and the **Windows Hollow Knight** all run; the game is playable (save started, starting area walkable) |
| The Windows FEX build avoids the Linux 16K walls | FEXCore's bundled jemalloc is gated `if (NOT MINGW)`; memory/loader/Mono/graphics are wine's (native ARM64), FEX only JITs x86_64 blocks |
| Stock nixpkgs wine cannot host x86_64 — it builds **plain ARM64**, not ARM64X hybrid | `llvm-readobj --coff-load-config` on `ntdll`/`kernel32`/`kernelbase`: `CHPEMetadataPointer: 0x0` |
| The fix is two lines over nixpkgs wine | add `arm64ec` to `--enable-archs` (→ ARM64X hybrid core DLLs, CHPE present), and `dontStrip = true` |
| **Stripping breaks the ARM64X hybrid** | stripping drops sections (ntdll 28→8) so the load-config `DynamicValueRelocTableSection` index points at the wrong section; wine's `update_arm64x_mapping` then never rewrites the header machine `ARM64`→`AMD64` for the EC view → `STATUS_NOT_SUPPORTED` (`0xc00000bb`) loading ntdll. Unstripped dev build (same source/flags) works; instrumented flip: `pre hdr=aa64 → post hdr=8664` |
| No wine source patch needed | stock wine 11.0's loader is byte-identical to Hangover's `AndreRH/wine arm64ec` in the ARM64X path; only stripping differed |
| Emulator wiring | FEX `libarm64ecfex.dll` (x86_64/ARM64EC) + `libwow64fex.dll` (i386) in `system32`, registered at `HKLM\Software\Microsoft\Wow64\{amd64,x86}` |
| GOG Windows installer is a single self-contained InnoSetup .exe | file id `en1installer0` (~1.2 GiB); `en1installer1+` don't exist; game files are `[en-US]`-tagged so `innoextract` needs `--language en-US` |
| Graphics | wined3d (D3D→OpenGL) on the Apple GPU; gameplay renders. Opening cinematics: audio decodes, video absent — a wine Media-Foundation video-pipeline limit, see §18 (skippable) |

## 16. Application VFS layers reject symlink farms (measured 2026-08-07, Stellaris 4.4.6)

A composed game tree built the Nix-idiomatic way — top-level directories symlinked into a shared
unpacked base so several content selections can share one 27.7 GiB payload — **does not work when the
application reads through PhysFS.** Stellaris links PhysFS (`__PHYSFS_Archiver_{DIR,ZIP,7Z}` and
`Failed to mount %s with error %s` are in the binary), and PhysFS refuses to traverse a symlink
unless `PHYSFS_setSymbolicLinksPermitted(1)` is called, which defaults off and which Clausewitz never
calls. Measured:

```
[virtualfilesystem_physfs.cpp:795] File 'gfx/loadingscreens/init.bmp' does not exist : symlinks are forbidden
terminate called after throwing an instance of 'std::logic_error'
```

— before any window appeared. **The emulator is not involved**: PhysFS `lstat`s the path components
itself, so this is identical under box64, FEX or a native x86_64 host.

Consequences for composition generally:
- `symlinkJoin`/`buildEnv` over a game tree is **not** a safe default. It is safe for content that
  sits *beside* the application (Hollow Knight's soundtrack under `share/`), and unsafe for anything
  the application resolves through its own VFS.
- Where real files are mandatory, do not split "unpack" and "compose" into two derivations: copying
  27.7 GiB is no cheaper than extracting it, so the split costs the same wall clock and twice the
  store. Fuse them and pay one tree per selection.
- Assert it in the builder — `find "$out" -type l` — because the runtime failure mode is a crash, not
  an error message.

Other engines to suspect: anything shipping PhysFS (a common indie/Paradox choice) and anything that
resolves its root through `/proc/self/exe`, which follows symlinks and would report the *shared base*
rather than the composed tree.

## 17. SDL video backend on this compositor (measured 2026-08-07)

`SDL_VIDEODRIVER=x11` is **not** a general default. It is per-package, and the two backends differ in
more than plumbing on a HiDPI Wayland session. Display: 2560x1664, compositor scale 1.601562.

| | Stellaris 4.4.6 (SDL2 static) | Hollow Knight 1.5.12620 (Unity 6000.0.61) |
|---|---|---|
| `x11` (XWayland) | works; SDL reports **2560x1664**, renders pixel-exact | works — the verified configuration |
| `wayland` | **works**; maps native `libwayland-{client,cursor,egl}` + `libxkbcommon`; same OpenGL 4.6 Mesa device; SDL reports the **logical 1600x1040** and the compositor upscales | **crashes**: reaches `Creating OpenGL 4.6 graphics device`, then `a fatal error in the mono runtime or one of the native libraries`, SIGILL |

**Wayland is not simply faster.** 1600x1040 is 2.56x fewer pixels than 2560x1664, so most of the
observed smoothness is resolution, not backend efficiency; the rest is the missing XWayland
indirection. The cost is an upscaled image. x11 buys pixel-exactness and a UI scaled for a
non-HiDPI display. Neither dominates, so the choice belongs in a per-package runtime knob
(`PROPNIX_SDL_VIDEODRIVER`), defaulting from `WAYLAND_DISPLAY` — a runtime decision about a *value*,
which PLAN2 §5 permits, unlike a decision that would shape the derivation graph.

**Hollow Knight's wayland crash is not a missing-library problem.** The wayland path loads the
payload's bundled `libdecor-0.so.0`, which x11 never touches, and under `BOX64_PREFER_WRAPPED=1`
box64 tries to bridge it natively along with `libdbus-1` and `libz`. Supplying all three natively
removed every `Error initializing native` line and produced the **identical** Mono SIGILL, so the
bridge failures were a symptom, not the cause. Unity's Mono under box64 on the wayland path is
unexplained and stays on x11.

## 18. Media Foundation video under wine — Hollow Knight cinematics (measured 2026-08-07)

Hollow Knight's opening cinematics are Unity `VideoPlayer` clips (H.264 in an MP4/QuickTime container,
embedded in the `.resS` data — no external video files), decoded on Windows via Media Foundation.

- **Stock nixpkgs `wineWow64Packages.stable` is built WITHOUT gstreamer** (`gstreamerSupport ? false`,
  and no variant flips it). So `winegstreamer.dll` is absent and MF has the API DLLs (`mfplat`, `mf`,
  `mfreadwrite`, `mfmediaengine`) but **no decoder backend**. Unity's `MFCreateSourceReader` then can't
  create the MPEG-4 byte-stream handler (CLSID `{271c3902-6095-4c45-a22f-20091816ee9e}`, registered by
  winegstreamer) → `err:ole:com_get_class_object … not registered` and `CoCreateInstanceEx … hr
  0x80040154` (`REGDB_E_CLASSNOTREG`). Cinematics are black **and** silent.
- **Building wine with `gstreamerSupport = true`** (pulls `gst_all_1.{gstreamer,plugins-base,good,ugly,
  bad,libav}` — all on `cache.nixos.org`) registers the MF classes: the COM errors vanish and the
  cinematic **audio plays**. **Video is still absent.**
- **The video failure is not the codec.** GStreamer initially auto-plugs the V4L2 stateless hardware
  H.264 decoder `v4l2slh264dec` (from gst-plugins-bad's v4l2codecs), which fails under wine. Demoting it
  with `GST_PLUGIN_FEATURE_RANK=v4l2slh264dec:NONE` (a runtime env var winefex passes through — no
  rebuild) removes that path (`v4l2slh264dec` occurrences 2→0) but the video failure is **unchanged**
  (`gst_video_info_from_caps` critical count stays 2). The software `avdec_h264` (gst-libav) is present.
- **The blocker is wine 11 mainline's Media-Foundation *video* pipeline**, downstream of the decoder:
  `winegstreamer wg_format_from_caps: Unhandled caps video/quicktime, variant=iso`, repeated
  `GStreamer-Video-CRITICAL gst_video_info_from_caps: assertion 'gst_caps_is_fixed (caps)' failed`, and
  wine's `video_processor` MFT (the format-conversion transform) stubbing its messages
  (`fixme:mfplat:video_processor_ProcessMessage Ignoring message 0x10000003`). Frames are never delivered
  to Unity's texture.
- **wine-staging does not fix it (measured 2026-08-07).** Rebuilding the hybrid on
  `wineWow64Packages.staging` (11.12, same `+arm64ec` / `dontStrip` / `gstreamerSupport`) reproduces the
  identical failure — the same `gst_video_info_from_caps` caps-critical and `video_processor` MFT stub
  (staging routes the latter through `fixme:dmo:` rather than `fixme:mfplat:`, same effect). So the gap is
  in the shared winegstreamer / MF-video path, not the mfplat patches; neither mainline nor staging
  renders the video in the arm64ec+FEX config. Left as a **known limitation** — cinematics are skippable.
  (This does not drive the base-wine choice: the hybrid is on **staging** (11.12) for the general
  game-focused patchset — §10 / `wine-hangover.nix` — and staging doesn't fix this video gap either.) The
  only untried avenue is shipping native Windows MF DLLs (Proton's `mf-install`), which is
  redistribution-problematic and not pursued.

## 19. Startup time (wall-clock to playable) — cost model + knobs (measured 2026-08-08)

Companion to PLAN2 §2.3(3). A wine+FEX launch pays, in order: (1) prefix provisioning (`wineboot -u` +
FEX-DLL install + Wow64 keys — **moved to BUILD time** into the store lower (`wine-prefix-lower.nix`), so
it is no longer paid at first launch; the runtime only assembles the symlink farm — a few dozen store
symlinks + a small writable profile skeleton, <0.1 s); (2) wineserver cold start; (3) Windows-runtime init (ntdll/kernel32 load +
ARM64X→EC flip); (4) **FEX cold JIT** — every x86_64 block re-translated from scratch, over DLLs read
**cold from the store** (no page-cache pre-warm now that `wineboot` no longer runs first); (5) engine +
GPU init. box64 pays only (4)+(5) analogues (no prefix, no wineserver) — the structural reason it's
faster. **The dominant, currently-unfixable cost is (4): FEX re-JITs everything every launch.**

- **Measured TTFW (Hollow Knight, overlay `winefex`, this 16K host, 2026-08-08).** With the **build-time
  store lower** (`wine-prefix-lower.nix`) + cheaply-seeded writable upper: cold (empty upper+saves) =
  **21.9 s** = 0.1 s seed+mount + 21.8 s launch→window; warm (upper present) = **4.8 s** = 0.0 s mount +
  4.8 s launch→window. For comparison the earlier *lazy* build (provisioning `wineboot` at first launch)
  measured cold **28.6 s** (22.3 s provision + 6.3 s launch→window), same warm 4.8 s. So build-time
  provisioning cut cold by ~7 s (net) but did **not** collapse cold to warm as first expected — there is a
  persistent ~17 s cold-over-warm gap. A 2×2 factorial (upper: fresh|existing × ZFS ARC: warm|cold,
  measured 2026-08-08) attributes it precisely:

  | upper \ ARC | warm | cold |
  |---|---|---|
  | fresh    | 5.2 s | 21.9 s |
  | existing | 4.8 s | 22.3 s |

  **ARC state is the only variable that matters** — cold ARC ⇒ ~22 s, warm ARC ⇒ ~5 s, independent of the
  upper. So the gap is **cold DLL page-cache**, NOT FEX cold-JIT (constant — the JIT never persists, so
  warm's 4.8 s already pays a full cold-JIT of HK's startup path), NOT prefix provisioning (build-time
  now), and NOT fresh-upper first-run work (font-cache build etc. cost only ~0.4 s: fresh+warm 5.2 vs
  existing+warm 4.8). The old lazy `wineboot` step had incidentally pre-warmed the DLLs; build-time
  provisioning removed that pre-warm, exposing the read.

- **`wineboot` provisioning is ~20 s of cache-INDEPENDENT work, not cold reads** (measured warm,
  2026-08-09). Timing a full `wineboot -u` into a fresh prefix with the wine closure already warm gave
  **20.3 / 20.5 / 21.1 s** across three back-to-back runs — flat from cold→warm, so the cost is intrinsic
  FEX-emulated provisioning work (`wineboot.exe` + `services.exe` + `rundll32 wine.inf` generating the
  3.7 M `system.reg` + 915 K `user.reg`), NOT the cold DLL page-cache. So the build-time lower genuinely
  removes ~20 s of first-launch **work**; the smaller ~7 s *net* cold win (vs lazy) is only because the
  lazy `wineboot` had incidentally pre-warmed the closure the game now reads cold (above), not because the
  provisioning was itself cache-bound. (Distinct from HKCU *regeneration* when `user.reg` is dropped from
  the lower — that just materializes wine's built-in HKCU defaults + the font list, ~2.7 s warm / +0.1 s
  over a seeded `user.reg`, and is NOT a `wineboot`; measured 2026-08-09.)

  **Where the cold read actually is (measured, ARC just cleared).** Datasets differ sharply on this
  Asahi/ZFS host: `/nix/store` is `rpool/sys/nix` (**unencrypted**); `$HOME`/`~/.local/state` and the
  scratch `/tmp` used by the experiment are `rpool/enc/*` (**aes-256-gcm**, and ARM has no AES accel so
  encrypted cold reads are slow). **Recordsize: `rpool/sys/nix` = 1 MB; `rpool/enc/*` = 32 KB** (so a
  single small read of a sub-1 MB `/nix` file pulls the whole file's record into the ARC). The working set
  the loader faults is almost entirely on **fast unencrypted `/nix`**: a pure cold-read (no HK, `find|xargs -P6 cat`) gave **wine-lower 295 MB in 5.3 s =
  55 MB/s** and **game 1130 MB in 4.7 s = 242 MB/s**. So the split is not encryption but **file shape**:
  the wine lower is hundreds of small DLL/`.nls` files → metadata/latency-bound (55 MB/s); the game is a
  few large asset files → bandwidth (242 MB/s). The only encrypted data in the launch is the ~1.9 MB prefix
  upper + saves — negligible here (would matter only for a title with GB-scale encrypted AppData/saves).

  **Prefetch lever — the final design + the exploration.** `winefex` warms the wine LOWER only, in the
  background at launch (before prefix assembly), via `propnix-prefetch` (tokio Rust helper, chunked
  `posix_fadvise(WILLNEED)`) — the **sole** prefetcher, no method/scope knobs (`PROPNIX_NO_PREFETCH=1`
  disables). Two warmer implementations were built and measured cold (warm prefix, HK):

  | warmer (lower-only unless noted) | cold TTFW |
  |---|---|
  | none | 22.3 s |
  | `read` — synchronous parallel reads (`xargs -P6 cat`) | 19.0 s (17.5 s if the game dir is warmed too; `-P16` ≈ `-P6` → pool-throughput-bound) |
  | `fadvise` — chunked `WILLNEED` (`propnix-prefetch`, **SHIPPED**) | 20.3 s (20.6 s incl. game dir) |

  (`ionice`/CFQ is moot throughout — NVMe scheduler `none`; ZFS bypasses the block layer.)

  **ZFS async prefetch — resolved (multi-agent research vs zfs-2.4.3 source + on-host proof, 2026-08-09).**
  **`posix_fadvise(WILLNEED)` is NOT a code-level no-op.** `zpl_fadvise` (registered unconditionally) maps
  WILLNEED to `dmu_prefetch(…, ZIO_PRIORITY_ASYNC_READ)` with `rlen = len ? len : isize-off` (so `len=0`
  and `len=filesize` are the *identical* code path — that's why they measured the same, not evidence of a
  no-op). It issues real async reads that land L0 data in the ARC — **proven on this host**: WILLNEED over
  a cold 115 MB file drove 115 MB of disk I/O, grew ARC by ~128 MB, and made the next `read()` finish in
  81 ms with zero disk. Crucially it reads at **ASYNC_READ**, which the two-phase vdev scheduler always
  issues *behind* SYNC_READ (wine's demand faults) — so it **yields to wine for free, no knob** (measured
  0.89× foreground latency under 640 MB/s background prefetch). This is the async-that-yields primitive the
  question asked for; `read()`/`cat` cannot be reclassified off SYNC_READ from userspace.

  Our apparent no-op had three real causes, now identified: **(1) `dmu_prefetch_max` = 128 MiB per-call
  cap** (host default `134217728`) — beyond it only indirect/metadata is prefetched, so large game assets
  warmed only their first 128 MiB; **(2) prescient-prefetch buffers are eviction-preferred** — the 10 s
  idle gap on the ~3.4 GB at-target ARC reclaimed them before launch (overlap the launch, or demand-touch
  to promote to MFU); **(3) FUSE drops `fadvise`** — advising a FUSE-overlay path never reaches ZFS (our
  tool used raw `/nix` paths, so this bit only if the *launcher's* fds are overlay paths). Also relevant:
  the ARC caches prefetch **compressed** (`zfs_compressed_arc_enabled=1`, dataset is **zstd**), so a demand
  read still pays decompression → the warmed class is **~17–20 s**, not the 4.8 s decompressed-MFU floor,
  unless a demand touch promotes the buffers. Host has non-default `zfs_vdev_sync_read_{min,max}_active=4`
  (upstream 10) — harmless, low-value to restore (wine's dlopen-chained reads are largely serial).

  **Why `fadvise`, not the ~1.5 s-faster `read`:** `read` wins on raw latency because wine *under-drives*
  the latency-bound disk — racing it with synchronous parallel reads beats yielding, whereas the async
  `WILLNEED` fills only idle slots, so concurrently it warms wine's critical DLLs only a little ahead of
  demand (reaching ~20 s, not the ~5 s an isolated full warm hits). But `fadvise` is the more
  portable/idiomatic warmer — async ZFS `dmu_prefetch` that yields to concurrent foreground I/O, degrading
  to plain readahead on `generic_fadvise` filesystems — and the ~1.5 s gap is an accepted trade. Lower-only
  ≈ both-layers (20.3 vs 20.6 s, within noise) and is bounded/game-size-independent. **Decision
  (2026-08-09): `propnix-prefetch` (chunked `WILLNEED`, lower-only) is the SOLE prefetcher** — no
  method/scope knobs; `PROPNIX_NO_PREFETCH=1` disables.

  **Evidence.** De-risk (`warm-exp.sh fadvise-bench`, cold ARC, HK-free): chunked `WILLNEED` on raw `/nix`
  drove **1424 MB** of async reads into the ARC (**+1469 MB** ARC), and an immediate full follow-up read
  hit NVMe for only **5 MB** — so it warms the whole working set and it *sticks* with no idle gap (chunking
  defeats the 128 MiB cap; no eviction without a gap). The earlier apparent "no-op" was purely the unchunked
  128 MiB cap + a 10 s eviction gap, not a broken mechanism. Concurrent end-to-end A/B (cold ARC, warm
  prefix): fadvise **20.3–20.6 s**, read **17.5–19.0 s**, none **22.3 s** — the async warmer yields, so it
  can't race ahead of wine's demand reads, hence the ~1.5 s it trails `read`. **Rejected alternatives:** a
  login-time `read()` prewarm (finishes first → would hit the 4.8 s warm floor) — bad UX + evicts unrelated
  hot data for a maybe-never-launched package; kernel `overlayfs` in a userns — identical cold speed
  (18.8 vs 19.0 s), i.e. **not a startup lever** (both overlay backends were later dropped for the symlink
  farm, §9 — this result survives only as evidence that overlay choice wasn't a startup factor);
  `io_uring`/POSIX-AIO, `mmap`+`MADV_WILLNEED`,
  `ionice`/cgroup-io, L2ARC — none give a usable async-yielding warmer on ZFS (§9). A possible future lever
  if cold ever matters more: raise `zfs_vdev_async_read_max_active` (host 4) so the yielding prefetch warms
  faster in wine's idle gaps — untested, risks device contention. Steady-state (warm ARC) is **4.8 s**
  regardless; only the first launch after boot (or ARC eviction) is cold. Still pending: box64 comparison,
  first-*frame* vs first-*window*.

- **No FEX code cache on FEX-2605/Hangover-11.9** — AOTIR was removed; the new on-disk code cache is
  upstream WIP ([FEX #5125](https://github.com/FEX-Emu/FEX/issues/5125), [#5116](https://github.com/FEX-Emu/FEX/issues/5116)),
  not default-enabled, ARM64EC layout still a proposal. No JIT cache to prime/reuse; a kept wineserver
  does not retain it (JIT dies with the process). **Largest lever, currently closed** — revisit on an M4
  FEX bump.
- **esync/fsync are dead knobs** (zero occurrences in 11.0/staging 11.12, §9) — wine 11 uses **ntsync**
  automatically (kernel ≥ 6.14; `/dev/ntsync` present here). Nothing to wire.
- **Mesa on-disk shader cache is already active** (`~/.cache/mesa_shader_cache`); both routes render
  through GL, so shader compiles amortize across launches — first-frame stutter is a cold-cache first-run
  cost only. The env seal must **never** scrub/ephemeralize it.
- `WINEDEBUG` is unset in the PoC → the game run inherits default (formats+writes every `err:`/`fixme:`).
- **Finalized (→ PLAN2):** `WINEDEBUG=-all` runtime default via `PROPNIX_WINEDEBUG`; build-time
  system-lower provisioning (removes `wineboot` from first-launch, §7.2, cache-substitutable via cachix);
  keep `mscoree=b;mshtml=;winemenubuilder.exe=d`; Mesa-cache-preservation as a seal constraint; extend
  `PROPNIX_BENCH` with phase markers (`t_entry`→`t_exec` provisioning cost, `first_window_ms`,
  `first_frame_ms` from MangoHud) + a cold/warm protocol.
- **Speculative/roadmap:** `wineserver -p` keepalive (helps only same-session relaunch, not first launch,
  not the JIT); DXVK `DXVK_STATE_CACHE_PATH` in the per-app prefix/state root (M3/BG3 only). Cold/warm TTFW now
  measured (bullet above); box64 comparison + first-*frame* still need a run.

## 20. propnix on a non-NixOS Linux host (Nix installed) — per-dependency portability (2026-08-08)

Only ONE dependency is a genuine porting item; the rest are nix-daemon or kernel/CPU facts (distro-
independent). Mechanisms measured on this NixOS/Asahi host; the *foreign-distro* claims are
mechanism-established + need a real foreign-host test.

| Item | Verdict |
|---|---|
| GPU OpenGL/Vulkan | **works-with-mitigation** (the real work item) |
| trusted-user + `--extra-sandbox-paths /propnix` | out-of-the-box (nix-daemon feature) |
| `/dev/kvm` for FEX | out-of-the-box (runtime JIT is pure userspace; KVM is Tier-3 self-test only) |
| Wayland/Xwayland | out-of-the-box (host display stack) |
| Asahi 16K + hardware-TSO | orthogonal to NixOS (kernel/CPU fact; generic aarch64 falls back — slower, not broken) |

**GPU (the one real item — measured mechanism).** nixpkgs GL/Vulkan userspace resolves the driver through
`/run/opengl-driver`, which exists **only** because NixOS's `hardware.graphics` creates it (measured:
libglvnd/vulkan-loader bake that path; mesa bakes none — its DRI/ICD live in its own store `$out`). **As
written, both PoCs get hardware GL only via `/run/opengl-driver` → silently NixOS-only.** Off-NixOS it's
absent → software fallback or a host-mesa/ABI mismatch (nixGL's only trick — injecting the path — is a
no-op for a foreign loader). The fix pins nixpkgs `mesa` into the sealed wrapper closure (§7) and points the
loader vars straight at it — talking to host kernel DRM (stable uAPI, needs only `/dev/dri`), hermetic on
NixOS **and** foreign distros, covering the whole mesa/open matrix (Apple/Asahi + AMD + Intel) and fixing
the implicit `/run/opengl-driver` reliance regardless; proprietary NVIDIA must version-match its kernel
module (nixGLNvidia / host inject), off the primary matrix. Finalized decision + the concrete env-var
values: PLAN2 §8. (`NIXOS_OZONE_WL` is a Chromium hint, irrelevant here.)

**The four non-issues:** trusted-user/`extra-sandbox-paths` are nix-daemon config (`/etc/nix/nix.conf` +
`systemctl restart nix-daemon` off-NixOS — trust must live in the daemon config, §7); FEX runtime needs no
KVM (pure userspace JIT; KVM is FEX's own test harness, PLAN2 §11 Tier-3); Wayland/Xwayland is the host's
(same prereq on NixOS); Asahi-16K/TSO is a kernel/CPU fact (generic aarch64 = correct via always-on
`DYNAREC_STRONGMEM` / FEX software-TSO, just slower; routes are page-agnostic, §1/§14).

## 21. Ownership vs credential vs delisting — what the GOG fetchers report (measured 2026-08-08)

Against `gogdl` 1.2.2 + `lgogdownloader` 3.18 (source + one offline reproduction). **Neither fetcher
distinguishes "not owned" from "bad credential," and gogdl's not-owned path is a ~3-minute log storm
ending in an opaque `RecursionError` — not a hash mismatch, not a legible message.** The PLAN2 §3.3
status+byte-count pre-check catches only the Route-A 302-to-login, not not-owned.

- **gogdl:** ownership is the last stage, `secure_link` (authenticated + entitlement); the builds list,
  repository meta are public. Under the fetcher's `--skip-dlcs`, `does_user_own` is never called and the
  base game's id goes to the secure-link set unconditionally; a non-200 `secure_link` **recurses** with
  `sleep(0.2)` logging `"invalid secure link response"` → ~200 s of noise → `RecursionError` traceback,
  nonzero exit. A **bad/expired credential** funnels to the *same* storm (no auth header → same non-200).
  A **delisted/rotated buildId** is silent: `--build` matching nothing falls back to latest → wrong build
  → hash mismatch. `gogdl info` is NOT an ownership probe (reads only public meta).
- **lgogdownloader:** resolves `--download-file gamename/fileid` only against the owned-games list; not
  owned → matches nothing → no `payload.bin` → the PoC's size check errors or misblames the token.
- **Finalized (→ PLAN2 §3.3):** extend the pre-check with an **authenticated owned-products pre-flight**
  run by propnix *before* invoking either tool: (1) refresh token (`auth.gog.com/token`) — non-200 ⇒
  bad-credential → `propnix login`; (2) `GET embed.gog.com/user/data/games` → `{"owned":[…]}` — 401 ⇒
  bad-credential, `productId ∉ owned` ⇒ **not-owned** (name title + buy URL + drop-dir + hash); (3) public
  builds list — pinned `buildId` absent ⇒ **delisted/rotated** → `updateScript`. This gives the clean
  three-way split (credential / ownership / pin) neither tool provides, with legible title-specific
  messages fitting the discovery ladder. Placement (Rust helper vs shared FOD prelude) is open.

## 22. Graphics backends on wine+FEX — wined3d vs DXVK, and native ARM64EC DXVK (measured 2026-08-09)

Host: 16K Asahi / Apple M2, Mesa **Honeykrisp** Vulkan 1.4 (conformant), Windows Hollow Knight under the
hybrid wine + FEX (§15). D3D→GPU backend set by `HKCU\Software\Wine\Direct3D` `renderer` (wined3d) or by
installing DXVK DLLs as native overrides. FPS is wined3d's own present counter (`WINEDEBUG=+fps`,
`… @ approx N fps`); RSS/CPU from `PROPNIX_BENCH`'s `/proc` sampler.

**Bare-host Vulkan under the hybrid wine — WORKS (closes the earlier M3 open question).** A tiny Vulkan
enumerator compiled with llvm-mingw for **native aarch64** *and* **emulated x86_64** both returned
`vkCreateInstance → VK_SUCCESS` and enumerated **Apple M2 (Honeykrisp), Vulkan 1.4.354** under wine —
winevulkan→host libvulkan works from native and FEX-emulated code alike.

**wined3d Vulkan renderer stalls to ~12 fps — a present-path defect, not tunable.** Measured on HK:

| backend | median fps | note |
|---|---|---|
| wined3d → **GL** | **60** (vsync) | ~1.5 CPU-cores, ~1.03 GB RSS |
| wined3d → **Vulkan** | **~12** | ~1.2 CPU-cores (i.e. mostly *waiting*) |
| native EC **DXVK** → Vulkan | **60** (cap 60) / 40-45 uncapped | **~1.04 CPU-cores**, ~0.99 GB RSS — lower CPU than the box64 Linux build; frame-pacing note below |

Ruled out as causes (each measured): **present mode** (`MESA_VK_WSI_PRESENT_MODE=immediate` briefly spiked
to 151 fps but steady-state stayed ~12), **windowing backend** (winewayland vs Xwayland both ~12), **GPU
raster / resolution** (wined3d-GL renders the identical 2560×1664 at 60). Profile (perf + `/proc/*/wchan`):
CPU dominated by `NtDelayExecution`/`NtYieldExecution`→`sched_yield`/`getrusage` (the engine **spin-waits**)
while a thread parks in `drm_syncobj_array_wait_timeout` (GPU-fence wait) — i.e. wined3d's Vulkan renderer
acquires+presents **synchronously on the render thread with no presenter thread**, fully serializing each
frame; the game spins ~83 ms/present. (GPU-busy% not obtainable — the asahi DRM driver exposes no
`drm-engine` in `fdinfo`.) DXVK's unconditional async presenter (since 1.4.5) bypasses this, which is why
DXVK — native or emulated — cures it. The 40-45 fps uncapped under DXVK is frame-pacing beat against the
60 Hz vblank (unaligned frames miss vsyncs); an in-game 60 cap **or** `PROPNIX_FPS=60` (→ `DXVK_FRAME_RATE`)
gives a clean 60. So DXVK ≈ GL for HK; the value of DXVK is the working Vulkan path for D3D11-heavy titles.

**Native ARM64EC DXVK is buildable and runs — finalized as `dxvk-arm64ec.nix`.**
- **No DXVK source patch for EC:** upstream merged ARM64EC support (PR #3900) in v2.4; present in the pinned
  2.7.1 (nixpkgs `dxvk_2.src`). Verified all five DLLs build to `IMAGE_FILE_MACHINE_ARM64EC (0xA641)` with
  populated CHPEMetadata (`llvm-readobj`; a naive COFF-machine read shows `0x8664` — EC images present as
  AMD64 to the machine check, distinguished by CHPE, the same hybrid mechanism as wine's ntdll, §15).
- **The toolchain blocker and its fix.** Linking any EC C/C++ DLL failed `undefined symbol:
  #__chkstk_arm64ec`; x86_64 similarly failed `___chkstk_ms`. Root cause: llvm-mingw ships
  `libclang_rt.builtins-{aarch64,x86_64}.a` as ARM64X **hybrid** archives whose object members appear under
  **duplicate names**, so `llvm-ar`/`llvm-ranlib`'s symbol index drops the `#`-mangled EC symbols (and
  `___chkstk_ms`). Fix (`reindex-ar.py`, baked into `llvm-mingw.nix` postFixup): extract members under
  unique names and re-archive with `llvm-ar rcs` → the index then includes them (verified 0→395 EC symbols;
  `#__chkstk_arm64ec` present). `--whole-archive` is NOT a fix (fails `unknown file type:
  outline_atomic_*.S.obj`). mstorsjo llvm-mingw 20260616 (LLVM 22) suffices — no need for bylaws' fork.
- **meson cross-file:** `cpu_family='aarch64'` (meson has no `arm64ec`; this also keeps DXVK's 32-bit x86
  stdcall branch off), `system='windows'`, binaries = the `arm64ec-w64-mingw32-*` drivers + `llvm-ar`. One
  unrelated **LLVM 22 libc++** workaround: an empty piecewise key-tuple in `dxvk_pipemanager.cpp` trips
  `__try_key_extraction.h` → pass the key explicitly (`std::tuple()`→`std::tuple(key)`); drop if libc++ ≤ 21.
- **Applied perf patch (`util_bit.h`):** arm64ec clang defines neither `__aarch64__` nor `_M_ARM64EC`, so
  DXVK detects *neither* x86 nor ARM64 and its spinlocks (`sync_spinlock.h`) fall to a **hintless
  busy-loop** instead of the ARM64 `yield`. Add `|| defined(__arm64ec__)` to the ARM64 `#elif` → spin loops
  emit `yield` (verified: 30 `yield` insns in `d3d11.dll`) and the ARM64 bit-intrinsics are used. Baked
  into `dxvk-arm64ec.nix` (ARM64EC *is* ARM64 codegen, so this is correct, not a hack).
- **Runtime:** the native EC DXVK loads under the bare no-muvm wine (`Found device: Apple M2 (G14G B0)
  (Honeykrisp)`) and renders HK at 60. Hangover ships a byte-shape-identical 0xA641 DXVK, so this is a
  trodden path. **Native vs emulated:** for present-bound HK, native buys ~nothing over emulated x86_64
  DXVK (both fix the present stall); native matters for CPU-bound, high-draw-call D3D11 (BG3) where per-draw
  translation × the FEX tax would dominate. Native is still the right end-state (removes emulation from the
  whole graphics chain) and, with the toolchain fix above, cheap enough to default.

### 22.1 Hangover wine, FEX-2607, and vkd3d-proton — building the emulator stack from source (2026-08-09)

Bumping the emulator stack to match Hangover, all from source on our `llvm-mingw` toolchain:

- **wine — build Hangover's fork directly, do NOT cherry-pick its patches onto nixpkgs wine.** Hangover is
  a superproject with three submodules: `wine` = `AndreRH/wine`@`arm64ec`, `fex` = `AndreRH/FEX`@`arm64ec`,
  `box64` = `AndreRH/box64`@`wow64`. Its wine is a **coherent tree = upstream wine 11.15 + ~10 ARM64EC/WoW64
  commits** (WoW64 BT-module thread-suspension, HODLL emulator-DLL defaults + env overrides, high-VA host
  allocations outside the 32-bit guest AS, mono autoinstall), built plain (`configure --with-mingw=clang
  --enable-archs=arm64ec,aarch64,i386`), **not staging**. First attempt replayed just those 10 commits onto
  nixpkgs `wineWow64Packages.staging` **11.12**; it applied clean (`git apply --check`) but **failed to
  compile**: `dlls/wow64/process.c` calls `RtlWow64SuspendThread`, whose declaration (`include/winternl.h`)
  and export (`dlls/ntdll/ntdll.spec`) are part of the **upstream 11.15 baseline** the commits assume (added
  upstream in the 11.15 cycle), absent from 11.12. Lesson: *applies-clean ≠ compiles*; a fork's out-of-tree
  commits carry an implicit dependency on their base version. Fix = align the base: `wine-hangover.nix` now
  fetches `AndreRH/wine`@`arm64ec` (pinned commit; `configure` is checked in, so no autoreconf) and builds
  it via `wineWow64Packages.unstable`'s machinery + `arm64ec`/`dontStrip`/`gstreamerSupport`, keeping only
  nixpkgs' `cert-path.patch`. No `wine-patches/`.
- **FEX-2607 from source** (`fex-dlls.nix`): `FEX-Emu/FEX`@`FEX-2607` (upstream — the arm64ec Windows build
  is upstreamed; AndreRH/FEX is only Hangover's pin) built twice with FEX's in-tree
  `Data/CMake/toolchain_mingw.cmake` → `libarm64ecfex.dll` (arm64ec triple, 0xA641) + `libwow64fex.dll`
  (aarch64 triple, **0xAA64** — native ARM64, the "i386" names the *guest*, like Windows' `xtajit.dll`),
  plus `wowbox64.dll` from `AndreRH/box64`@`wow64`. Replaces the prebuilt-Hangover-tarball FOD (no fallback).
  Key flags: `-DTUNE_CPU=none` (no native `-mcpu` probe / SEH-directive fix), `OVERRIDE_VERSION/HASH` (no
  `find_package(Git)`), jemalloc gated off for MINGW so the 16K walls don't apply.
- **vkd3d-proton-arm64ec** (`vkd3d-proton-arm64ec.nix`): stock vkd3d-proton **2.14.1** (no arm64ec source
  patch — upstream handles it; x86 SSE paths self-exclude when `-msse2` is rejected for the EC target) →
  `d3d12.dll` + `d3d12core.dll` (0xA641). Ships no `dxgi` — reuses DXVK's. One extra build tool vs DXVK:
  `widl` (from `wine64Packages.minimal`).

**VERIFIED end-to-end on 16K (2026-08-09):** HK on `wine-hangover` (fork) + FEX-2607-from-source + native-EC
DXVK 2.7.1 + vkd3d-proton wired — **boots and renders, no stack-overflow** (the wine+FEX-combo-on-16K
caution cleared; the fork's "wrong page size" warning is benign). ntdll is ARM64X-hybrid
(`CHPEMetadataPointer != 0`) and carries `RtlWow64SuspendThread` (the fork's WoW64 glue that the 11.12
cherry-pick couldn't even compile). DXVK inits on Apple M2 (Honeykrisp) → D3D11 FL 11_1; `wine-prefix-lower`
rebuilt reproducibly with the FEX-2607 DLLs. CPU at the 60-cap menu ≈ 0.5 cores / ~760 MB RSS (down from
~1.0 core / ~1 GB pre-bump — FEX-2607 memory work + the DXVK spin-`yield` patch).
