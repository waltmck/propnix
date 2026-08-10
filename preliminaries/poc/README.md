# Proofs of concept

Deliberately unabstracted, end-to-end derivations — no options, no `lib/`, no reuse. Each answers one
question: **does the architecture in [../PLAN2.md](../PLAN2.md) actually work?** The filename suffix is
the **payload's** architecture; every PoC runs on aarch64.

| File | Axis exercised | Verdict |
|---|---|---|
| `hollow-knight-x86_64.nix` | GOG payload, credentialed FOD, x86_64 Linux under **box64**; optional DLC | **works** — playable, save written |
| `stellaris-x86_64.nix` | **multi-payload**: 12 credentialed FODs, real DLC merged into the game tree | **works** — frontend reached, all 11 DLC present |
| `slack-arm64.nix` | free MSIX, **ARM64 Windows under wine, zero emulation** | **partial** — path proven; Electron opens no window |
| `whatsapp-arm64.nix` | **Store payload fetched inside a FOD**, multi-payload, .NET 8 + WinUI 3 | **partial** — pipeline works; WinUI 3 unsupported by wine |
| `zoom-arm64.nix` | Store **Win32/winget** path, installer unpacked, native C++ under wine | **works** — joins a meeting with audio |
| `msstore/` | **Microsoft Store payload acquisition** (protocol spike, not a derivation) | **works** — 355 MB fetched anonymously, digests matched |

Per-run records with measured detail: [`../docs/verified/`](../docs/verified/). Cross-cutting findings
and mechanisms: [`../RESEARCH.md`](../RESEARCH.md). Reusable helpers discovered here:
[`../tools/`](../tools/) (`wine-import-triage.py`, `wine-trust-cert.py`, `mk-codesign-cert.py`).

A standing invariant every PoC upholds: **app binaries run from the read-only `/nix/store` path; the
only writable state is a separate wine prefix or state dir.** An app therefore cannot overwrite or
shadow its own store-provided files (PLAN2 §7.2). Auto-update is disabled where the app supports it.

---

## PoC 1 — Hollow Knight (GOG, x86_64 Linux) under box64

```sh
# Credential store, bind-mounted into the sandbox at /propnix (needs trusted-user status):
mkdir -p /var/tmp/propnix/gog
cp ~/.config/lgogdownloader/{galaxy_tokens.json,cookies.txt,config.cfg} /var/tmp/propnix/gog/
printf 'version = 1\n[gog]\ncredentialDir = "/propnix/gog"\n' > /var/tmp/propnix/credentials.toml
chmod go-rw /var/tmp/propnix/credentials.toml /var/tmp/propnix/gog/*
setfacl -m g:nixbld:r  /var/tmp/propnix/credentials.toml /var/tmp/propnix/gog/*
setfacl -m g:nixbld:rx /var/tmp/propnix/gog

nix-build hollow-knight-x86_64.nix --option extra-sandbox-paths /propnix=/var/tmp/propnix
./result/bin/hollow-knight     # first build downloads 1.21 GB
```

Playable: main menu, gameplay, save written. Renderer `Apple M2`, `OpenGL 4.6 Mesa 26.1.5`.

**Proves:** a credential reaches a build without touching the store or evaluator (the ACL grant to
`nixbld`, unprivileged); box64 needs no patchelf; every derivation is `aarch64-linux` with x86 libraries
as pure `pkgsX86` dependencies (PLAN2 §9); D13 sealing (scrub `BOX64_*` and `LD_*`); single-instance
protection replicated with `flock` outside the game.

**Constraints (per-package tuning, PLAN2 §7.1):** the dependency list is the union of a native-aarch64
bridging set and the x86_64 guest closure; `-force-opengl` and `SDL_VIDEODRIVER=x11` are required and
not derivable from anything. Details: [`../docs/verified/hollow-knight.json`](../docs/verified/hollow-knight.json).

**Wayland re-tested 2026-08-07: still fails**, and the reason is now pinned down. It reaches
`Creating OpenGL 4.6 graphics device`, then dies in the Mono runtime with SIGILL. The wayland path
also loads the payload's bundled `libdecor-0.so.0`, which x11 never touches, so box64 tries to bridge
it natively along with `libdbus-1` and `libz` and fails on all three — but supplying those natives
removed every bridge error and produced the *identical* Mono crash, so they were a symptom, not the
cause. `x11` stays, and it is Unity-specific rather than a general default (RESEARCH §17).

**Nothing left to make native.** Measured by ELF machine byte over `/proc/<pid>/maps`: 69 file-backed
shared objects mapped at the renderer, **all AArch64, zero x86-64**. The only emulated code is
`UnityPlayer.so` and the bundled Mono runtime, which have no native equivalent (RESEARCH §4).

### DLC

```sh
nix-instantiate --eval --strict -A availableDLC hollow-knight-x86_64.nix   # what exists
nix-build hollow-knight-x86_64.nix --arg dlc '[ "gods-nightmares" ]' \
  --option extra-sandbox-paths /propnix=/var/tmp/propnix
```

**GOG's "Gods & Nightmares" is a soundtrack, not game content.** The product has **no installers —
only two extras**, the Godmaster OST as MP3 (148 MB) or FLAC (281 MB); the Godmaster *gameplay* was a
free base-game update and is already in 1.5.12620. Nothing in the payload can load extra content
from disk, so selecting the DLC installs the album as data —
`share/hollow-knight/soundtrack/gods-nightmares/` — and leaves the game tree untouched.
`--argstr ostFormat mp3` picks the smaller encode.

The point of packaging it is the **mechanism**: one credentialed FOD per DLC file, a named
catalogue, and a selection API that changes *which FODs are in the graph*. `dlc` defaults to `[ ]`,
so a plain `nix-build` produces byte-for-byte the derivation this record describes and never fetches
the album. `passthru` carries `withDLC` (accepting `(d: [ d.gods-nightmares ])` or
`[ "gods-nightmares" ]`), `withAllDLC`, `withoutDLC` and `override`.

---

## PoC 2 — Slack for Windows, ARM64, under wine

```sh
nix-build slack-arm64.nix && ./result/bin/slack
```

**Proves** PLAN2 §2 row 3: an ARM64 Windows PE runs under `wineWow64Packages.stable` with **no
emulation** (no box64/FEX/muvm). Also MSIX extract-and-run (MSIX is a plain ZIP; wine has no AppX
stack), the PLAN2 §7.2 state layout, and the wine-store-path stamp so `wineboot -u` runs once.

**Partial:** Slack (Electron) initialises and composites a framebuffer but creates no window, under
both wayland and x11. Wine's own notepad shows a window on both, so the fault is Slack's, not wine's
display layer. Not pursued (minified Electron). Details:
[`../docs/verified/slack-arm64.json`](../docs/verified/slack-arm64.json).

---

## Microsoft Store fetcher (spike)

See [`msstore/README.md`](msstore/README.md). Resolves a Store product id to a downloadable package
**anonymously — no Microsoft credentials**. Verified by a full 355 MB WhatsApp download with size, SHA1
and SHA256 all matching. Also yields the vendor-published framework-dependency closure. Two Store
acquisition paths exist: **FE3/MSIX** (this spike, for `9…`-class product ids) and **winget manifests**
(PoC 4, for `XP…`-class Win32 listings). Protocol detail: RESEARCH §10.

---

## PoC 3 — WhatsApp Desktop (Store MSIX, ARM64) under wine

```sh
nix-build whatsapp-arm64.nix && ./result/bin/whatsapp
```

No credentials. Three payloads (app + two ARM64 VCLibs frameworks) are resolved and fetched **inside
the FODs**, each verified against FE3's own size + SHA1 + SHA256 before nix's gate.

**The propnix machinery works end to end** — first PoC to prove PLAN2 §3.4 (Store payload inside a FOD)
and to package a real dependency closure. **.NET 8 CoreCLR starts** and WindowsAppSDK activates.

**Blocked by wine, not propnix:** WinUI 3's dispatcher (`CoreMessagingXP.dll`) statically imports
`Nt{Create,Associate,Cancel}WaitCompletionPacket`, which wine does not implement in any current build.
A missing *static* import binds to an aborting stub, so no tunable helps; a fix needs new wineserver
support. **Triage rule:** check these imports before packaging a WinUI 3 app (RESEARCH §11).
Details: [`../docs/verified/whatsapp-arm64.json`](../docs/verified/whatsapp-arm64.json).

---

## PoC 4 — Zoom Workplace (Store Win32/winget, ARM64) under wine

```sh
nix-build zoom-arm64.nix
PROPNIX_DPI=154 ./result/bin/zoom 'https://<host>.zoom.us/j/<id>?pwd=<pwd>'   # 96 = 100%
```

**Joins a real meeting with working audio**, on aarch64 under wine, with no emulation and no VM. The
first PoC to run a native C++ Windows app, and the first end-to-end call. Joining by link needs no
account (sign-in itself does not work).

**Acquisition — a third Store path.** `XP…` product ids are Win32 listings: DisplayCatalog 404s and
FE3 does not apply. Installers come from winget manifests
(`storeedgefd.dsx.mp.microsoft.com/v9.0/packageManifests/<id>`) — public JSON with an authoritative
`InstallerSha256`, and a **content-addressed** CDN URL that cannot expire, so plain `fetchurl` suffices
with no in-FOD resolver. The payload is an installer (7z SFX → CAB → 248-file tree) unpacked, not run.

**Two byte-level payload fixups are required, both per-package tuning:**
- **16K-page section fix** — one writable+shared PE section (`zCrashReport64.dll:.PROPSEC`) cannot be
  mapped on a 16K-page host; clear `IMAGE_SCN_MEM_SHARED` (RESEARCH §12).
- **EL0 PMU fix** — 15 `mrs …,pmccntr_el0` reads (6 binaries) trap on Linux; rewrite to `cntvct_el0`,
  else Zoom crashes seconds after joining (RESEARCH §12.1).

**Other per-package settings:** `wineWow64Packages.staging` (needs `SetThreadpoolTimerEx`);
`Graphics=x11` (winewayland mishandles Zoom's layered windows — corrects Slack's "no reason to prefer
x11", which is not a general default); runtime DPI via `LogPixels` (wine auto-detects DPI from
nothing).

**Known limitations (none block a call):**
- **Video does not display** — the participant tile renders but stays blank; wine repeatedly fails to
  resize the presentation swapchain. Audio is unaffected.
- **UI top is clipped** — constant offset, DPI-independent, unchanged by resize or driver.
- **"Unknown publisher" dialogs at launch** — the byte fixups break Authenticode digests; Zoom's
  self-check pins the signer's publisher **and** CA (DigiCert/Entrust) by name, which no local
  certificate can satisfy without impersonating a public CA. Re-signing takes the error to code 0 but
  the dialog persists; the dialogs are accepted (advisory — click through). RESEARCH §12.2.
- **Camera / screen-share** need wine features absent here (`libv4l2`,
  `d3d11.CreateDirect3D11DeviceFromDXGIDevice`).

Full record: [`../docs/verified/zoom-arm64.json`](../docs/verified/zoom-arm64.json).

---

## PoC 5 — Stellaris + 11 DLCs (GOG, x86_64 Linux) under box64

```sh
nix-build stellaris-x86_64.nix --option extra-sandbox-paths /propnix=/var/tmp/propnix
./result/bin/stellaris

nix-instantiate --eval --strict -A availableDLC stellaris-x86_64.nix    # what exists
nix-build stellaris-x86_64.nix --arg dlc '[ "nemesis" "megacorp" ]' ... # a subset
```

The first **multi-payload** package: up to twelve credentialed FODs (base + eleven owned DLC)
composed into one game tree.

**`dlc` defaults to `[ ]`, as in Hollow Knight, and that matters more here than it looks.** Eleven
DLC are owned on the packaging account, but defaulting to them would make the default derivation
depend on the *packager's* entitlements — `nix-build stellaris-x86_64.nix` would fail at rung 4 for
anyone who owns nine of the eleven, and every store path quoted in this README would be one most
readers cannot produce. Vanilla is the configuration every owner of Stellaris can build, so it is
the one the default names. `withAllDLC` opts into the rest.

**Proves** what Hollow Knight could not: DLC the engine actually loads. Each installer drops one
self-contained `dlc/dlcNNN_<name>/`, so composition is a directory union with no collisions
(RESEARCH §8).

**Three findings:**
- **`bsdtar` cannot read a ZIP64 MojoSetup installer.** At 15.9 GB the appended archive is ZIP64 and
  libarchive fails with `Damaged Zip archive` — not because of the prepended script, which is
  *larger* on Hollow Knight, but because it cannot reconcile the ZIP64 end-of-central-directory
  locator with a non-zero start offset. Info-ZIP `unzip` reads it, warns, and exits 1. Triage rule:
  **> 4 GiB means `unzip`, and tolerate exit status 1.** RESEARCH §8.
- **The Paradox Launcher is bypassed.** GOG's `start.sh` runs `./dowser`, which bootstraps an Electron
  launcher; `launcher-settings.json` records what that launcher would exec (`"exePath": "./stellaris"`,
  `"exeArgs": [ "-gdpr-compliant" ]`), so the wrapper runs exactly that and no Chromium stack has to
  survive emulation. Cost: the launcher's mod/playset UI.
- **Runs on Wayland, and prefers it.** `PROPNIX_SDL_VIDEODRIVER` overrides; otherwise the wrapper
  picks `wayland` when `WAYLAND_DISPLAY` is set and `x11` otherwise. Under wayland the process maps
  native `libwayland-{client,cursor,egl}` and `libxkbcommon` and reaches the frontend on the same
  OpenGL 4.6 Mesa device. It is *not* simply faster: SDL reports the **logical** 1600×1040 on this
  2560×1664 panel at scale 1.6, so it renders 2.56× fewer pixels and the compositor upscales, while
  x11 renders pixel-exact at native resolution with a UI sized for a non-HiDPI display. Hollow
  Knight's `x11` is Unity-specific and not a general default (RESEARCH §17).
- **The game tree cannot be a symlink farm.** Stellaris serves content through PhysFS, which refuses
  to traverse symlinks unless `PHYSFS_setSymbolicLinksPermitted(1)` is called — Clausewitz never
  calls it. Sharing one unpacked base across DLC selections by symlinking the top-level directories
  produced `File 'gfx/loadingscreens/init.bmp' does not exist : symlinks are forbidden` and a
  `std::logic_error` before any window appeared. box64 is not involved: PhysFS `lstat`s the path
  components itself. Extraction and DLC composition are therefore **fused into one derivation** —
  splitting them would cost the same wall clock (copying 27.7 GiB is no cheaper than extracting it)
  and twice the store. The builder asserts no symlink survives in `$out`, because the failure mode is
  a crash rather than an error. **Sharing between selections is nix's job**: the store optimiser
  hardlinks identical files across paths, so the vanilla and all-11-DLC trees share the `stellaris`
  binary at one inode (nlink 6) and occupy 16.9 GiB together rather than 2×27.7 — the second
  selection really costs ~375 MB. That beats the symlink farm on every axis: invisible to the
  application, no privileges, no runtime indirection, and each tree stays independently collectable.

**Mods are loaded, not ignored — and a stale playset crashes the game.** Bypassing the launcher means
nothing reconciles `dlc_load.json` against the installed version. Measured: 21 Steam Workshop mods
from a 3.x-era install were enabled silently, threw 582 `Wrong scope` errors (4.x split the planet
and colony scopes), and took the game down with SIGSEGV during galaxy generation; the identical tree
with an empty state dir ran clean. The wrapper now **warns** when `enabled_mods` is non-empty and
never rewrites the file — that belongs to the launcher and to every third-party mod manager.

The crash also showed the diagnostics are fine without the crash reporter: `crashes/<ts>/`
`{exception.txt,meta.yml,error.log,system.log}` are written by the *game*. `CrashReporter` itself is
a Backtrace **uploader** (`--uploadurl=https://submit.backtrace.io/paradoxinteractive/…`) and cannot
start because no native GTK3 is supplied — so no crash data leaves the machine. That is a feature,
not the bug the log noise suggests. Its `meta.yml` is also independent confirmation of the DLC
packaging: `DLC_1`…`DLC_11`, by title, straight from the engine.

**State is deliberately NOT namespaced under `$XDG_STATE_HOME/propnix/` (a documented deviation from
D13-3).** Paradox's own `~/.local/share/Paradox Interactive/Stellaris/` is already a stable,
install-independent key shared with any Steam or native install; redirecting it would orphan an
existing player's saves, mods and `dlc_load.json`, which is worse than a non-namespaced directory.
The wrapper creates that directory and writes nothing else into it.

**Measured:** OpenGL 4.6 (Compatibility Profile) Mesa 26.1.5, fullscreen 2560×1664, anisotropic 16;
audio through SDL2 → PulseAudio at 44100 Hz. The extraction is byte-exact against the archive listing
— 42,741 files / 1,107 directories / 29,778,452,123 bytes. `error.log` carries five lines, all
benign. The only launch-time complaint is `Failed to mount .../dlc004_plantoid/dlc004.zip with error
unsupported`, which is upstream data: GOG ships that zip as a 22-byte empty-zip record because the
Plantoids portraits are already in the base build and the `.dlc` file is only an ownership marker.

**Disk:** a first build needs ~45 GiB of free store (15.9 GiB payload + 27.7 GiB unpacked). Further
selections cost only their differing files on a store with `auto-optimise-store` (or after
`nix-store --optimise`).

Full record: [`../docs/verified/stellaris.json`](../docs/verified/stellaris.json).
