//! The launcher↔wrapper interface: the JSON config `makeAppWinefex` bakes (a `writeText` with store paths
//! interpolated) and passes via `--config`. Nix computes the intended set; the launcher enforces it. This
//! struct mirrors PLAN2 §4 exactly. Every field is explicit (no catch-all) so a schema drift fails loudly
//! at load, not silently at launch.

use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
pub struct Config {
    /// Interface version; bumped when this shape changes incompatibly.
    pub schema: u32,
    pub appid: String,
    pub name: String,
    /// Icon path (a store path to a PNG), or null this pass.
    pub icon: Option<String>,
    /// "winefex" for now; the box64/native backends are backlog.
    pub backend: String,
    /// The game tree (a store path); also the launch cwd.
    pub payload: String,
    /// The executable to run, relative to `payload` (e.g. "Hollow Knight.exe").
    pub exe: String,
    #[serde(rename = "wineUser")]
    pub wine_user: String,
    pub emulators: Emulators,
    pub defaults: Defaults,
    pub save: Save,
    pub seal: Seal,
    /// HKCU (user.reg) overrides re-applied on every launch (e.g. the black window colors).
    #[serde(rename = "userReg", default)]
    pub user_reg: Vec<RegOverride>,
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
    /// Full path to the propnix-prefetch binary.
    pub prefetch: String,
}

#[derive(Debug, Deserialize)]
pub struct Defaults {
    /// Wine display driver: "wayland" | "x11". Each PROPNIX_* env var overrides the matching default.
    pub graphics: String,
    /// D3D→GPU backend: "dxvk" | "wined3d".
    pub d3d: String,
    pub dpi: Option<u32>,
    pub fps: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct Save {
    /// Save location inside the guest profile, relative to `drive_c/users/<wineUser>`.
    #[serde(rename = "guestRel")]
    pub guest_rel: String,
    /// Default host location (shell-style, `$HOME`-expanded at runtime); PROPNIX_SAVE_DIR overrides.
    #[serde(rename = "hostDefault")]
    pub host_default: String,
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
