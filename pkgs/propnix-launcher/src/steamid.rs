//! Steam identity for the gbe_fork offline-entitlement shim: seat the SteamID64 of the account whose
//! credential the propnix store holds, so the emulated Steam client reports the OWNER — stable across
//! launches and equal to what a real Steam install would report — instead of gbe_fork's made-up-per-run
//! fallback (our per-launch views discard its self-generated ID, so on THIN a game that keys anything on
//! the SteamID sees a new identity every launch).
//!
//! HOW IT LANDS. gbe_fork reads `[user::general] account_steamid` from `configs.user.ini`, merged local
//! settings first (the baked `steam_settings/` tree, which deliberately ships NO identity — a store path
//! must not carry an account; see lib/builders/steam-offline-entitlement.nix) and the GLOBAL settings dir
//! second: `$XDG_DATA_HOME/GSE Saves/settings/` on Linux, `%APPDATA%\GSE Saves\settings\` on Windows.
//! Both resolve INSIDE the per-launch view, so the launcher writes the file there right before exec:
//! identity is injected per launch on the host, never baked into a package.
//!
//! WHERE THE ID COMES FROM. The credential store (`$PROPNIX_CRED_DIR`, default `/var/lib/propnix`) holds
//! the refresh-token JWTs `propnix cred add steam` captured, and a Steam JWT's `sub` claim IS the
//! SteamID64 (steam-vent logs in with exactly that field). The shared `propnix-steam-cred` crate decodes
//! the stored tar; only the ID leaves this module — the token itself is never exported to the game's
//! environment or filesystem.
//!
//! BEST-EFFORT, ALWAYS. A launch must never fail over identity: no store, an unreadable token (the
//! NixOS module keeps declarative tokens readable only via the propnix-fetch group), or a parse failure
//! all fall back to gbe_fork's own behavior, with a note under PROPNIX_DEBUG. `PROPNIX_STEAM_ACCOUNT`
//! (the same variable the pin tool honors) picks one of several stored accounts; otherwise the
//! first-by-name wins, mirroring the pin tool's deterministic try-order.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The prefix profile of wine's fixed propnix user (see emulators/wine-prefix-lower.nix — a hardcoded
/// constant there too), where CSIDL_APPDATA resolves: `<profile>/AppData/Roaming`.
pub const WINE_APPDATA: &str = "drive_c/users/propnix/AppData/Roaming";

/// The SteamID64 (and the account name it belongs to) of the stored Steam credential, or None with the
/// reason under PROPNIX_DEBUG. Never errors — see the module header.
pub fn resolve() -> Option<(String, u64)> {
    let cred_dir = std::env::var_os("PROPNIX_CRED_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/var/lib/propnix"));
    let debug = std::env::var_os("PROPNIX_DEBUG").is_some();
    let note = |msg: String| {
        if debug {
            eprintln!("propnix: steam identity: {msg}");
        }
    };

    // Sorted account name → token, across every stored tar. A tar this user cannot read is SKIPPED, not
    // repaired: the pin tool's sudo-escalated chown has no place in a game launch.
    let mut tokens: BTreeMap<String, String> = BTreeMap::new();
    for t in propnix_steam_cred::store_tars(&cred_dir) {
        match std::fs::File::open(&t) {
            Ok(f) => match propnix_steam_cred::login_tokens_in_tar(f) {
                Ok(pairs) => tokens.extend(pairs),
                Err(e) => note(format!("{}: {e}", t.display())),
            },
            Err(e) => note(format!("{}: {e}", t.display())),
        }
    }
    if tokens.is_empty() {
        note(format!(
            "no readable Steam credential under {} — leaving gbe_fork's own identity",
            cred_dir.display()
        ));
        return None;
    }

    // The same narrowing variable the pin tool takes. An account the store does not hold is worth a
    // NON-debug warning — the user explicitly asked for it — but still never blocks the launch.
    let (account, token) = match std::env::var("PROPNIX_STEAM_ACCOUNT") {
        Ok(w) if !w.is_empty() => match tokens.get_key_value(&w) {
            Some(kv) => kv,
            None => {
                let have: Vec<&str> = tokens.keys().map(|k| k.as_str()).collect();
                eprintln!(
                    "propnix: PROPNIX_STEAM_ACCOUNT={w:?} names no stored Steam account (stored: {}) \
                     — leaving gbe_fork's own identity",
                    have.join(", ")
                );
                return None;
            }
        },
        // First-by-name: deterministic, and the single-account store — the normal case — is unaffected.
        _ => tokens.iter().next().expect("checked non-empty"),
    };

    // An EXPIRED token still names its owner truthfully — identity outlives login validity, so unlike
    // the pin tool there is no expiry check here.
    match propnix_steam_cred::jwt_steam_id(token) {
        Some(id) => {
            note(format!("account {account:?} → {id}"));
            Some((account.clone(), id))
        }
        None => {
            note(format!("account {account:?}: token carries no readable SteamID"));
            None
        }
    }
}

/// Merge `account_steamid` into `<settings_dir>/configs.user.ini`, creating the path as needed and
/// preserving every other line: on wine the file lives in the PERSISTENT users overlay upper, where
/// gbe_fork saves its own keys (a generated account_name, …) — clobbering the file would erase them
/// every launch. Written via a sibling tempfile + rename so a crash mid-write cannot leave a torn file
/// for the next launch to read.
pub fn seat(settings_dir: &Path, steam_id: u64) -> std::io::Result<()> {
    std::fs::create_dir_all(settings_dir)?;
    let target = settings_dir.join("configs.user.ini");
    let existing = std::fs::read_to_string(&target).unwrap_or_default();
    let merged = set_ini_value(&existing, "user::general", "account_steamid", &steam_id.to_string());
    let tmp = settings_dir.join(".configs.user.ini.propnix");
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(merged.as_bytes())?;
    }
    std::fs::rename(&tmp, &target)
}

/// `contents` with `[section] key=value` set: the section's existing `key=` line replaced in place, or
/// the pair appended — to the section if present, else as a new section at the end. Everything else is
/// preserved byte-for-byte (gbe_fork owns this file's other keys). Deliberately line-level, not a full
/// INI model: the one consumer is gbe_fork's CSimpleIni, which reads `key=value` lines and `[section]`
/// headers and treats `#`/`;` as comments — all of which pass through untouched here.
fn set_ini_value(contents: &str, section: &str, key: &str, value: &str) -> String {
    let header = format!("[{section}]");
    let line = format!("{key}={value}");
    let mut out: Vec<String> = Vec::new();
    let mut in_section = false;
    let mut done = false;
    for l in contents.lines() {
        let t = l.trim();
        if t.starts_with('[') {
            // Leaving the target section without having found the key: insert before the next header.
            if in_section && !done {
                out.push(line.clone());
                done = true;
            }
            in_section = t == header;
        } else if in_section && !done {
            let is_key = t
                .split_once('=')
                .map(|(k, _)| k.trim() == key)
                .unwrap_or(false);
            if is_key {
                out.push(line.clone());
                done = true;
                continue;
            }
        }
        out.push(l.to_string());
    }
    if !done {
        if !in_section {
            out.push(header);
        }
        out.push(line);
    }
    let mut s = out.join("\n");
    s.push('\n');
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ini_merge_creates_replaces_and_preserves() {
        // Fresh file: section + key.
        assert_eq!(
            set_ini_value("", "user::general", "account_steamid", "76561198000000001"),
            "[user::general]\naccount_steamid=76561198000000001\n"
        );
        // gbe_fork's own keys survive; ours is REPLACED in place, not appended a second time.
        let theirs = "[user::general]\naccount_name=gse orca\naccount_steamid=111\n\n[user::saves]\nsaves_folder_name=GSE Saves\n";
        let got = set_ini_value(theirs, "user::general", "account_steamid", "222");
        assert_eq!(
            got,
            "[user::general]\naccount_name=gse orca\naccount_steamid=222\n\n[user::saves]\nsaves_folder_name=GSE Saves\n"
        );
        // Section present but key absent: inserted before the NEXT section, not at the file end.
        let sparse = "[user::general]\naccount_name=x\n[user::saves]\nsaves_folder_name=y\n";
        let got = set_ini_value(sparse, "user::general", "account_steamid", "3");
        assert_eq!(
            got,
            "[user::general]\naccount_name=x\naccount_steamid=3\n[user::saves]\nsaves_folder_name=y\n"
        );
        // Section absent entirely: appended as a new section.
        let other = "[main::connectivity]\noffline=1\n";
        let got = set_ini_value(other, "user::general", "account_steamid", "4");
        assert_eq!(got, "[main::connectivity]\noffline=1\n[user::general]\naccount_steamid=4\n");
        // Target section LAST in the file, key absent: appended inside it.
        let last = "[a]\nx=1\n[user::general]\naccount_name=x\n";
        let got = set_ini_value(last, "user::general", "account_steamid", "5");
        assert_eq!(got, "[a]\nx=1\n[user::general]\naccount_name=x\naccount_steamid=5\n");
    }

    #[test]
    fn seat_round_trips_on_disk() {
        let dir = std::env::temp_dir().join(format!(
            "propnix-steamid-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let settings = dir.join("GSE Saves").join("settings");
        seat(&settings, 76561198000000001).unwrap();
        // Idempotent, and a later launch with a different stored account REPLACES the id.
        seat(&settings, 76561198000000002).unwrap();
        let got = std::fs::read_to_string(settings.join("configs.user.ini")).unwrap();
        assert_eq!(got, "[user::general]\naccount_steamid=76561198000000002\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
