//! The launcher↔wrapper interface: the JSON configs the wine/thin builders bake (a `writeText` with store
//! paths interpolated) and pass via `--config`. Nix computes the intended set; the launcher enforces it.
//! The wine `Config` mirrors PLAN2 §4. Schema drift fails loudly at LOAD, not silently at launch:
//!   * every flatten-free struct is `#[serde(deny_unknown_fields)]` — a misspelled or removed field is a
//!     deserialization error (the configs ship in lockstep with this launcher, so strictness is free);
//!   * `Mount`/`MountSpec` CANNOT be stamped (serde ignores/forbids `deny_unknown_fields` under
//!     `#[serde(flatten)]` + internal tagging), so mount-row keys are checked by an explicit validation
//!     pass in `Config::load` (`validate_mount_rows`) instead;
//!   * `ModeProbe` alone stays deliberately tolerant — it reads one field of the full config.

use serde::Deserialize;
use std::collections::BTreeMap;

/// Where the game payload is mounted inside the prefix (C:\game) and thus the launch cwd, relative to the
/// view root. mkWineApp mounts the payload here and puts the galaxy stubs under it; keep the two in sync.
pub const GAME_DIR: &str = "drive_c/game";

/// THIN mode's game dir, relative to the view root ($HOME): the launcher mounts the read-only game overlay
/// (the unioned `gameLowers`) here and runs the game from it. Under $HOME so it sits in the same ephemeral
/// per-launch view as the save binds; the game writes nothing here (state goes to the bound save dirs).
pub const THIN_GAME_DIR: &str = "game";

/// THIN mode's exec-bit-fix mountpoint PREFIX, relative to the view root: each `skeleton::lower` metacopy
/// overlay (see `GameModeFix`) is mounted at `<prefix><i>` and then takes its own tree's place in the game
/// overlay's lower stack. Hidden dirs in the view $HOME the game never reads. The leading `.` sorts these
/// before `game`, so they are laid before the overlay that references them.
pub const THIN_BINFIX_DIR: &str = ".propnix-binfixed";

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Interface version; bumped when this shape changes incompatibly.
    pub schema: u32,
    /// Whether the app may reach the network. `false` → the launcher unshares a NETWORK NAMESPACE for the
    /// game (loopback only), enforcing propnix's offline guarantee at the kernel rather than by trusting the
    /// app. Display and audio are unaffected (UNIX sockets live in the mount ns).
    pub online: bool,
    /// The launcher-dispatch tag ("prefix" — `ModeProbe` routes on it before this struct loads). Declared
    /// here as well so `deny_unknown_fields` accepts the baked field.
    pub mode: String,
    pub appid: String,
    pub name: String,
    /// Icon path (a store path to a PNG), or null this pass.
    pub icon: Option<String>,
    /// Which emulator set assembled this app: "winefex" (aarch64 wine+FEX) or "wine" (x86_64 native wine).
    /// The launcher itself is arch-transparent (it does NOT branch on this), so it's carried purely as a
    /// diagnostic — surfaced under PROPNIX_DEBUG. The box64/native backends are backlog.
    pub backend: String,
    /// The game tree (a store path); also the launch cwd.
    pub payload: String,
    /// The executable to run, relative to `payload` (e.g. "Hollow Knight.exe").
    pub exe: String,
    /// Optional launch working directory, RELATIVE to the game dir (drive_c/game). Some engines resolve
    /// their asset/data root from the CWD (not the exe path) and expect the CWD to be the exe's subdirectory
    /// — the goggame.info `workingDir`. E.g. Don't Starve's exe is `bin/dontstarve.exe`, it expects cwd =
    /// `bin`, and finds its data at `../data`; with cwd = the payload root it fails with a missing-shader
    /// assert. Null (the default) → cwd = drive_c/game (the payload root), the historical behaviour, so no
    /// existing game's launch directory changes.
    #[serde(rename = "workingDir", default)]
    pub working_dir: Option<String>,
    /// Baked command-line arguments passed to `exe` on every launch (before any runtime `-- <args>`
    /// passthrough). Per-game engine flags, e.g. a Unity title's `["-screen-fullscreen", "1"]`.
    #[serde(rename = "exeArgs", default)]
    pub exe_args: Vec<String>,
    pub emulators: Emulators,
    pub defaults: Defaults,
    pub seal: Seal,
    /// Env var names the launcher UNSETS before doing anything else — a per-game escape hatch from a user's
    /// global `PROPNIX_*` that a specific title cannot tolerate (e.g. Skyrim can't survive `PROPNIX_FPS`'s
    /// forced vsync-off or `PROPNIX_DPI`'s LogPixels stamp, so it lists both). Cleared first, so it wins over
    /// fact population, `Settings`, and the seal alike.
    #[serde(rename = "brokenVariables", default)]
    pub broken_variables: Vec<String>,
    /// HKCU (user.reg) overrides re-applied on every launch (e.g. the black window colors).
    #[serde(rename = "userReg", default)]
    pub user_reg: Vec<RegOverride>,
    /// HKCU overrides applied ONLY when `PROPNIX_FPS > 0` (a fixed cap; NOT VRR/unset) — same shape as
    /// `userReg`, but the `value` may contain `$VAR`/`${VAR}` (notably `$PROPNIX_FPS`) expanded at launch
    /// (graphics.rs). Deliberately NOT baked into the base user.reg (the value isn't known until runtime) and
    /// folded into the three-way-merge desired set only in the Fixed FPS mode — so switching away from a
    /// fixed cap PRUNES them (the merge self-heals; see userreg.rs). An entry whose `$VAR` is unset is skipped.
    #[serde(rename = "fpsUserReg", default)]
    pub fps_user_reg: Vec<RegOverride>,
    /// HKCU overrides applied ONLY when `PROPNIX_FPS == 0` (VRR) — the counterpart to `fpsUserReg`: ENABLE
    /// the game's own vsync so it presents FIFO and the display's variable refresh follows it. Same shape and
    /// semantics as `fpsUserReg` (runtime `$VAR` expansion, runtime-precedence over static `userReg`, folded
    /// into the desired set only in the Vrr mode so it's PRUNED on the transition out of VRR).
    #[serde(rename = "vsyncUserReg", default)]
    pub vsync_user_reg: Vec<RegOverride>,
    /// Optional escape hatch: a store-path executable the launcher runs (INNER, prefix view live) with the
    /// runtime env (incl. `PROPNIX_FPS`, `PROPNIX_PAYLOAD`) whose STDOUT is a JSON array of HKCU overrides
    /// (`[{ "key": "<HKCU-relative>", "name", "value", "type"? }]`, `type` default REG_SZ) applied this
    /// launch via the same three-way merge. For dynamic per-launch registry customization the static
    /// `userReg`/`fpsUserReg` can't express. A non-zero exit or unparseable stdout ABORTS the launch (like
    /// `setupScript` — a failure is a packaging bug that must surface).
    #[serde(rename = "userRegScript", default)]
    pub user_reg_script: Option<String>,
    /// The WINEPREFIX mount table: target (relative to the prefix root) → mount spec. The launcher resolves
    /// the symbolic sources, drops `enabled = false` entries, sorts parent-first, and lays the binds with
    /// propnix-mount to assemble the prefix the game sees.
    #[serde(default)]
    pub mounts: BTreeMap<String, Mount>,
    /// Optional per-game SETUP SCRIPT (a store-path executable) the launcher runs in the OUTER phase, before
    /// wine — the escape hatch for game-specific prefix setup that doesn't belong in the launcher itself
    /// (e.g. Skyrim seeding SkyrimPrefs.ini `iSize` + a quality preset). Runs with the runtime env available
    /// (PROPNIX_SAVE_DIR/APPID/WIDTH/HEIGHT/QUALITY + PROPNIX_PAYLOAD = the game tree). A NON-ZERO exit ABORTS
    /// the launch: a setup failure means a packaging bug or a would-be-corrupted prefix, which must surface.
    #[serde(rename = "setupScript", default)]
    pub setup_script: Option<String>,
    /// Whether this build carries the gbe_fork offline Steam-entitlement shim (steam.emu.enable). When set,
    /// the launcher seats the stored Steam account's SteamID64 into the shim's global settings inside the
    /// per-launch view (see steamid.rs) — gated so a GOG game's launch never touches the credential store.
    #[serde(rename = "steamEmu", default)]
    pub steam_emu: bool,
    /// The baked GL/Vulkan fallback stack (see `FallbackGl`); optional so a pre-existing baked config loads.
    #[serde(rename = "fallbackGl", default)]
    pub fallback_gl: Option<FallbackGl>,
}

/// A mount-table entry (keyed by target). The `spec` is a type-tagged SUM so a bind and an overlay can't be
/// mixed (a bind has no `lower`/`upper`; an overlay has no `source`/`mode`). Common knobs sit alongside it.
/// Targets (the keys) are paths RELATIVE to the tmpfs prefix root; sources are `$VAR`-expanded by the
/// launcher (it sets `PROPNIX_STATE`/`PROPNIX_SAVE_DIR`/`PROPNIX_APPID`; store paths are baked literal by
/// Nix). Only literal paths ever reach propnix-mount. (Nix defaults `type` to "mount"; see sealing.nix.)
/// NOT `deny_unknown_fields`: serde ignores/forbids it under `#[serde(flatten)]` + internal tagging, so an
/// unknown row key would be silently dropped — `validate_mount_rows` does that strict check instead.
#[derive(Debug, Deserialize, Clone)]
pub struct Mount {
    #[serde(flatten)]
    pub spec: MountSpec,
    /// A disabled entry (default true) is dropped when building the topology.
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// If the writable dir (mount `source` / persistent overlay `upper`) is missing: create it (true) or
    /// FAIL the launch (false, the default — a missing store source/lower is a bug and should fail loudly).
    #[serde(rename = "createIfNotExist", default)]
    pub create_if_not_exist: bool,
}

#[derive(Debug, Deserialize, Clone)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum MountSpec {
    /// A bind mount of `source` at the target — OR, when `source` is null, a fresh ns-private tmpfs mounted
    /// at the target (an ephemeral, writable, per-launch directory; nothing persists across launches).
    Mount {
        /// The bind source (an env-expandable path). Null → a fresh ns-private tmpfs at the target.
        #[serde(default)]
        source: Option<String>,
        /// "ro" | "rw" (default "rw").
        #[serde(default = "default_mount_mode")]
        mode: String,
        /// Optional seed path (env-expandable). When set, on EVERY launch the target is populated from
        /// `seed`: every file NOT already present is copied in (existing files are never overwritten), done
        /// concurrently. Combined with a null `source` this gives a per-launch tmpfs pre-filled with a store
        /// tree — used for game assemblies a runtime (e.g. Mono) needs as real files in a writable dir that
        /// a data-only overlay can't provide (kernel overlayfs MAP_SHARED-of-lower limitation).
        #[serde(default)]
        seed: Option<String>,
    },
    /// A COW overlay: reads fall through to the read-only `lower`; writes go to `upper` — or, when `upper`
    /// is null, an EPHEMERAL per-launch tmpfs upper (cleared every launch). The persistent form (upper set)
    /// is how store-shipped defaults become writable without copying. With `readOnly` set it is instead a
    /// lowerdir-only merge of several read-only lowers (no writable layer at all).
    Overlay {
        /// The read-only lower layer(s), an env-expandable path — or several colon-joined into one string
        /// (`a:b:c`) to UNION them (overlayfs `lowerdir`). Multi-lower is how a base payload + DLC trees merge.
        lower: String,
        /// The writable upper layer (an env-expandable path); null → ephemeral per-launch tmpfs upper. Ignored
        /// when `readOnly` is set (a read-only overlay has no upper).
        #[serde(default)]
        upper: Option<String>,
        /// Optional store path to a TAR of a data-only METADATA skeleton (sparse stubs sized to each
        /// original + `user.overlay.metacopy`/`redirect`). Set when `lower` is a root-owned Nix store tree:
        /// propnix-mount extracts it into a tmpfs and stacks it above `lower` so copy-up works unprivileged
        /// and preserves data. Null → a plain overlay over a user-owned/ephemeral `lower`.
        #[serde(default)]
        skeleton: Option<String>,
        /// Read-only overlay: mount the (possibly multi-`lower`) union with NO upper/work layer, so the merged
        /// tree cannot be written. Unlike `upper = null` (ephemeral writable tmpfs upper), there is no upper at
        /// all. Used for merging a base game with DLC trees into a strictly read-only game dir. Default false.
        #[serde(rename = "readOnly", default)]
        read_only: bool,
    },
    /// Bind one regular FILE at the target. Identical to `Mount` except in what it IS: the source is a
    /// file, so `createIfNotExist` TOUCHES it instead of `mkdir -p`, and propnix-mount lays a file
    /// mountpoint rather than a directory one.
    ///
    /// Its reason to exist is redirecting an individual file out of a directory that is itself bound
    /// somewhere else. Factorio is the case: it writes `atlas-cache.dat` (~1.4 GB with Space Age),
    /// `data-cache.dat` and `crop-cache.dat` into the SAME write-data root as `saves/` and `mods/`, and
    /// offers no path option for them — so the caches cannot be split off by an overlay (one `upper`
    /// cannot route by filename) and have to be bound file by file out of the save dir into the state dir.
    File {
        /// The bind source (an env-expandable path). Unlike `Mount`, never null: a file mount has nothing
        /// ephemeral to fall back to.
        source: String,
        /// "ro" | "rw" (default "rw").
        #[serde(default = "default_mount_mode")]
        mode: String,
    },
    /// ERASE the file at the target (the key) from its parent mount — a true absence, no store copy. Realized
    /// by propnix-mount overlaying the parent dir in place with a char-device 0,0 whiteout for the basename.
    /// Used to neutralize a store-integration DLL a wine game bundles (e.g. a Steam build's steam_api64.dll)
    /// so the game's plugin loader reports "no online subsystem" and runs offline — the wine-path sibling of
    /// the THIN `maskFiles` mechanism (both are derived from the game's `maskFiles`). Carries no other fields.
    Whiteout {},
}

fn default_mount_mode() -> String {
    "rw".to_string()
}
fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegOverride {
    /// Key relative to HKEY_CURRENT_USER, e.g. "Control Panel\\Colors".
    pub key: String,
    pub name: String,
    pub value: String,
    /// Registry type: "REG_SZ" (default), "REG_DWORD", ….
    #[serde(rename = "type", default = "default_reg_type")]
    pub value_type: String,
}

fn default_reg_type() -> String {
    "REG_SZ".to_string()
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Emulators {
    /// wine-hangover store dir (`/bin/wine`, `/bin/wineserver`).
    pub wine: String,
    // (No `prefixLower`: the read-only system tree reaches the launcher only as the baked `${prefixLower}/…`
    // sources of the `mounts` rows. Nothing needs the root itself — the module prefetch warms the ASSEMBLED
    // prefix from inside the mount ns, not the store tree — so it is not baked, per `deny_unknown_fields`.)
    /// Native ARM64EC DXVK store dir (d3d11/d3d10core/dxgi/d3d9 DLLs).
    pub dxvk: String,
    /// Native ARM64EC vkd3d-proton store dir (d3d12/d3d12core DLLs).
    pub vkd3d: String,
    /// Full path to a `tar` binary, used by the linked `propnix_mount` to extract overlay `skeleton` tars
    /// (it has no runtime deps of its own; the launcher supplies this baked store path). (propnix-mount and
    /// propnix-prefetch are no longer separate binaries — they're compiled into this launcher.)
    pub tar: String,
    /// The MangoHud package root. Under PROPNIX_BENCH on the Vulkan backend, the launcher enables MangoHud's
    /// Vulkan implicit layer by adding `<mangohud>/share` to the child's XDG_DATA_DIRS (+ MANGOHUD=1) — one
    /// overlay covering both DXVK and vkd3d. No GL hook, so it never touches the wined3d path.
    pub mangohud: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Defaults {
    /// Wine display driver: "wayland" | "x11". Each PROPNIX_* env var overrides the matching default.
    pub graphics: String,
    /// D3D→GPU backend: "dxvk" | "wined3d".
    pub d3d: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Seal {
    /// Env-var name PREFIXES to unset before spawning the child (targeted scrub, never env_clear).
    pub scrub: Vec<String>,
    /// Structured WINEDLLOVERRIDES: DLL name → load order ("n"=native, "b"=builtin, ""=disabled). The
    /// launcher joins this into the WINEDLLOVERRIDES string and merges the DXVK/vkd3d entries on top.
    /// BTreeMap → deterministic order.
    #[serde(rename = "dllOverrides", default)]
    pub dll_overrides: BTreeMap<String, String>,
    /// The remaining "meant" vars (WINEDEBUG, USER/LOGNAME, + any per-game extras) set on top of the
    /// (scrubbed) inherited env. BTreeMap → deterministic apply order.
    #[serde(rename = "setEnv", default)]
    pub set_env: BTreeMap<String, String>,
}

/// The launcher runs in one of two MODES, tagged by the config's `mode` field (default "prefix"):
///   * "prefix" — the wine path: `Config` above (userns + mount table + WINEPREFIX overlay). UNCHANGED.
///   * "thin"   — box64/native: `ThinConfig` below (no prefix; scrubbed env + LD_LIBRARY_PATH + cwd + save
///                binds + execve). The two share focus/splash/window-watcher/signals.
/// `ModeProbe` reads just the discriminator so `main` can deserialize the right variant (their field sets
/// differ, so loading a thin config as `Config` would fail on the missing wine fields).
#[derive(Deserialize)]
pub struct ModeProbe {
    #[serde(default = "default_mode")]
    pub mode: String,
}

fn default_mode() -> String {
    "prefix".to_string()
}

impl ModeProbe {
    pub fn mode_of(path: &str) -> Result<String, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read config {path}: {e}"))?;
        let p: ModeProbe =
            serde_json::from_str(&text).map_err(|e| format!("invalid config {path}: {e}"))?;
        Ok(p.mode)
    }
}

/// The GL/Vulkan userspace of last resort: a mesa baked into the closure. Nix-built glvnd/vulkan-loader
/// resolve their vendor through `/run/opengl-driver`, which only NixOS provides — on any other distro the
/// launcher points the standard discovery env vars at this stack instead (glstack.rs), so a game runs on a
/// host with nothing but nix installed. `forced` (the `mesa` knob set to a derivation) applies it even when
/// `/run/opengl-driver` exists — a per-game driver patch must beat the host stack too.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FallbackGl {
    pub forced: bool,
    /// `<mesa>/lib` — the GLX/EGL vendor libraries (libGLX_mesa/libEGL_mesa); goes on LD_LIBRARY_PATH.
    #[serde(rename = "libDir")]
    pub lib_dir: String,
    /// `<mesa>/lib/dri` — the DRI megadrivers (LIBGL_DRIVERS_PATH, and LIBVA_DRIVERS_PATH: mesa keeps its
    /// VA-API drivers in the same dir on the arches that build them).
    #[serde(rename = "driDir")]
    pub dri_dir: String,
    /// `<mesa>/lib/gbm` — the gbm backend (GBM_BACKENDS_PATH); winewayland allocates through gbm.
    #[serde(rename = "gbmDir")]
    pub gbm_dir: String,
    /// `<mesa>/share/glvnd/egl_vendor.d` (__EGL_VENDOR_LIBRARY_DIRS).
    #[serde(rename = "eglVendorDir")]
    pub egl_vendor_dir: String,
    /// `<mesa>/share/vulkan/icd.d` — its *.json files become VK_DRIVER_FILES.
    #[serde(rename = "vulkanIcdDir")]
    pub vulkan_icd_dir: String,
}

/// THIN-mode config: a native/box64 Linux game. No wine prefix — $HOME is a fresh per-launch tmpfs view; the
/// game tree (`gameLowers`, read-only overlay) is mounted at the view's game dir and run from there under a
/// scrubbed env with the library union on LD_LIBRARY_PATH; the declared save dirs are bound out of the view to
/// persistent $STATE. So a native game writes its own paths (`$HOME/.local/share/…`) while the data lands in
/// propnix-managed dirs — mirroring the wine PROPNIX_SAVE_DIR/<appid> semantics.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinConfig {
    pub schema: u32,
    /// Whether the app may reach the network. `false` → the launcher unshares a NETWORK NAMESPACE for the
    /// game (loopback only), enforcing propnix's offline guarantee at the kernel rather than by trusting the
    /// app. Display and audio are unaffected (UNIX sockets live in the mount ns).
    pub online: bool,
    /// The launcher-dispatch tag ("thin"; see `ModeProbe`). Declared here as well so `deny_unknown_fields`
    /// accepts the baked field.
    pub mode: String,
    #[serde(rename = "appId")]
    pub app_id: String,
    pub name: String,
    /// Icon path (a store-path PNG) for the splash + desktop entry, or null.
    pub icon: Option<String>,
    /// The game tree the launcher mounts read-only at the view's game dir (`THIN_GAME_DIR`) and runs from. One
    /// or more store paths: a single-tree game is one path (bound); a multi-depot Steam game is several
    /// (e.g. Stellaris = binaries depot + data depot), UNIONED by a read-only overlayfs at mount time — merged
    /// for FREE with NO store copy (leftmost wins on overlap), exactly like the wine DLC overlay. overlayfs
    /// presents real dirs/files (not symlinks), so a PhysFS-style engine traverses the union fine. These are
    /// the lowers that need NO exec-bit fix — the fixed game trees arrive as `gameModeFixes` and are stacked
    /// BELOW these, in their own order.
    #[serde(rename = "gameLowers")]
    pub game_lowers: Vec<String>,
    /// The EXEC-BIT-fixed game trees, highest priority first — one entry per game tree (payloads and enabled
    /// DLC alike). A Steam depot ships mode 0444 (no +x); box64/native exec require +x on the ELF. Rather
    /// than re-emit the executable's data, each `skeleton` is a sparse metacopy skeleton of its own `lower`
    /// whose exe stubs are 0755, with `lower` as the metacopy DATA source: the launcher mounts
    /// `skeleton::lower` (userxattr) — the merged files are +x with data redirected to the store (ZERO copy).
    ///
    /// ONE PER TREE, deliberately. A single fix layer built from the primary payload and stacked at the very
    /// top mirrors that whole tree, so it SHADOWS every higher-priority lower (a DLC that ships its own build
    /// of the game — Factorio's Space Age is a complete tree on both stores — would silently lose to the base
    /// engine), and it leaves an executable that only the DLC supplies at 0444. Fixing each tree in place
    /// keeps every layer's priority intact and every layer's executables runnable. See thin.rs resolve.
    #[serde(rename = "gameModeFixes", default)]
    pub game_mode_fixes: Vec<GameModeFix>,
    /// Game-dir-relative files to ERASE from the game dir — each becomes a propnix-mount `whiteout` entry (an
    /// overlay-whiteout over the file's parent), so the file is genuinely absent at runtime with no store copy.
    /// Used to neutralize a bundled library (e.g. a Steam game's libsteam_api.so). Default empty.
    /// The highest-priority GAME TREE (a store path) — what `PROPNIX_PAYLOAD` points a setup script at so
    /// it can read shipped assets. Not derivable from `gameLowers`/`gameModeFixes`, whose heads are the
    /// backend's own overlays (patched exe, entitlement settings) rather than game content.
    pub payload: String,
    /// Optional per-game SETUP SCRIPT (a store-path executable) run in the OUTER phase, before the view is
    /// assembled — the same hook the wine path has (`Config::setup_script`), because it is not wine-specific:
    /// it seeds a config file in the game's own save dir, which exists on the host either way. Runs with the
    /// runtime env (PROPNIX_SAVE_DIR/APPID/WIDTH/HEIGHT/QUALITY + PROPNIX_PAYLOAD). A NON-ZERO exit ABORTS
    /// the launch: a setup failure is a packaging bug or a half-written config, not something to launch into.
    #[serde(rename = "setupScript", default)]
    pub setup_script: Option<String>,
    #[serde(rename = "maskFiles", default)]
    pub mask_files: Vec<String>,
    /// The program that runs the game: `${box64}/bin/box64` on aarch64 (the x86_64 ELF is passed as its arg),
    /// or null on x86_64 where the ELF is exec'd natively. An absolute store path when set.
    #[serde(default)]
    pub emulator: Option<String>,
    /// The game executable, RELATIVE to the game dir (e.g. "stellaris"). The launcher runs it as
    /// `<emulator> <gameDir>/<exe> <exeArgs>` (aarch64) or `<gameDir>/<exe> <exeArgs>` (native).
    pub exe: String,
    /// Baked args passed to the exe on every launch (before any runtime `-- <args>`), e.g. `[ "-gdpr-compliant" ]`.
    #[serde(rename = "exeArgs", default)]
    pub exe_args: Vec<String>,
    /// Optional working directory RELATIVE to the game dir (for an engine that resolves its data root from cwd).
    /// Null (default) → cwd = the game dir root.
    #[serde(rename = "workingDir", default)]
    pub working_dir: Option<String>,
    /// Env vars SET on the child after the scrub ($VAR-expanded): box64 knobs, SDL driver, etc.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// The ':'-joined LD_LIBRARY_PATH — the native aarch64 bridging libs box64 wraps + the x86_64 guest libs,
    /// baked by nix (`lib.makeLibraryPath (native ++ guest)`).
    #[serde(rename = "ldLibraryPath", default)]
    pub ld_library_path: String,
    /// Env-name PREFIXES scrubbed before the child (targeted, never env_clear) — e.g. BOX64_/FEX_/LD_/WINE.
    #[serde(rename = "scrubPrefixes", default)]
    pub scrub_prefixes: Vec<String>,
    /// Save/state bind rows: bind `src` (a persistent `$STATE/…`/`$VAR`-expandable dir) at `dst` (a path under
    /// the view $HOME). Laid by propnix-mount in the game's private mount ns.
    #[serde(default)]
    pub binds: Vec<Bind>,
    #[serde(default = "default_true")]
    pub splash: bool,
    #[serde(rename = "singleInstance", default = "default_true")]
    pub single_instance: bool,
    #[serde(rename = "windowWatch", default = "default_true")]
    pub window_watch: bool,
    /// A `tar` binary path for propnix-mount's skeleton extraction (it has no runtime deps of its own).
    pub tar: String,
    /// The NATIVE MangoHud package root for PROPNIX_BENCH. box64 renders through native Mesa (it wraps libGL),
    /// and box64 has a built-in special-case for `libMangoHud_shim.so`'s `dlsym`, so the HUD is enabled the way
    /// the `mangohud` wrapper does: LD_PRELOAD the SHIM (`<root>/lib/mangohud/libMangoHud_shim.so`), put that
    /// dir on LD_LIBRARY_PATH (so the shim finds its opengl/dlsym siblings), and add `<root>/share` to
    /// XDG_DATA_DIRS (the Vulkan implicit layer). See thin.rs.
    #[serde(default)]
    pub mangohud: Option<String>,
    /// Whether this build carries the gbe_fork offline Steam-entitlement shim (steam.emu.enable). When set,
    /// the launcher seats the stored Steam account's SteamID64 into the shim's global settings inside the
    /// per-launch view (see steamid.rs) — gated so a GOG game's launch never touches the credential store.
    #[serde(rename = "steamEmu", default)]
    pub steam_emu: bool,
    /// The baked GL/Vulkan fallback stack (see `FallbackGl`); optional so a pre-existing baked config loads.
    #[serde(rename = "fallbackGl", default)]
    pub fallback_gl: Option<FallbackGl>,
}

/// THIN-mode exec-bit fix for ONE game tree (see `ThinConfig::game_mode_fixes`): a metacopy skeleton
/// (`skeleton`, a sparse-stub tar whose executable stubs are 0755) over that tree (`lower`) as its data
/// source. The launcher mounts `skeleton::lower` (userxattr) so the merged executables are +x with data
/// redirected to the store, and the result takes that tree's own place in the lower stack — all zero-copy.
#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct GameModeFix {
    pub skeleton: String,
    pub lower: String,
}

/// What a THIN bind row binds — the thin counterpart of the wine mount table's `type` discriminator.
#[derive(Debug, Deserialize, Clone, Copy, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
pub enum BindKind {
    /// A directory (the default): `create` makes it with `mkdir -p`.
    #[default]
    Mount,
    /// A single regular file: `create` touches it, and propnix-mount lays a file mountpoint.
    File,
}

/// A THIN-mode save/state bind: `src` (persistent, $VAR-expandable) mounted at `dst` (under the view $HOME).
#[derive(Debug, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Bind {
    pub src: String,
    pub dst: String,
    /// What this row binds: a directory (the default) or a single regular `file`. The same distinction the
    /// wine mount table draws with `type = "file"`, and for the same reason — `create` must touch a file
    /// rather than `mkdir -p` it. See `MountSpec::File`.
    #[serde(rename = "type", default)]
    pub kind: BindKind,
    #[serde(default)]
    pub ro: bool,
    #[serde(default = "default_true")]
    pub create: bool,
}

impl ThinConfig {
    pub fn load(path: &str) -> Result<ThinConfig, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read config {path}: {e}"))?;
        let cfg: ThinConfig =
            serde_json::from_str(&text).map_err(|e| format!("invalid config {path}: {e}"))?;
        if cfg.schema != 1 {
            return Err(format!("unsupported config schema {} (need 1)", cfg.schema));
        }
        Ok(cfg)
    }
}

impl Config {
    pub fn load(path: &str) -> Result<Config, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read config {path}: {e}"))?;
        // The explicit mount-row key check first (serde cannot strict-check those rows; see
        // `validate_mount_rows`), then the typed deserialization from the same text — the file is read once.
        let raw: serde_json::Value =
            serde_json::from_str(&text).map_err(|e| format!("invalid config {path}: {e}"))?;
        validate_mount_rows(&raw, path)?;
        let cfg: Config =
            serde_json::from_str(&text).map_err(|e| format!("invalid config {path}: {e}"))?;
        if cfg.schema != 1 {
            return Err(format!(
                "config schema {} unsupported (this launcher speaks schema 1)",
                cfg.schema
            ));
        }
        Ok(cfg)
    }
}

/// The strict key check serde cannot do for `mounts` rows: `Mount` flattens the internally-tagged
/// `MountSpec`, and serde ignores/forbids `deny_unknown_fields` on that combination — so without this pass a
/// misspelled row key (`sorce`, `readonly`, …) would be SILENTLY DROPPED and the row would launch with the
/// field's default. Walks the raw JSON's `.mounts` and checks each row's keys against its `type` variant's
/// allowed set, failing with the target + offending key. The rest of the row's typing (value shapes, the
/// tag itself) is still serde's job in the typed deserialization that follows.
fn validate_mount_rows(raw: &serde_json::Value, path: &str) -> Result<(), String> {
    // Keys every bind/overlay row may carry (`Mount`'s own fields + the tag).
    const COMMON: &[&str] = &["type", "enabled", "createIfNotExist"];
    let Some(mounts) = raw.get("mounts") else {
        return Ok(()); // absent → serde's `#[serde(default)]` empty table
    };
    let Some(map) = mounts.as_object() else {
        return Err(format!("invalid config {path}: `mounts` is not an object"));
    };
    for (target, row) in map {
        let Some(obj) = row.as_object() else {
            return Err(format!(
                "invalid config {path}: mount row '{target}' is not an object"
            ));
        };
        // A missing/non-string tag is left for serde's own missing-field-`type` error, right after this pass.
        let Some(ty) = obj.get("type").and_then(|v| v.as_str()) else {
            continue;
        };
        // Per-variant keys, mirroring `MountSpec` (a whiteout carries nothing beyond the tag + `enabled`).
        let (variant, extra): (&[&str], &[&str]) = match ty {
            "mount" => (&["source", "mode", "seed"], COMMON),
            "overlay" => (&["lower", "upper", "skeleton", "readOnly"], COMMON),
            "file" => (&["source", "mode"], COMMON),
            "whiteout" => (&[], &["type", "enabled"]),
            other => {
                return Err(format!(
                    "invalid config {path}: mount row '{target}' has unknown type '{other}' \
                     (expected mount | overlay | whiteout)"
                ));
            }
        };
        for key in obj.keys() {
            if !variant.contains(&key.as_str()) && !extra.contains(&key.as_str()) {
                return Err(format!(
                    "invalid config {path}: mount row '{target}' (type '{ty}') has unknown key '{key}'"
                ));
            }
        }
    }
    Ok(())
}
