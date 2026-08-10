//! Wine HKCU registry tweaks applied in the worker before the game launches: the per-app display driver
//! (PROPNIX_WINE_GRAPHICS → HKCU\Software\Wine\Drivers\Graphics) and the black window background. Both are
//! reg-adds that spin a wineserver, so each is STAMPED and only runs on first launch / on change.
//!
//! (Driver: unlike winefex — which only stamped when the env var was set — the launcher stamps the
//! RESOLVED value, since the config now carries the default explicitly and wine's own default driver is
//! not necessarily the measured-best one; HK → winewayland, RESEARCH §12 / §6.2.)

use crate::config::Config;
use crate::env::ChildEnv;
use crate::settings::{Paths, Settings};
use std::fs;
use std::process::{Command, Stdio};

fn reg_add(wine: &str, child_env: &ChildEnv, key: &str, name: &str, reg_type: &str, data: &str) -> bool {
    let mut cmd = Command::new(wine);
    cmd.args(["reg", "add", key, "/v", name, "/t", reg_type, "/d", data, "/f"]);
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    child_env.apply(&mut cmd);
    matches!(cmd.status(), Ok(s) if s.success())
}

pub fn apply(cfg: &Config, settings: &Settings, paths: &Paths, child_env: &ChildEnv) {
    if settings.graphics.is_empty() {
        return;
    }
    let stamp = paths.prefix.join(".propnix-graphics");
    if fs::read_to_string(&stamp).ok().as_deref() == Some(settings.graphics.as_str()) {
        return; // unchanged — skip the wineserver spin
    }

    let wine = format!("{}/bin/wine", cfg.emulators.wine);
    // Best-effort (winefex: `|| true`); only stamp if the reg-add actually succeeded.
    if reg_add(
        &wine,
        child_env,
        r"HKCU\Software\Wine\Drivers",
        "Graphics",
        "REG_SZ",
        &settings.graphics,
    ) {
        let _ = fs::write(&stamp, &settings.graphics);
    }
}

/// Re-apply the configured HKCU (user.reg) overrides on EVERY launch (unstamped) so they always win and
/// update without a prefix reset — e.g. the black pre-render window background (config.userReg, from
/// winefex-defaults). wine regenerates user.reg fresh per prefix; these are layered back on top each
/// launch. One `wine reg add` per entry — which also CREATES user.reg on the very first launch, so the
/// override applies even then. Runs in the worker while the splash covers cold start.
pub fn apply_user_reg(cfg: &Config, child_env: &ChildEnv) {
    if cfg.user_reg.is_empty() {
        return;
    }
    let wine = format!("{}/bin/wine", cfg.emulators.wine);
    for o in &cfg.user_reg {
        let key = format!(r"HKCU\{}", o.key);
        reg_add(&wine, child_env, &key, &o.name, &o.value_type, &o.value);
    }
}
