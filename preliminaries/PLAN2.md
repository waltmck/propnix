# propnix — design plan

Reproducible Nix packaging of proprietary, non-redistributable games and apps (initially from GOG and
the Microsoft Store) for Linux, on both x86_64 and aarch64 — including Apple-Silicon / Asahi hosts with 16K or 64K kernel
pages — **without muvm**. It folds in the exploratory results in `RESEARCH.md` (§§1–22, its companion
evidence base) and the design decisions taken during development.
`RESEARCH §n` and memory names are cited where a claim rests on a measured finding.

---

## 1. Goals and non-goals

**Goal.** Given a purchased title, produce a Nix derivation that fetches the payload reproducibly and
runs it on the host with correct emulation/translation, as a normal, sealed, launchable application —
CLI-first, with a desktop entry — and with saves that persist and (where sensible) carry across builds.

**What's in scope.** Any lawfully-purchased title that falls outside nixpkgs — proprietary /
non-redistributable, behind an **authenticated fetcher** (GOG, the Microsoft Store). This is orthogonal to
arch: propnix's value is the reproducible authenticated fetch plus the sealed, launchable wrapper (saves,
`.desktop`, single-instance), of which CPU emulation is only one part. All four guest kinds are in scope —
(a) x86_64 Linux ELFs; (b) x86_64 Windows PEs; (c) native aarch64 Windows PEs; (d) native aarch64 Linux
ELFs — the last two needing no CPU emulation but still the fetch + wrapper. ((d) is moot on GOG today, which
has no aarch64-Linux builds, but such builds may appear elsewhere, e.g. Steam.) A freely-redistributable
native app belongs in nixpkgs, not here.

**Hosts in scope (D-ARCH).** `x86_64-linux` and `aarch64-linux`, at **all kernel page sizes** (4K, 16K,
64K); Wayland + Xwayland assumed present. A package is written against a *guest payload kind*, and its
builder auto-selects native vs emulated for that one payload on each host (an ELF: native on its own arch,
box64 on the other; a Windows PE: native wine on its own arch, wine+FEX on the other). That native-vs-emulated
choice is deterministic and internal — **not** a claim that a title's native build is the one to ship. When a
title offers several builds (e.g. Linux + Windows on GOG), each is its own spec; which one
`propnix.packages.<title>` resolves to on a given host is the **empirically-benchmarked winner** (§2.3),
which pin-ability or raw performance can make the emulated build rather than the native one. The per-backend
packages stay individually addressable; a user-facing override of the default is future work.

**Non-goals.** DRM circumvention beyond running lawfully-purchased content; redistribution of payloads
(all payloads are `allowSubstitutes = false`); muvm (broken rendering here — muvm#240 — and buggy in
general; § Rejected); a general-purpose emulator NixOS module or binfmt registration (§ Rejected).

---

## 2. Emulation routes — the core result

**Emulation routes selected by (host arch, guest kind).** A payload on its own arch needs no CPU emulation
(it still runs inside the propnix wrapper); a cross-arch/OS payload uses one translator. muvm is dropped for
now (broken and non-testable here — § Rejected).

| Guest | Host x86_64 | Host aarch64 |
|---|---|---|
| x86_64 Linux ELF | native | **box64** (Route A) |
| x86_64 Windows PE | **wine** (native x86_64) | **wine + FEX/ARM64EC** (Route B) |
| aarch64 Windows PE | (n/a) | **wine** (native aarch64) |
| aarch64 Linux ELF | (n/a) | native (no emulation) |

**Route A — box64 (x86_64 Linux on aarch64).** box64 runs an x86_64 *Linux* ELF by bridging to native
aarch64 libraries and translating the rest (RESEARCH §2/§4; `poc/hollow-knight-x86_64.nix`). It is how a
Linux ELF runs on aarch64 — but for a title that *also* ships a Windows build, whether its Linux build
(box64) or its Windows build (wine+FEX) is the better default is decided empirically (§2.3): ARM64EC's
thunking to native ARM libraries can outperform box64's in-process translation.

**Route B — wine + FEX (x86_64 Windows on aarch64).** Native-ARM64 wine owns the loader, memory, Windows
runtime, Mono, and graphics; FEX (the ARM64EC CPU-emulator DLL) only JITs the x86_64 code, so the large-page
wall never arises (RESEARCH §12; `wine-fex/hollow-knight-win.nix`; RESEARCH §15, memory
`wine-fex-x86_64-arm64ec`). The path for **Windows-only titles** (e.g. Baldur's Gate 3).

**Native wine (no CPU emulation).** An x86_64 Windows PE on an x86_64 host, and an aarch64 Windows PE on
an aarch64 host, run under plain wine — the same wrappers, with the FEX/box64 layer simply absent. The
aarch64-Windows case (`makeAppNative`) is subject to the §2.2 PMU wall.

`fex-portable` (a from-source FEXInterpreter for x86_64 Linux on >4K host pages) is **not** a production
route — strictly dominated (box64 for x86_64-Linux, wine+FEX for the JIT-heavy Windows case) and blocked by
the 16K soft-MMU wall; kept only as **research** (`fex-portable/`, §14; § Rejected).

### 2.1 wine as an ARM64X hybrid (RESEARCH §15, §22)
Hosting an x86_64/ARM64EC process needs two things. **(a) Build flags:** stock wine builds its PE core DLLs
(`ntdll`, `kernel32`, …) **plain ARM64**, which cannot host x86_64/ARM64EC code (`STATUS_NOT_SUPPORTED`,
`0xc00000bb`); adding `arm64ec` to `--enable-archs` emits **ARM64X-hybrid** core DLLs, and **`dontStrip =
true`** keeps the sections carrying the ARM64X load-config (stripping → wine can't flip the header to the EC
view → `0xc00000bb`; RESEARCH §15). **(b) WoW64 runtime glue:** it also needs Hangover's ARM64EC/WoW64 wine
changes (WoW64 thread-suspension via the BT module, HODLL emulator-DLL selection, high-VA host allocations).
Rather than cherry-pick those onto nixpkgs' wine, `wine-hangover.nix` builds **Hangover's wine fork directly**
(`AndreRH/wine` branch `arm64ec` = upstream wine **11.15** + those commits, one coherent tree; **not
staging**), reusing nixpkgs `wineWow64Packages.unstable` only for build machinery + the two flags above.
Replaying just the commits onto nixpkgs' 11.12 failed — they assume the upstream-11.15 baseline (RESEARCH
§22). The FEX emulator DLLs (`libarm64ecfex.dll` x86_64, `libwow64fex.dll` i386, built from source §10) live
in `system32`; the fork defaults the amd64 emulator to `libarm64ecfex` (HODLL), so the
`HKLM\…\Wow64\{amd64,x86}` registration is now optional.

Two build guards are **planned** (not yet implemented): a build assertion that the `--enable-archs=` rewrite
matched and that `ntdll`/`kernel32` report `CHPEMetadataPointer != 0`, and pinning the hybrid wine
**co-versioned** with the FEX DLLs behind a stock-x86_64 `hello.exe` gate (§11, §13; RESEARCH §15).

### 2.2 Per-title walls on the Windows routes
Neither Windows route is universal, so a **`wine-import-triage.py`** go/no-go gate runs on every title
before packaging. It **rejects** the two fatal, arch-independent wine-level walls — writable+shared PE
sections (wine cannot map them on a 16K host → `0xc000007b`) and unimplemented static imports (e.g. a
statically-linked `NtCreateWaitCompletionPacket`, no wine/FEX workaround) — and, for native-ARM64 Windows
PEs only, detects the `pmccntr_el0` PMU trap and **repairs** it as a build step (per-binary patch +
Authenticode re-sign; not a rejection). Wall mechanisms and measurements: RESEARCH §11, §12, §12.1–12.3.

### 2.3 Backend selection is empirical and per-arch
Which route runs a given title is decided **empirically, and separately for aarch64 and x86_64** (a route
that wins on one arch / page size need not win on the other), weighing, in priority order:
1. **Compatibility (highest).** Every feature must work at the target page size — determinable *only* by
   testing (the §2.2 walls, box64 SIGILLs on wayland, engine quirks). A route that fails a feature is
   disqualified regardless of the other factors.
2. **Performance.** Memory, framerate, CPU — collected by a **common gameplay instrumentation** (gated by
   `PROPNIX_BENCH`, §5): `/proc/<pid>/{status,stat}` for RSS + CPU is the **guaranteed floor** (works on
   every backend); MangoHud adds FPS / frametime / VRAM where it is on `PATH` — best-effort, unverified on
   the wine path (RESEARCH §19). Logged to a standard bench dir (curated into `docs/verified/`) in one format.
3. **Startup time.** Wall-clock to a playable state, recorded per backend; wine+FEX is materially slower
   than box64 (prefix assembly + FEX JIT + Windows-runtime init — RESEARCH §19).
4. **Pin-ability.** Only the Windows path is version-addressable (Galaxy `buildId`, §3.1); the GoG Linux
   offline installer is latest-only. So **all else equal, prefer wine+FEX over box64** for reproducibility —
   which can even favor the Windows build under wine on an **x86_64** host that has a working native Linux
   client.
The measured winner per (title, arch) is recorded in `docs/verified/` and is what `propnix.packages.<title>`
resolves to on that arch (§1); the per-backend packages remain individually addressable.

---

## 3. Fetching and payloads

### 3.1 Fetch policy is per platform (D15, revised)
Reproducible pinning differs by payload platform, because GOG exposes the two differently (RESEARCH §7):

- **Windows payloads (Route B) — GOG Galaxy builds, pinned like nixpkgs.** Every derivation pins
  `{ version; buildId; hash; }`: `buildId` is a stable, depot-addressable id GOG retains (Hollow Knight
  history reaches 2018), `version` is human-facing provenance, `hash` is the recursive `sha256` of the
  assembled tree. Offline installers are **rejected for Windows** — they are latest-only (GOG overwrites
  the file-id slot on update), so a content-pinned FOD becomes unbuildable from a clean store once the
  game updates.
- **Linux payloads (Route A) — the MojoSetup offline installer; there is no alternative.** The GOG
  Galaxy content system has **no Linux builds** (`Unsupported OS`; RESEARCH §7), so a native-Linux title
  can only come from the auth-gated `.sh` offline installer, pinned `{ version; fileId; size; hash; }`:
  `hash` is the **flat** `sha256` of the single installer (Linux `.sh` installers are never split at any
  size — assert the file count, RESEARCH §7), `size` is the observed byte count (a bad-credential
  pre-check, since GOG's API `size` field is wrong and a 302-to-login otherwise surfaces only as a hash
  mismatch), and `fileId` + the installer's `gameinfo` (title / version / GOG build id) are the version
  authority (RESEARCH §8). The tree is unpacked in a downstream step. **Reproducibility caveat:** the
  offline installer is latest-only, so a *clean-store* rebuild after GOG ships an update can no longer
  fetch the pinned bytes; in practice the private binary cache holds the payload (`allowSubstitutes =
  false` keeps it off public caches) — the same posture as a nixpkgs source whose upstream does not
  archive old tarballs.

An `updateScript` re-pins the whole tuple on both paths. (RESEARCH §7, §8, memory
`gog-fetch-galaxy-builds`.)

### 3.2 Fetch tooling — two fetchers
Both are credentialed FODs (§3.3):
- **`fetchGogOfflineInstaller`** (Linux / Route A) downloads the `.sh` MojoSetup installer and unpacks
  the game tree. Its download verb (the safe single-file `lgogdownloader --download-file`) is the **only
  measured-working GOG fetch** — the Linux PoC fetched this `.sh`; the Windows PoC fetched an InnoSetup
  `.exe` (`en1installer0`, unpacked via `innoextract --language en-US`, RESEARCH §15) the same way, a
  Windows offline path kept only as the PoC since Windows production uses Galaxy (§3.1).
- **`fetchGogGalaxyBuild`** (Windows / Route B) downloads `<productId>/<buildId>` with **`gogdl`** (nixpkgs
  `gogdl` 1.2.2, Heroic's depot downloader) and publishes the depot tree directly — no
  InnoSetup/`innoextract`. It authenticates from the existing `galaxy_tokens.json` alone (no new credential
  plumbing) and takes the **numeric** `productId` (`1308320804` for HK), not the slug. The download is
  deterministic and the FOD reproduces its pin from a clean fetch; the measurement, the token-refresh
  mechanics, and why it replaced the crashing `lgogdownloader` 3.18 are in RESEARCH §7.

### 3.3 Credentials, the discovery ladder, and failure modes
Payloads are credentialed FODs: the derivation names a credential *id* (`types.str`, never `types.path`
— a path would copy the secret into the store), never a secret; the credential directory is bind-mounted
into the sandbox (`extra-sandbox-paths /propnix=…`, which requires a **trusted user**), and the
credential must be **readable by the build user** (`setfacl -m g:nixbld:r …` or nixbld ownership) or the
FOD cannot read its own credential. Changing a credential never changes a store path. The threat boundary
is **single-user**; a shared / CI host instead pre-populates payloads into the store and leaves
`credentialsDir` unset. Payloads are non-redistributable (`allowSubstitutes = false`,
`preferLocalBuild = true`) and live only in the user's store / a private cache. `pkgs.cacert` must be a
real `nativeBuildInputs` entry, not just an interpolated `SSL_CERT_FILE` (RESEARCH §13).

By contrast, propnix's **redistributable** derivations — the hybrid wine (a ~1-hour build, FOSS/LGPL),
the FEX emulator DLLs, and the `makeApp*` wrappers — are built in CI and
pushed to a **cachix** binary cache, so users substitute them (crucially the heavy wine) instead of
compiling. This is a **build** workflow, distinct from the §3.5 payload **update** workflow: it builds and
pushes the emulator/wrapper closures on every change to them. Only payloads are excluded from any public
cache. (The wine closure references the freely-distributed GStreamer/ffmpeg plugins already on
`cache.nixos.org`, so caching it raises no new redistribution question.) **Regression
test (D8, Tier-1):** the payload `.drv` contains credential *ids*, not values, and editing the credential
changes no store path.

**Discovery ladder (fetch resilience).** A fetch resolves the payload in order: (1) the store / binary
cache; (2) a **hash-keyed user drop directory** (a read-only search path where a user can place a
manually-downloaded payload); (3) the credentialed network fetch. A blocked or failed fetch yields a
**legible acquisition-instructions error** naming the title and expected hash — not a bare hash mismatch.
Because a bad credential surfaces on GOG as a 302-to-login with a wrong `size` field (RESEARCH §7), the
fetcher **pre-checks the HTTP status and observed byte count** and fails with "bad/expired credential"
rather than letting it degrade into a hash mismatch. A **delisted or rotated pin** — a Galaxy `buildId`
GOG drops, or the offline path's overwritten `fileId` (its latest-only failure) — is a first-class error
that points at the drop directory and `updateScript`.

Because **neither gogdl nor lgogdownloader distinguishes "not owned" from a bad credential** (RESEARCH §21),
propnix runs an **authenticated owned-products pre-flight** *before* invoking either tool: refresh the token
(non-200 ⇒ **bad/expired credential** → `propnix login`); `GET embed.gog.com/user/data/games` (`productId`
absent from `owned` ⇒ **not owned** → a legible message naming the title, its store/buy URL, the drop
directory, and the expected hash); then the public builds list (pinned `buildId` gone ⇒ **delisted/rotated
pin**). This gives the clean three-way split — bad-credential / not-owned / stale-pin — that the fetchers
themselves cannot.

### 3.4 Microsoft Store payloads
A `fetchMsStorePackage` FOD fetches an MSIX/appx(bundle) via the FE3 delivery protocol (RESEARCH §10; the
resolver already exists as `poc/msstore/fe3.py`, generalized past the measured WhatsApp `9NKSQGP7F2NH`). It
is **credential-free** — free apps resolve and download with an empty MSA ticket, needing no `/propnix`
bind-mount (a categorical simplification over the GoG fetchers) — but carries `cacert` **and** the vendored
`poc/msstore/msroot2011.pem` as real build inputs (the MS Root CA 2011 is in no public bundle, RESEARCH
§13). FE3 publishes each file's SHA256 as base64, which **is** the SRI hash body, so a pin is computed with
**zero bytes downloaded**; pinning is **hash-only / latest-only** (FE3 serves only the current approved
revision; DisplayCatalog's version disagrees with what FE3 serves and is unusable as a byte pin). Store apps
are Windows PEs — native aarch64 (→ `makeAppNative`) or x86_64 (→ wine+FEX / Route B), by machine type
(RESEARCH §11), so a Store payload feeds the same wrappers as a GoG one — exactly the fetch/wrap decoupling
of §4.

### 3.5 Pins and the update workflow
Pins live in a generated per-package JSON lockfile `pkgs/games/<name>/versions.json`, read with
`lib.importJSON` (chosen over inline attrs and over nvfetcher because a package carries many hashes — base +
each DLC × up to three backends — that must be rewritten by *attribute path*, not text position). It is
keyed by **backend** → **components** (`base`, `dlc:<slug>`, `dep:<slug>`, `extras:<slug>`), each credentialed
FOD carrying its `outputHash` + `outputHashMode`/`outputHashAlgo`. A fetcher pins **by version where the
backend is version-addressable** (a Galaxy `buildId`) and **by hash alone where it is not** (the GoG Linux
offline installer and the MS Store are latest-only; `version` is provenance).

**Can a pin be refreshed without materializing the whole game?** Per backend: the flat single-file payloads
(GoG Linux `.sh`, MS Store MSIX) stream through `sha256` in O(1) disk (`curl … | sha256sum`,
size-independent even at 15.9 GB) — and MS Store needs *no* download at all, since the pin is FE3's
already-published SHA256. A GoG Galaxy build is a recursive NAR hash of a reassembled depot tree with no
whole-build hash in the protocol, so it **must be materialized** (peak disk ≈ the assembled game) — the one
disk-bound backend.

`passthru.updateScript` shells to one `propnix-update` tool (nix-update ergonomics, not its regex engine).
The GitHub Actions workflow (public / Pro repo) splits a **credential-free `discover` job** (polls the public
GoG/FE3 metadata APIs) from a **credentialed `repin` job** in a protected Environment; GoG credentials are
one `base64(tar(cred-dir))` secret, the workflow triggers only on `schedule` / `workflow_dispatch` (fork PRs
never receive the secret), pins every action to a commit SHA, and never uploads a payload artifact. Hosted
runners (~14 GB free, ~45 GB on arm64) cover flat and small-recursive titles; BG3-class recursive Galaxy
trees exceed every hosted runner and route to the user's self-hosted trusted machine. **Full design +
schema + workflow YAML: `UPDATE-AUTOMATION.md`.**

---

## 4. Packages are declarative specs over shared utilities (D-LIB)

**Fetching is separate from wrapping, and neither is hand-rolled per package.** A **fetcher** turns a
pinned tuple into a payload artifact (an unpacked game tree); a **wrapper** turns a payload artifact plus a
small spec into the sealed, launchable app. They compose — the wrapper takes the fetcher's output as
`payload` and never knows *which* fetcher produced it — so a new store (GOG, MS Store, …) is a new fetcher
and a new backend is a new wrapper, added independently. All the ugly plumbing the PoCs inline (wine-prefix
provisioning, credential handling, FEX-emulator install + Wow64 registry, save-dir binding,
single-instance/focus, `.desktop`/icon emission, box64 library bridging + sealing) lives in the wrappers. A
package is then a small declarative spec, e.g.:

```nix
makeAppWinefex {                                     # wrapper: native wine on x86_64, wine+FEX on aarch64
  pname = "hollow-knight"; appid = "hollow-knight";  # appid = shared cross-backend id (§5)
  payload = fetchGogGalaxyBuild {                    # fetcher: Windows depot, Galaxy pin (§3.1/§3.2)
    productId = "1308320804"; buildId = "59545516053866453";
    version = "1.5.12620"; hash = "sha256-…";
  };
  exe = "Hollow Knight.exe";
  saveDir = "Team Cherry/Hollow Knight";             # persistentDataPath, bound per §6.1
  icon = "goggame-*.ico";                            # or auto-extracted from the PE
  tuning = {                                         # non-derivable, settled empirically (§7.1)
    SDL_VIDEODRIVER = "x11";                          #   Xwayland; wayland SIGILLs (RESEARCH §17)
    WINEDLLOVERRIDES = "mscoree=b;mshtml=;winemenubuilder.exe=d";
    graphics = "dxvk";                                #   dxvk|wined3d → PROPNIX_WINE_D3D; HK=dxvk (§6.2)
  };
}
makeAppBox64 {                                       # wrapper: native on x86_64, box64 on aarch64
  pname = "hollow-knight-linux"; appid = "hollow-knight";  # same appid as above (§5), ≠ pname
  payload = fetchGogOfflineInstaller {               # fetcher: Linux .sh offline installer (§3.1/§3.2)
    fileId = "en3installer0";                         #   Linux .sh (en3, not Windows en1)
    version = "1.5.12620"; size = 1214513063; hash = "sha256-…";
  };
  exe = "Hollow Knight"; nativeLibs = p: […]; guestLibs = p: […];
  tuning = {                                         # RESEARCH §17 x11 / §4 PREFER_WRAPPED / §6 STRONGMEM
    SDL_VIDEODRIVER = "x11"; extraArgs = [ "-force-opengl" ];  # -force-opengl required for this title (§7.1)
    BOX64_PREFER_WRAPPED = "1";                       #   BOX64_DYNAREC_STRONGMEM is never disabled (§7)
  };
}
```

The `poc/` and `wine-fex/` wrappers are **prototypes of the behavior** these utilities must provide, not the
shape of production packages. **Fetchers:** `fetchGogGalaxyBuild`, `fetchGogOfflineInstaller` (§3.2),
`fetchMsStorePackage` (§3.4) — each produces a payload artifact from its own pin tuple. **Wrappers:**
`makeAppBox64` (Linux ELF → native on x86_64, box64 on aarch64), `makeAppWinefex` (x86_64 Windows PE →
native wine on x86_64, wine + FEX/ARM64EC on aarch64), and `makeAppNative` (**aarch64-Windows PE** → native
wine on an aarch64 host; subject to the §2.2 PMU wall). The box64/winefex wrappers auto-select
native-vs-emulated across host arches for **their** payload kind (D-ARCH); `makeAppNative` is
aarch64-host-only. A title that ships several builds is several specs (one fetcher+wrapper pair each);
`propnix.packages.<title>` resolves to the benchmarked winner for the host (§1, §2.3). Every assembled tree
is composed from **real files, never a symlink farm** — some engines (PhysFS) crash with no error on
symlinked data — and composition asserts `find <tree> -type l` is empty (RESEARCH §16). **DLC** is composed
as a directory union of the base payload and each DLC payload into that one real-file tree; `extras`-only
entitlements (soundtracks, art) are bonus material, not installers, and are packaged separately if at all
(RESEARCH §8).

---

## 5. The application interface (D14)

Every app, on any route:
1. **CLI-launchable** and scriptable — `nix run .#<app>` / `./result/bin/<app>`.
2. **Configured only via `PROPNIX_*` environment variables** (e.g. `PROPNIX_PAGESIZE`,
   `PROPNIX_HOSTCAPS_OVERRIDE`, `PROPNIX_WINEDEBUG`, `PROPNIX_SDL_VIDEODRIVER`, `PROPNIX_SAVE_DIR`,
   `PROPNIX_BENCH`, `PROPNIX_APPID`, `PROPNIX_DPI`, `PROPNIX_WINE_GRAPHICS`, `PROPNIX_WINE_D3D`,
   `PROPNIX_FPS`, `PROPNIX_NO_PREFETCH`); no ambient/config-file launch knobs, so the sealed environment
   (§7) stays authoritative and one namespace is the whole surface. Because the surface is exactly this
   env namespace, a user — or a NixOS module — can set any `PROPNIX_*` globally to steer **all** games at
   launch (e.g. a machine-wide `PROPNIX_FPS`). `PROPNIX_SDL_VIDEODRIVER` is a **per-package**
   value (RESEARCH §17): box64 Hollow Knight SIGILLs on the wayland SDL backend, so it pins `x11`
   (Xwayland) rather than inheriting a `WAYLAND_DISPLAY`-derived default; a session-derived default is used
   only for titles where both backends are verified (e.g. Stellaris). `PROPNIX_SAVE_DIR` overrides the save
   root to `$PROPNIX_SAVE_DIR/<appid>` (namespaced per app, so several titles share one dir; §6.1), resolved
   identically on every backend. `PROPNIX_BENCH=1` records performance samples — RSS/CPU from `/proc`, and
   FPS/frametime/GPU via MangoHud when it is on `PATH` — to `${PROPNIX_BENCH_DIR:-/tmp/propnix-bench}/<appid>/`
   in a backend-comparable format (§2.3), and on the DXVK backend also shows an **on-screen HUD** (DXVK's
   built-in overlay, upper-left: fps, frametime, GPU load, GPU name, DXVK version, D3D level) — no MangoHud
   needed.  **`PROPNIX_APPID` is the title's cross-backend identity** — shared
   by its box64 and winefex packagings, distinct from `pname` — and is the `<appid>` that keys saves,
   state, bench, and the single-instance lock (§5.1 / §6.1 / §7.2). **`PROPNIX_DPI`** sets the wine DPI
   (`HKCU\Control Panel\Desktop\LogPixels`; 96 = 100%), applied on-change with no re-provision (§7.1),
   defaulting to the session's `Xft.dpi` else 96. It is needed because wine never auto-detects DPI on the
   practical winex11/Xwayland driver (RESEARCH §12) — essential for windowed HiDPI utility apps (Zoom/Slack),
   largely moot for fullscreen games. **`PROPNIX_WINE_GRAPHICS`** selects the wine display driver **per
   title** (`wayland` | `x11`; sets `HKCU\Software\Wine\Drivers\Graphics`, stamped like `PROPNIX_DPI`) — the
   driver tradeoff and Hollow Knight's choice are in §6.2. **`PROPNIX_WINE_D3D`** selects the D3D→GPU
   translation on the wine routes (`wined3d` | `dxvk`); `dxvk` installs the native-ARM64EC DXVK DLLs as
   system32 overrides for a fast Vulkan path (§6.2). **`PROPNIX_FPS`** is a backend-agnostic
   target-framerate cap: on the wine routes it maps to `DXVK_FRAME_RATE` (DXVK backend), and each other
   backend maps it to its own limiter where one exists (wined3d has none; box64/native titles self-limit).
   It is the archetypal global knob — set once (user or NixOS module) to cap every game.
3. **Also ships a `.desktop` file with an icon** (`makeDesktopItem`): `Exec` = the CLI wrapper,
   `Categories=Game`, `Icon` extracted from the payload, installed under `$out/share/{applications,icons}`
   so `nix profile install` surfaces it in the menu. Same `Exec` means menu and shell never diverge. The
   file is named `org.propnix.<appid>.desktop` and carries **`StartupWMClass`** = the backend's actual
   window class, so the compositor/taskbar shows this icon for the game window. wine and box64 **derive
   the window class from the executable and expose no override** (winewayland calls `xdg_toplevel_set_app_id`,
   winex11 sets `res_class`, both from the exe basename — winefex HK is `hollow knight.exe`), so
   `StartupWMClass` is the freedesktop-standard bridge rather than trying to rename the window. The class is
   **per-backend** (winefex vs box64 differ — the same cross-backend wrinkle as §5.1), so each packaging's
   `.desktop` declares its own.

### 5.1 Single-instance and focus (desideratum)
A duplicate launch **focuses the running window** rather than starting a second copy, and the lock is
keyed on an **app identity shared across all backends** — so `winefex` Hollow Knight and `box64` Hollow
Knight count as one instance. Implementation: a shared lock under `$XDG_RUNTIME_DIR/propnix/<appid>/`
(keyed on appid, not per-`pname`), a window-activate step (EWMH `_NET_ACTIVE_WINDOW` / `wmctrl -a`), and the guard/focus logic
in the **outer launcher** — not an flock fd inherited into box64/wine, since `wineserver` lingers and
would hold a naive inherited lock. (Not yet implemented; recorded desideratum.)

### 5.2 Startup splash (desideratum)
Cold startup is long (~20 s on a first-launch-per-boot; §19), so the launcher shows a **minimal floating
splash** — the game's name + its `.desktop` icon (§5 item 3 / D14) — while the game starts, dismissing it
when the first game window maps (timeout fallback). It is built with **relm4** (GTK4) and rendered
**in-process by the Rust launcher**, which is why the production per-app launcher is a Rust program, not the
PoC shell wrapper. That launcher owns the splash and the §5.1 single-instance/focus guard, and orchestrates
backend startup/teardown (the prefetch / prefix assembly / exec + trap that `winefex` prototypes, §7.2).
**Closing the splash cancels startup** — SIGTERM the backend child, then the standard `wineserver -k`
teardown (§7.2) — rather than orphaning a half-started prefix. **If feasible**, it parses wine/FEX stderr
for a coarse progress bar (best-effort). (Not yet implemented; recorded desideratum.)

---

## 6. Wine model (Route B)

**The hybrid wine** (§2.1) is an override of `wineWow64Packages.staging` (§10) with `+arm64ec`,
`dontStrip`, `+gstreamerSupport` — a heavy build, produced once and shared by all Windows packages.
(`gstreamerSupport = true` supplies `winegstreamer.dll` + the GStreamer/ffmpeg codecs so Media Foundation
can decode media — cinematic audio works; video is a wine MF limitation, §6.2.) **The
`winefex` runner** assembles the prefix as a **symlink farm** and runs wine directly — no overlay, mount, or
namespace (§7.2 details the layout, lifecycle, and retention). The read-only system tree it symlinks in
(`wineboot -u` + the FEX DLLs + Wow64 keys, built at **BUILD TIME** into the nix store as
`wine-prefix-lower.nix`, so there is no first-launch provisioning and it is cachix-substitutable) is shared
by every Windows package. Each launch it:
- **prefetches the system tree's DLL closure** into cache in the background first (`propnix-prefetch`, a
  tokio Rust helper issuing chunked `posix_fadvise(WILLNEED)`) so the cold closure warms while startup
  proceeds (RESEARCH §19);
- **assembles the symlink farm** (§7.2) — read-only paths symlinked to the store and recreated each launch,
  writable paths (`user.reg`/HKCU, the user profile) real and persistent;
- sets `WINEDLLOVERRIDES=mscoree=b;mshtml=;winemenubuilder.exe=d` (builtin mscoree suppresses the wine-mono
  prompt without breaking .NET titles; disables gecko + the menu-builder) and `WINEDEBUG=-all`, and pins
  the wine username so the store tree's profile is found as-is;
- applies **save binds** (§6.1); tears down on exit/signal with a prefix-scoped `wineserver -k` — there is
  no mount or namespace to unwind, so a run can never strand anything, and it never touches another title's
  wine (wine runs backgrounded + `wait`ed so a signal fires the trap promptly).

A wine/FEX bump changes the system tree's store path; the next launch relinks to it while the persistent
per-app dir carries over untouched (§7.2). App binaries never live in the prefix (they run from the store
tree). Auto-update is disabled for every packaged app (propnix pins the version).

### 6.1 Save/data policy — link saves, don't reconcile settings
The save location is resolved **once, identically on every backend** (box64 Linux, wine+FEX Windows,
native-ARM64 wine) and bound into each guest's in-app save path — a symlink for a Linux guest, a prefix
bind for a Windows guest — so the same on-disk directory holds saves whichever backend runs.
`PROPNIX_SAVE_DIR` overrides that root to `$PROPNIX_SAVE_DIR/<appid>` (namespaced per app, so several titles
can share one `PROPNIX_SAVE_DIR`). The launcher **creates** the host save directory (owned
by the user) before launch if it is absent, and **refuses to launch with a legible error** if it cannot;
saves are never allowed to fall back into the rebuildable per-app prefix.

For a Unity title the **source of truth** for saves is the native Linux persistentDataPath
`~/.config/unity3d/<co>/<prod>` — shared by the box64/Linux and wine/Windows builds of the same title and
persisted outside the rebuildable prefix; the Windows path (`AppData/LocalLow/<co>/<prod>`) is symlinked
to it. This works because Unity `userN.dat`/`shared.dat` are engine-serialized and platform-independent,
but propnix **verifies the round trip** (save under one backend, load under the other) before declaring a
title cross-backend — it is not assumed (RESEARCH §15 recorded only that a save *started*). **PlayerPrefs
are an explicit non-goal:** Windows Unity keeps them in the registry, Linux in a `prefs` file —
incompatible backends, not worth bridging; settings live per-backend. The bind migrates any existing
in-prefix data once, then symlinks.

**Non-Unity / Windows-only titles** (Route B's stated target class, e.g. BG3) are **not** covered by the
persistentDataPath model: there is no native Linux build to share with and the save location is
per-engine, so `saveDir` is a per-title declaration pointing at the engine's actual path, persisted under
the state root (§7.2) with no cross-backend claim.

### 6.2 Graphics
Two D3D→GPU translations are available on the wine routes, chosen per title via `PROPNIX_WINE_D3D` (§5):
- **wined3d → OpenGL** (`wined3d`, wine's builtin, native ARM64EC) — renders Hollow Knight at 60 fps.
- **DXVK → Vulkan** (`dxvk`) — **native ARM64EC DXVK** (`dxvk-arm64ec.nix`) dropped into the prefix's
  system32 as `d3d11,d3d10core,dxgi,d3d9=n` overrides; measured 60 fps on Hollow Knight (Apple M2 /
  Honeykrisp). This is the path for D3D11-heavy titles (e.g. Baldur's Gate 3, M3). Its pipeline/shader
  cache is persisted at `$XDG_CACHE_HOME/propnix/<appid>/dxvk` (`DXVK_STATE_CACHE_PATH`) — regenerable, so
  cache not state, and never the read-only store where DXVK's default next-to-exe cache would silently
  no-op — so cold-compile stutter happens once, not every launch.

wine's **Vulkan** renderer *inside wined3d* is deliberately not used: it serializes present on the render
thread and stalls to ~12 fps here — not fixable by present-mode or windowing tuning (measured) — which is
exactly what DXVK's async presenter avoids. Bare-host Vulkan-under-wine, an earlier open question, is
**resolved**: winevulkan reaches Honeykrisp from both native and emulated code. (Both findings: RESEARCH
§22.) **The wine routes default to `dxvk`** (winefex default; DXVK on HK draws even less CPU than the box64
Linux build at a locked 60); wined3d-GL (also 60) stays the per-title fallback via `PROPNIX_WINE_D3D=wined3d`
for any title DXVK can't render. The hybrid wine is built with `gstreamerSupport` so Media Foundation can
decode media (§6); cinematic video remains an open question (RESEARCH §18).

The wine **display driver** — `winewayland.drv` (native Wayland) vs `winex11.drv` (Xwayland) — is a
**per-title** choice via `PROPNIX_WINE_GRAPHICS` (§5), decided by testing. **Hollow Knight ships `wayland`**
(measured 2026-08-09: single native Wayland window, stable, renders correctly), which gets the compositor's
fractional scaling for free (no `PROPNIX_DPI`); its only rough edge is an **undersized cursor** on a
fractional-scaled output (winewayland doesn't scale the cursor surface — RESEARCH §12). winex11/Xwayland
stays the safer default for untested titles (correct cursor, and layered-window apps like Zoom break under
winewayland — RESEARCH §12), at the cost of needing `PROPNIX_DPI` for content scaling.

---

## 7. box64 model (Route A), sealing, and tuning

**Library triage (RESEARCH §4).** box64 bridges the *native* aarch64 copy of the sonames it wraps, and
the guest needs the x86_64 copies of everything box64 does not wrap. The set is the **union** of a
bridging list and a guest list, derived from box64's wrapped-soname set minus `essential_libs[]`.

**Sealing (D13).** Every wrapper scrubs the backend's whole env namespace (`BOX64_*` / `WINE*` / `FEX_*`)
then sets only what it means. By default `BOX64_NORCFILES=1`, so a user's `~/.box64rc` cannot change
behavior. `NORCFILES=1` also suppresses propnix's *own* rcfile, so the two are mutually exclusive: a
package that needs per-library dynarec tuning (an explicit, costed escalation) **drops `NORCFILES=1`** and
ships its rcfile as the first search path, accepting that a user rcfile can then also load.
`--propnix-unseal` and `--shell` are the deliberate escape hatches. The runtime `WINEDEBUG` default is
**`-all`** (`export WINEDEBUG="${PROPNIX_WINEDEBUG:--all}"`) so a chatty title isn't taxed formatting every
`err:`/`fixme:` line — provisioning and Tier-2 verification override it, since they rely on those lines
(RESEARCH §19). One seal constraint: the env scrub must **never** remove or ephemeralize the **Mesa
shader-disk cache** (`$XDG_CACHE_HOME`, `MESA_SHADER_CACHE_DIR`) — both routes render through GL and it
amortizes shader compiles across launches (RESEARCH §19).

### 7.1 Tuning data model
Tuning is **typed data with provenance**, not free-form script. Each package's `tuning.nix` is an attrset
whose entries are `{ value; reason; }` (the `reason` records *why* the knob is set, so a later reader can
retire it; the §4 spec examples elide it to inline comments for brevity), rendered by the builder into
the sealed environment — or, for the escalated per-library case, into a store-path rcfile. The mandatory, **non-derivable** knobs (a title is not packageable until they
are settled empirically, and `docs/verified/` records each verified run):
- **box64**: `SDL_VIDEODRIVER=x11`, `-force-opengl`, `BOX64_PREFER_WRAPPED=1`. **`BOX64_DYNAREC_STRONGMEM`
  is never disabled** — under box64 the CPU runs in the weak memory model and STRONGMEM is the *only*
  ordering guarantee (RESEARCH §6); disabling it is a silent data race, not a speed knob. Per-library
  rcfile knobs carry a leading-`/` path scope, and a per-mapping section honours only a fixed subset of
  the `DYNAREC_*` knobs — box64 silently ignores the rest (RESEARCH §4).
- **winefex**: SDL / wine display driver, wine variant, DPI (`LogPixels`), `AeDebug` (no crash dialog),
  and `wined3d`-vs-`DXVK`.

### 7.2 State, lifecycle, and retention (D13)
The wine prefix is a **symlink farm**, split so a system update preserves user data. Its parts are keyed
differently on purpose:
```
# system tree — read-only, provisioned at BUILD TIME into the store; keyed by its store-path hash.
# Symlinked into each prefix; never written.
/nix/store/<hash>-wine-prefix-lower/    # wine system32/syswow64 + FEX DLLs + Wow64 keys + system hives (HKLM, HKU\.Default)
# per-app prefix — read/write, persistent; keyed by <appid>. The WINEPREFIX itself.
$XDG_STATE_HOME/propnix/<appid>/prefix/ # user.reg (HKCU), drive_c/users (AppData), ProgramData, windows/temp, font cache
$XDG_STATE_HOME/propnix/<appid>/        # other persistent user data
# disposable
$XDG_CACHE_HOME/propnix/<hash>/         # JIT / DXVK caches — disposable, keyed by store hash
$XDG_RUNTIME_DIR/propnix/<appid>/       # the shared single-instance lock (§5.1)
```
`WINEPREFIX` is the **persistent per-app `prefix/` directory**, assembled each launch as a symlink farm:
its read-only content is symlinked into the store system tree, its writable content is real and persists.
There is **no overlay, no mount, and no namespace** — so the game runs as the real user with every host
supplementary group (`video`, `kvm`, `pipewire`, …) intact, and a run can never strand a mount (RESEARCH §9).

**Read-only, symlinked → the store** (recreated every launch): `drive_c/windows/*` (except `temp`),
`drive_c/Program Files*`, `system.reg` (HKLM), `userdef.reg` (HKU\.Default), `.update-timestamp`. The
system tree is a pure function of the wine + FEX + provisioning build — the **store path** of
`wine-prefix-lower.nix`, **regenerated on a wine/FEX bump** (never reused against a different binary — the
silent-corruption failure D13 guards against). Recreating the symlinks every launch means a bump is picked
up for free, and any read-only file wine tried to rewrite last run — it can't (the store is `0444`), so its
save drops a real file over the symlink — is restored to the symlink. So the system hives are authoritative
from the store every launch, with no drift and no reconcile (the D13 concern).

**Writable, real, persistent** — the Windows non-elevated write set (matches what a standard Windows user
may write; everything else is read-only, as on Windows): `user.reg` (HKCU), `drive_c/users` (the user
profile / AppData), `drive_c/ProgramData`, `drive_c/windows/temp`, `dosdevices`. `user.reg` is a **real
file**, not a symlink — wine's atomic save would clobber a symlink: wine regenerates a fresh default HKCU
on first run (~+0.1 s — built-in defaults + font list, not a `wineboot`) and writes it in place thereafter,
so HKCU (settings, font cache) persists. Saves are bound *out* of the prefix (§6.1) and so are already
independent of it — a Unity title's shared saves at the engine-native path (`~/.config/unity3d/…`), a
non-Unity title's under its `<appid>` state root.

Building the system tree at **build time** removes the ~22 s first-launch `wineboot` and is
cachix-substitutable (`wine-prefix-lower.nix` is bit-reproducible — `nix-store --check` passes); assembling
the prefix is a few dozen symlinks (sub-second). Verified end-to-end on Hollow Knight; the measurements, and
why the symlink farm superseded the earlier overlay designs (fuse-overlayfs, kernel-`overlayfs`-in-a-userns),
are in RESEARCH §9 / §19.

**Rollback** rebuilds the older system tree (from its store hash) and **keeps the app's persistent prefix**, so
saves and settings survive a version change. **Uninstall** removes the app from the profile and, on
`--purge`, its `<appid>` state root (the persistent prefix + user data) — saves guarded behind an explicit confirm.
**Payload retention:** payloads are the largest artifacts (HK 1.2 GB, Stellaris 15.9 GB, larger for BG3),
store-only and non-cheap to re-fetch, so each pinned `{ buildId | fileId }` a profile references is a GC
root; superseded payloads are collected on the next `nix-collect-garbage` once no pin references them.

---

## 8. Host capabilities and runtime detection

Prefer runtime detection to eval-time assumption, except where a decision shapes the derivation. A small
probe emits `PROPNIX_*` facts (`PROPNIX_PAGESIZE`, `PROPNIX_NPROC`, `PROPNIX_HW_TSO`, …; page size
RESEARCH §1/§14, TSO RESEARCH §6), overridable via `PROPNIX_HOSTCAPS_OVERRIDE` for testing. Page size in
particular is a runtime fact, and the production routes are page-agnostic: box64 works at the host page
size, and the Route-B Windows FEX build has **no jemalloc** (its CMake gates it out with `if (NOT MINGW)`)
and runs through wine's native-ARM64 `ntdll`. (The research `fex-portable` build handles 16K/32K/64K via
jemalloc `LG_PAGE=16`; RESEARCH §14.)

**Non-NixOS hosts (Nix installed).** propnix targets any Linux with Nix, not just NixOS. Four of its five
host dependencies are distro-independent — the sandbox/trusted-user machinery is a **nix-daemon** feature
(set `trusted-users` + `extra-sandbox-paths` in `/etc/nix/nix.conf` off-NixOS; §3.3), the FEX runtime is a
pure-userspace JIT (no `/dev/kvm` — that's Tier-3 self-test only, §11), Wayland/Xwayland is the host's, and
the Asahi-16K/TSO specifics are kernel/CPU facts (generic aarch64 runs correctly, just slower). The one
real porting item is **GPU GL/Vulkan**: nixpkgs userspace resolves the driver via `/run/opengl-driver`,
which exists only on NixOS. So the wrappers **pin nixpkgs `mesa` into their sealed env**:
`LIBGL_DRIVERS_PATH=${mesa}/lib/dri`, `__EGL_VENDOR_LIBRARY_DIRS=${mesa}/share/glvnd/egl_vendor.d`,
`__GLX_VENDOR_LIBRARY_NAME=mesa`, `VK_DRIVER_FILES=${mesa}/share/vulkan/icd.d/<gpu>_icd.aarch64.json`, plus
`${mesa}/lib` on the loader path — talking straight to host kernel DRM (stable uAPI, needs only `/dev/dri`).
This makes GL/Vulkan hermetic on NixOS **and** foreign distros and covers the whole Apple/Asahi + AMD +
Intel matrix (proprietary NVIDIA still needs nixGL). Measured mechanism: RESEARCH §20.

---

## 9. Overrides and the x86_64 package set

**Overrides.** One `callPackage`'d function per package with explicit arguments (no `...`, so a typo is an
eval error), so `.override` propagates (payload, lib lists, tuning).

**The x86_64 package set (`pkgsX86`).** box64 / Route A needs x86_64 *guest* libraries while the wrapper
runs on an aarch64 host. `pkgsX86` is a second nixpkgs instance evaluated for `x86_64-linux` whose store
paths the aarch64 wrapper depends on; this cross-eval is substitutable from the public cache and safe
(RESEARCH §3). propnix **never builds an `x86_64-linux` derivation on aarch64** — it only depends on
prebuilt x86_64 store paths.

---

## 10. Repository layout

`lib.makeScope` (not `pkgs/by-name` — propnix's value is *shared* files). Roughly: `lib/` (the fetchers, the
`makeApp*` wrappers, sealing, prefix/winefex, single-instance, desktop-item helpers), `pkgs/games/<name>/`
(the declarative spec + `versions.json` + `tuning.nix` + `docs/verified/`), `config/` (credentials,
host-caps), and the production emulator packages — the hybrid wine (`wine-hangover.nix`: **Hangover's wine
fork**, `AndreRH/wine` `arm64ec` = upstream 11.15 + the ARM64EC/WoW64 commits, built by us via
`wineWow64Packages.unstable`'s machinery + `arm64ec`/`dontStrip`; not staging, no cherry-picked patch set —
§2.1), the **FEX emulator DLLs built from source at FEX-2607** (`fex-dlls.nix`: FEX-Emu/FEX + box64's
`wowbox64` via the `llvm-mingw.nix` toolchain — no prebuilt-tarball FOD), **native ARM64EC DXVK**
(`dxvk-arm64ec.nix`: stock DXVK 2.7.1 built with `llvm-mingw.nix`, whose `postFixup` re-indexes the
compiler-rt builtins archives so EC symbols link) +
**native ARM64EC vkd3d-proton** (`vkd3d-proton-arm64ec.nix`: D3D12→Vulkan, same recipe), and box64
(`box64-latest.nix`, pinned ahead of nixpkgs to the latest upstream). RESEARCH §22. Each tracks the
**latest packaged version**, verified by a real run — Nix lets us run latest-and-greatest safely.
`fex-portable/` lives here too but as **research**, not a production package.

**Nontrivial helpers are Rust, not shell/Python** — the `propnix-hostcaps` probe, the credential helper,
the FE3 / Microsoft-Store resolver (`poc/msstore/fe3.py` is the spec), and `wine-import-triage` (§2.2).
They build with `runCommandCC` + `rustc` (no crates, no `cargoHash`/`cargoLock`; `prctl`/`sysconf` via
`unsafe extern "C"`), for a smaller closure and unit-testable code. The `poc/` Python/shell versions are
prototypes of the behavior, not the production shape.

---

## 11. Testing and verification

- **Tier-1 (eval / assertion).** Sealed env (no unsealed backend var survives); the D8 credential test
  (the payload `.drv` holds credential *ids*, not values, and editing the credential changes no store
  path — §3.3); and, for the hybrid wine, the planned `arm64ec`-matched + `CHPEMetadataPointer != 0`
  assertion (§2.1).
- **Tier-2 (non-vacuous smoke run).** A wine wrapper's exit code is **vacuously green** (it detaches and
  `wineserver` lingers), so success is **never** inferred from it. **box64:** read `/proc/<pid>/maps` and
  check the ELF machine byte of every mapped `.so` to prove the native/emulated split (RESEARCH §4).
  **wine+FEX:** that scan is vacuous (the x86_64 code is a PE JITed in-process by FEX, not an ELF `.so`),
  so Route B needs its own check — assert wine loaded the ARM64X `ntdll`/`kernel32` (`CHPEMetadataPointer
  != 0`) and that a known x86_64 module actually executed under FEX. Both routes assert the composed tree
  has no symlinks (`find -type l` empty, §4); payload determinism is a clean rebuild against the pin.
- **Tier-3 (manual, recorded in `docs/verified/`).** GPU rendering, the stock-x86_64 `hello.exe` wine
  gate, and FEX behavior — FEX's own checks need `/dev/kvm`, and a green build proves nothing (nixpkgs
  disables FEX's tests off-4K, RESEARCH §1). Each entry records the exact invocation + host caps.

---

## 12. Roadmap

- **M0 (done, PoC).** box64 Hollow Knight (Linux, hardware GL); `fex-portable` (**research**: Linux FEX on
  16K, static + dynamic x86_64); **wine+FEX Windows Hollow Knight playable**; hybrid-wine two-line fix; `winefex`
  runner with save-bind + headless provisioning. Both playable PoCs fetched via the offline installer.
  **`gogdl` verifiably downloads a version-pinned Galaxy Windows build, deterministically** (Hollow Knight,
  §3.2) — the reproducible Galaxy fetcher, drafted as `wine-fex/fetchGogGalaxyBuild-gogdl.nix`.
- **M1 — fetching.** `fetchGogOfflineInstaller` (Linux / Route A — productionize the working PoC path),
  `fetchGogGalaxyBuild` on `gogdl` (Windows / Route B — verified; finalize as the FOD), and `fetchMsStorePackage`
  (§3.4); the discovery ladder + legible-error pre-check (§3.3); the auto-bump pin format + `updateScript`
  + a GitHub Actions update workflow with credentials as a secret (§3.5); a **cachix build workflow**
  publishing the redistributable emulator/wrapper closures — the heavy hybrid wine especially (§3.3);
  `propnix login` + the sandbox-path module fragment.
- **M2 — the fetchers + `makeApp*` wrappers.** Abstract all PoC plumbing into `lib`, with fetching split
  from wrapping (§4); sealing built in from the first package; the tuning data model (§7.1); `.desktop`/icon;
  single-instance/focus; the `wine-import-triage.py` go/no-go gate (§2.2). Ends in declarative Hollow Knight
  as **two specs** — a Linux `makeAppBox64` and a Windows `makeAppWinefex` (§1) — with
  `propnix.packages.hollow-knight` resolving to the benchmarked winner per host (§2.3).
- **M3 — heavy D3D11 (Baldur's Gate 3).** The graphics prerequisites are already met: bare-host Vulkan
  under the hybrid wine is proven, and **native ARM64EC DXVK is built and validated at 60 fps on Hollow
  Knight** (`dxvk-arm64ec.nix`; RESEARCH §22). M3 is now the title-specific bring-up — does BG3 boot and
  hold a playable framerate under DXVK — plus the §2.2 import-triage gate. An open feasibility question,
  not a scheduled certainty.
- **M4 — breadth.** More titles; itch.io; the black-cinematics/wined3d fix; build the FEX arm64ec DLL
  from source (FEX-2605 via llvm-mingw, §2.1); upstream the `fex-portable` patch and the wine
  `arm64ec`+`dontStrip` finding.

---

## 13. Risks and open questions

- **Galaxy fetcher — resolved (was M1's top risk; mechanism + reproducibility in §3.2).** Remaining is
  per-title variance only — redistributables landing in the tree, multi-language pins, and
  paid/entitlement-gated titles (§3.2 / `UPDATE-AUTOMATION.md §6`).
- **Offline-installer reproducibility (Route A).** Latest-only: a clean-store rebuild after a GOG update
  cannot re-fetch the pinned bytes; mitigated by the private cache + hash-keyed drop directory (§3.1, §3.3).
- **Route B is per-title, not universal (§2.2).** Writable+shared PE sections (`0xc000007b`) and
  unimplemented static imports block specific titles; native-ARM64 PEs additionally hit the `pmccntr_el0`
  PMU trap with no sysctl fix on kernel 7.1.5. The `wine-import-triage.py` gate is mandatory pre-packaging.
- **Cinematic video + bare-host Vulkan (open).** Unity VideoPlayer video does not render under the
  current wine (RESEARCH §18); bare-host Vulkan-under-wine — hence the DXVK path for D3D11-heavy titles —
  is unproven (gate: a bare-host `vkcube.exe`).
- **Prebuilt FEX DLLs (provenance).** The emulator DLLs are unaudited third-party binaries (Hangover 11.9)
  — accepted as a **recorded trust compromise** (pinned release tag + tarball hash), with a from-source
  build (FEX-2605 via llvm-mingw) as a roadmap milestone (§2.1, §10, M4).
- **Hybrid-wine maintenance.** The `+arm64ec`/`dontStrip`/`+gstreamerSupport` override tracks
  `wineWow64Packages.staging` and is paired with out-of-nixpkgs Hangover DLLs; a wine bump can silently
  regress the ARM64X path, which the **planned** co-version pin + `CHPEMetadataPointer` assertion +
  `hello.exe` gate (§2.1, §11) are meant to catch.

---

## 14. Rejected alternatives

- **muvm — dropped for now.** Broken rendering on this host (muvm#240) and non-testable here; buggy
  generally. The whole reason the production routes target the bare host.
- **GOG offline installers for *Windows* production** — latest-only, unbuildable-from-clean after an
  update; Windows uses Galaxy `buildId` pins instead. (Linux has *no* Galaxy builds, so Route A must use
  the offline installer with a documented caveat — §3.1.)
- **A blanket rule for native-Linux titles (always box64, or always the Windows build)** — neither is
  categorical: the route is an empirical per-title, per-arch call (§2.3) weighing compatibility, performance,
  startup, and pin-ability. Pin-ability favors wine+FEX/Galaxy (even on x86_64); native performance favors
  box64 — the winner is measured, not assumed.
- **fex-portable as a production route** — strictly dominated: box64 covers x86_64-Linux guests and
  wine+FEX covers the JIT-heavy Windows case, and its Mono/JIT support is blocked by the 16K soft-MMU
  wall. Kept as **research** (`fex-portable/`, RESEARCH §14) — a from-source FEXInterpreter for >4K host
  pages, worth upstreaming (M4) — but not implemented in production.
- **Hand-rolled per-package scripts** — replaced by the fetchers + `makeApp*` wrappers (§4).
- **binfmt / emulator NixOS module** — binfmt is claimed by qemu; propnix wraps explicitly instead.
