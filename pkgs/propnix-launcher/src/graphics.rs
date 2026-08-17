//! Builds the launcher's desired HKCU (user.reg) set and hands it to `userreg::update_user_reg`, which
//! reconciles it against what the launcher wrote last time (three-way merge; see userreg.rs). This is the
//! ONLY place that writes HKCU, so every managed key flows through one reconciliation — a key the launcher
//! stops setting is pruned from user.reg (unless the app changed it), which is what stops a stale value (e.g.
//! a since-removed LogPixels, or an fps cap after switching to VRR) persisting and misrendering the game.
//!
//! EVERY HKCU write is DECLARATIVE — there are no hardcoded keys here. The display driver and screen DPI are
//! just `userReg` entries in wine-defaults (`Graphics = "$PROPNIX_WINE_GRAPHICS"`,
//! `LogPixels = "$PROPNIX_DPI"`); `apply` exports the launcher's RESOLVED `settings.graphics`/`settings.dpi`
//! into those env vars so the `$VAR`s expand (capturing the per-game `graphics` override AND a runtime
//! `PROPNIX_*` override), then assembles the desired set from config, in ASCENDING precedence (later wins on
//! a (key,name) clash):
//!   1. `userReg`      — static per-game HKCU overrides (incl. the Graphics/LogPixels defaults from
//!                       wine-defaults); values are `$VAR`-expanded, so an unset var (e.g. `$PROPNIX_DPI`)
//!                       drops the entry → the three-way merge prunes it (the LogPixels self-heal).
//!   2. `fpsUserReg` / `vsyncUserReg` — HKCU overrides applied ONLY in the Fixed (`PROPNIX_FPS > 0`) resp.
//!                       Vrr (`PROPNIX_FPS == 0`) FPS mode; MUTUALLY EXCLUSIVE (one mode at a time). A prior
//!                       mode's group is pruned on the transition out of it.
//!   3. `userRegScript`— an escape hatch: a game executable whose JSON stdout is a set of HKCU overrides.
//! The ordering guarantees RUNTIME-DEPENDENT entries (fps/vsyncUserReg, userRegScript) ALWAYS override a
//! statically-set `userReg` value for the same key — a game states a base and refines it per launch.

use crate::config::{Config, RegOverride};
use crate::env::ChildEnv;
use crate::settings::{FpsMode, Paths, Settings};
use crate::userreg::{self, RegEntry};
use crate::util;
use std::collections::HashMap;
use std::process::{Command, Stdio};

/// Assemble the launcher-managed HKCU entries and reconcile them (userreg's three-way merge). Runs inside the
/// namespace with the prefix view live, in the worker, while the splash covers cold start. Returns `Err` only
/// when `userRegScript` fails (non-zero exit / bad JSON) — a packaging bug that aborts the launch; the
/// userReg / fps/vsyncUserReg entries never fail.
pub fn apply(
    cfg: &Config,
    settings: &Settings,
    paths: &Paths,
    child_env: &ChildEnv,
) -> Result<(), String> {
    let debug = std::env::var_os("PROPNIX_DEBUG").is_some();

    // Export the RESOLVED display settings so the declarative `$PROPNIX_WINE_GRAPHICS` / `$PROPNIX_DPI` userReg
    // entries (wine-defaults) expand here. `settings.graphics` = the PROPNIX_WINE_GRAPHICS env override → the
    // per-game `graphics` knob (already merged), so exporting it captures BOTH override layers. `settings.dpi`
    // is exported only when set → an unset `$PROPNIX_DPI` drops LogPixels, and the merge prunes a stale one.
    // Single-threaded here (run_inside_ns calls us before any thread / the wine spawn), so set_var is safe.
    // LOAD-BEARING: run_inside_ns spawns the module-prefetch thread only AFTER this returns, precisely because
    // that thread reads the env (`getenv`) — never move it above this call, or these two race.
    std::env::set_var("PROPNIX_WINE_GRAPHICS", &settings.graphics);
    if let Some(dpi) = settings.dpi {
        std::env::set_var("PROPNIX_DPI", dpi.to_string());
    }

    let mut desired: Vec<RegEntry> = Vec::new();

    // 1. Static userReg overrides (config keys are HKCU-RELATIVE, e.g. `Software\Wine\Drivers`). `$VAR`-expanded
    // like the fps/vsync groups — a plain value passes through unchanged; an entry whose var is unset is skipped
    // (so `$PROPNIX_DPI` unset → no LogPixels → pruned).
    push_conditional(&mut desired, &cfg.user_reg, "userReg", debug);

    // 2. fpsUserReg — applied ONLY in the Fixed FPS mode (PROPNIX_FPS > 0): a game's own frame-cap/vsync
    // registry keys, whose values may reference `$PROPNIX_FPS` (etc.) resolved now. In Vrr/Unmanaged mode
    // these are absent from the desired set, so the merge prunes any that a prior Fixed launch wrote. An entry
    // whose `$VAR` is unset is SKIPPED (never write a value with a blank hole).
    if let FpsMode::Fixed(_) = settings.fps {
        push_conditional(&mut desired, &cfg.fps_user_reg, "fpsUserReg", debug);
    }

    // 2b. vsyncUserReg — the VRR counterpart, applied ONLY in the Vrr mode (PROPNIX_FPS == 0): the game's own
    // vsync keys, so it presents FIFO and the display's variable refresh follows. Mutually exclusive with
    // fpsUserReg (different FPS modes), so the two never clash; both prune on the transition out of their mode.
    if let FpsMode::Vrr = settings.fps {
        push_conditional(&mut desired, &cfg.vsync_user_reg, "vsyncUserReg", debug);
    }

    // 3. userRegScript — the dynamic escape hatch. Its JSON stdout is a set of HKCU overrides (relative keys);
    // a failure ABORTS the launch (Err → run_inside_ns returns non-zero, the outer tears down).
    if let Some(script) = &cfg.user_reg_script {
        for o in run_user_reg_script(script, cfg)? {
            desired.push(entry_from(&o, o.value.clone()));
        }
    }

    // Collapse (key,name) clashes keeping the LAST occurrence, so the ascending-precedence order above holds
    // (script > fps/vsyncUserReg > userReg) and update_user_reg never sees / persists duplicate ids.
    let desired = dedup_last(desired);

    // The last-applied JSON lives in the WINE backend's state namespace (<state>/wine); ensure it exists (the
    // mounts create it too, but the merge must not depend on ordering).
    let _ = std::fs::create_dir_all(&paths.wine_state);
    userreg::update_user_reg(
        &format!("{}/bin/wine", cfg.emulators.wine),
        child_env,
        &paths.wine_state,
        &paths.view,
        &desired,
    );
    Ok(())
}

/// Push a conditional (fps/vsync) override group onto `desired`: `$VAR`-expand each value (an entry whose
/// var is unset is SKIPPED, not written blank) and append it. `label` names the source for the debug skip log.
fn push_conditional(desired: &mut Vec<RegEntry>, group: &[RegOverride], label: &str, debug: bool) {
    for o in group {
        match util::expand_env_checked(&o.value) {
            Some(v) => desired.push(entry_from(o, v)),
            None => {
                if debug {
                    eprintln!(
                        "propnix: {label} {}\\{} skipped — unresolved $var in {:?}",
                        o.key, o.name, o.value
                    );
                }
            }
        }
    }
}

/// Build a full-path `RegEntry` from a config `RegOverride` (whose `key` is HKCU-relative) and a resolved
/// value (verbatim for userReg/script, `$VAR`-expanded for fps/vsyncUserReg).
fn entry_from(o: &RegOverride, value: String) -> RegEntry {
    RegEntry {
        key: format!(r"HKCU\{}", o.key),
        name: o.name.clone(),
        value,
        value_type: o.value_type.clone(),
    }
}

/// Run the per-game `userRegScript` and parse its stdout as a JSON array of HKCU overrides. Its stderr is
/// inherited (diagnostics reach the console); a non-zero exit, a spawn failure, or unparseable stdout is a
/// hard error (aborts the launch).
fn run_user_reg_script(script: &str, cfg: &Config) -> Result<Vec<RegOverride>, String> {
    let out = Command::new(script)
        .env("PROPNIX_PAYLOAD", &cfg.payload)
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("cannot run userRegScript {script}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "userRegScript {script} exited {} — aborting (packaging bug)",
            crate::run::code_of(out.status)
        ));
    }
    serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("userRegScript {script}: invalid JSON on stdout: {e}"))
}

/// Keep the LAST occurrence of each `(key, name)` while preserving first-seen order — so higher-precedence
/// sources (pushed later) win, and the reconciler receives no duplicate identities.
fn dedup_last(entries: Vec<RegEntry>) -> Vec<RegEntry> {
    let mut order: Vec<(String, String)> = Vec::new();
    let mut latest: HashMap<(String, String), RegEntry> = HashMap::new();
    for e in entries {
        let id = (e.key.clone(), e.name.clone());
        if !latest.contains_key(&id) {
            order.push(id.clone());
        }
        latest.insert(id, e);
    }
    order
        .into_iter()
        .map(|id| latest.remove(&id).expect("id inserted above"))
        .collect()
}
