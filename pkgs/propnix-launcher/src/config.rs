//! The launcher↔wrapper interface: the JSON config `makeAppWine` bakes (a `writeText` with store paths
//! interpolated) and passes via `--config`. Nix computes the intended set; the launcher enforces it. This
//! struct mirrors PLAN2 §4 exactly. Every field is explicit (no catch-all) so a schema drift fails loudly
//! at load, not silently at launch.

use serde::Deserialize;
use std::collections::BTreeMap;

/// Where the game payload is mounted inside the prefix (C:\game) and thus the launch cwd, relative to the
/// view root. makeAppWine mounts the payload here and puts the galaxy stubs under it; keep the two in sync.
pub const GAME_DIR: &str = "drive_c/game";

#[derive(Debug, Deserialize)]
pub struct Config {
    /// Interface version; bumped when this shape changes incompatibly.
    pub schema: u32,
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
}

/// A mount-table entry (keyed by target). The `spec` is a type-tagged SUM so a bind and an overlay can't be
/// mixed (a bind has no `lower`/`upper`; an overlay has no `source`/`mode`). Common knobs sit alongside it.
/// Targets (the keys) are paths RELATIVE to the tmpfs prefix root; sources are `$VAR`-expanded by the
/// launcher (it sets `PROPNIX_STATE`/`PROPNIX_SAVE_DIR`/`PROPNIX_APPID`; store paths are baked literal by
/// Nix). Only literal paths ever reach propnix-mount. (Nix defaults `type` to "mount"; see sealing.nix.)
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
    /// is how store-shipped defaults become writable without copying.
    Overlay {
        /// The read-only lower layer (an env-expandable path).
        lower: String,
        /// The writable upper layer (an env-expandable path); null → ephemeral per-launch tmpfs upper.
        #[serde(default)]
        upper: Option<String>,
        /// Optional store path to a TAR of a data-only METADATA skeleton (sparse stubs sized to each
        /// original + `user.overlay.metacopy`/`redirect`). Set when `lower` is a root-owned Nix store tree:
        /// propnix-mount extracts it into a tmpfs and stacks it above `lower` so copy-up works unprivileged
        /// and preserves data. Null → a plain overlay over a user-owned/ephemeral `lower`.
        #[serde(default)]
        skeleton: Option<String>,
    },
}

fn default_mount_mode() -> String {
    "rw".to_string()
}
fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
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
pub struct Emulators {
    /// wine-hangover store dir (`/bin/wine`, `/bin/wineserver`).
    pub wine: String,
    /// The read-only system tree symlinked into each prefix (wine-prefix-lower).
    #[serde(rename = "prefixLower")]
    pub prefix_lower: String,
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
pub struct Defaults {
    /// Wine display driver: "wayland" | "x11". Each PROPNIX_* env var overrides the matching default.
    pub graphics: String,
    /// D3D→GPU backend: "dxvk" | "wined3d".
    pub d3d: String,
}

#[derive(Debug, Deserialize)]
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

impl Config {
    pub fn load(path: &str) -> Result<Config, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read config {path}: {e}"))?;
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
