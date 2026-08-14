//! Three-way-merge management of the launcher's HKCU (user.reg) entries — the "last-applied-configuration"
//! pattern (à la `kubectl apply`). Every launcher-managed HKCU write (the Graphics driver, DPI/LogPixels, the
//! per-game `userReg` overrides) contributes to ONE desired set passed to `update_user_reg`; nothing else
//! touches user.reg. The merge reconciles three inputs:
//!   * DESIRED      — the set we're about to write (this launch).
//!   * LAST-APPLIED — what the launcher wrote last time, persisted alongside the prefix state.
//!   * LIVE         — the current user.reg (the once-seeded game-agnostic base, plus whatever the launcher
//!                    and the app have written since — all persisted in the root mount's upper).
//! and PRUNES a key that left the desired set IFF `live == last-applied` for it — i.e. the launcher's own
//! last value is still there, untouched by the app. If the app changed it, it's left alone (app writes win).
//! This is what stops a since-removed managed value (e.g. a LogPixels the launcher no longer sets) persisting
//! in the persistent prefix and misrendering the game — the footgun that black-screened Skyrim.
//!
//! CRASH SAFETY: the last-applied set is persisted by ATOMIC REPLACE (temp + fsync + rename — `rename(2)` is
//! atomic, so a kill leaves the whole old or whole new file, never a torn one), and the prune is guarded by
//! `live == last-applied`, making the whole operation IDEMPOTENT — a kill at any point re-reconciles to the
//! same result on the next launch. A key whose `reg delete` didn't succeed is kept in last-applied so it's
//! retried next time (never silently orphaned). Single-writer: the per-appid flock serializes launches.

use crate::env::ChildEnv;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// One managed HKCU entry. `key` is the FULL path INCLUDING the `HKCU\` prefix (e.g.
/// `HKCU\Software\Wine\Drivers`); `value` is the raw value in the SAME form `reg add /d` takes and
/// `parse_user_reg` normalizes to (a plain string for REG_SZ, the decimal digits for REG_DWORD).
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct RegEntry {
    pub key: String,
    pub name: String,
    pub value: String,
    #[serde(rename = "type")]
    pub value_type: String,
}

impl RegEntry {
    /// Identity of an entry for set membership / live lookup: the HKCU-relative key + the value name.
    fn id(&self) -> (String, String) {
        let rel = self.key.strip_prefix(r"HKCU\").unwrap_or(&self.key).to_string();
        (rel, self.name.clone())
    }
}

/// Reconcile the launcher-managed HKCU entries (see the module doc). `state_dir` holds the last-applied JSON;
/// `view` is the WINEPREFIX root (its `user.reg` is the live hive); `wine`/`child_env` run `reg add`/`delete`.
pub fn update_user_reg(
    wine: &str,
    child_env: &ChildEnv,
    state_dir: &Path,
    view: &Path,
    desired: &[RegEntry],
) {
    let managed_path = state_dir.join(".propnix-userReg-managed.json");
    let last_applied: Vec<RegEntry> = std::fs::read(&managed_path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    let live = parse_user_reg(&view.join("user.reg"));

    let desired_ids: std::collections::HashSet<(String, String)> =
        desired.iter().map(RegEntry::id).collect();

    // The new last-applied = the desired set, plus any dropped key we FAIL to remove (so it's retried, never
    // orphaned). A dropped key the app has since changed is neither removed nor retained — we relinquish it.
    let mut new_last_applied: Vec<RegEntry> = desired.to_vec();

    // 1. PRUNE keys that left the desired set, but only where the live value still matches what we last wrote.
    for e in &last_applied {
        if desired_ids.contains(&e.id()) {
            continue; // still managed
        }
        if live_value(&live, e).as_deref() == Some(e.value.as_str()) {
            // Ours and untouched by the app → remove it. Keep tracking it only if the delete didn't take.
            if !reg_delete(wine, child_env, &e.key, &e.name) {
                new_last_applied.push(e.clone());
            }
        }
        // else: absent (already gone) or app-modified → nothing to do, and stop tracking it.
    }

    // 2. WRITE desired entries whose live value differs — skipping ones already correct (usually from the
    //    seeded base user.reg or a prior launch), so we don't needlessly rewrite the hive.
    for e in desired {
        if live_value(&live, e).as_deref() != Some(e.value.as_str()) {
            reg_add(wine, child_env, &e.key, &e.name, &e.value_type, &e.value);
        }
    }

    // 3. Persist the new last-applied ATOMICALLY (see the module doc), as the final commit of this launch.
    persist_atomic(&managed_path, &new_last_applied);
}

/// The live value for an entry, or None if the key/name isn't present in user.reg.
fn live_value(live: &BTreeMap<(String, String), String>, e: &RegEntry) -> Option<String> {
    live.get(&e.id()).cloned()
}

fn reg_add(wine: &str, env: &ChildEnv, key: &str, name: &str, reg_type: &str, data: &str) -> bool {
    run_reg(wine, env, &["reg", "add", key, "/v", name, "/t", reg_type, "/d", data, "/f"])
}

fn reg_delete(wine: &str, env: &ChildEnv, key: &str, name: &str) -> bool {
    run_reg(wine, env, &["reg", "delete", key, "/v", name, "/f"])
}

fn run_reg(wine: &str, env: &ChildEnv, args: &[&str]) -> bool {
    let mut cmd = Command::new(wine);
    cmd.args(args).stdout(Stdio::null()).stderr(Stdio::null());
    env.apply(&mut cmd);
    matches!(cmd.status(), Ok(s) if s.success())
}

/// Parse a wine `user.reg` hive into `(HKCU-relative key, value name) → normalized value`. Section headers
/// (`[Foo\\Bar] <timestamp>`) carry escaped backslashes, which we unescape to a single `\` to match the
/// `RegEntry::id` form; values are normalized to `reg add /d` form (REG_SZ unquoted, REG_DWORD as decimal).
/// A missing/unreadable file yields an empty map (a fresh prefix — nothing live yet).
fn parse_user_reg(path: &Path) -> BTreeMap<(String, String), String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return BTreeMap::new(),
    };
    let mut map = BTreeMap::new();
    let mut section = String::new();
    for line in text.lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix('[') {
            if let Some(end) = rest.find(']') {
                section = rest[..end].replace("\\\\", "\\"); // unescape \\ → \
            }
        } else if l.starts_with('"') {
            if let Some((name_part, val_part)) = l.split_once('=') {
                let name = unquote(name_part.trim());
                map.insert((section.clone(), name), parse_reg_value(val_part.trim()));
            }
        }
    }
    map
}

/// Normalize a user.reg value token to the `reg add /d` form: REG_DWORD hex → decimal, REG_SZ → unquoted;
/// anything else is passed through verbatim (we only manage SZ/DWORD, so a compare against those is exact).
fn parse_reg_value(v: &str) -> String {
    if let Some(hex) = v.strip_prefix("dword:") {
        u32::from_str_radix(hex.trim(), 16)
            .map(|n| n.to_string())
            .unwrap_or_else(|_| v.to_string())
    } else if v.starts_with('"') {
        unquote(v)
    } else {
        v.to_string()
    }
}

/// Strip the surrounding quotes of a wine reg string token and unescape `\\`→`\` and `\"`→`"`.
fn unquote(s: &str) -> String {
    let inner = s.strip_prefix('"').and_then(|s| s.strip_suffix('"')).unwrap_or(s);
    inner.replace("\\\\", "\\").replace("\\\"", "\"")
}

/// Persist `entries` to `path` by ATOMIC REPLACE: write a temp file, fsync it, rename over the target, then
/// fsync the directory so the rename is durable. `rename(2)` is atomic, so a crash can never leave a torn
/// file — the reader sees either the whole previous set or the whole new one. Best-effort (a write failure
/// just means the next launch re-derives from the stale last-applied — still safe, since the prune is guarded).
fn persist_atomic(path: &Path, entries: &[RegEntry]) {
    let Ok(json) = serde_json::to_vec(entries) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    let ok = (|| -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(&json)?;
        f.sync_all()
    })()
    .is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    if std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    if let Some(dir) = path.parent() {
        if let Ok(d) = std::fs::File::open(dir) {
            let _ = d.sync_all();
        }
    }
}
