//! Steam credential provider. Unlike GOG (a browser OAuth code-paste), Steam auth is Steam Guard 2FA, which
//! DepotDownloader (SteamKit2) already handles well — so `propnix cred add steam` DRIVES DepotDownloader
//! through a one-time interactive login and captures the reusable credential it mints.
//!
//! DepotDownloader persists the login as a protobuf `account.config` (its AccountSettingsStore: a
//! username→JWT-refresh-token map + Steam Guard machine data) inside .NET Isolated Storage under $HOME — a
//! hashed path derived from the DepotDownloader assembly. We therefore store the credential as a TAR of that
//! file *with its path preserved*, so the fetcher can replay it verbatim under its own $HOME. Because the
//! packaged DepotDownloader is pinned, the isolated-storage path is identical at `cred add` and at fetch time.

use crate::cred::provider::{Credential, Provider};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Steam;

impl Provider for Steam {
    fn type_name(&self) -> &'static str {
        "steam"
    }
    fn display_name(&self) -> &'static str {
        "Steam"
    }
    fn token_filename(&self) -> &'static str {
        // A tar of DepotDownloader's isolated-storage account.config (path-preserving), not a bare token —
        // see the module doc for why.
        "depotdownloader-store.tar"
    }

    fn login(&self) -> Result<Credential, String> {
        // 1. Steam username (the label + the -username DepotDownloader logs in with).
        eprint!("Steam username: ");
        std::io::stderr().flush().ok();
        let mut user = String::new();
        std::io::stdin()
            .read_line(&mut user)
            .map_err(|e| format!("reading input: {e}"))?;
        let user = user.trim().to_string();
        if user.is_empty() {
            return Err("no Steam username entered".into());
        }

        // 2. Scratch dirs so account.config lands somewhere we own and can capture. DepotDownloader stores it
        //    via .NET Isolated Storage, whose root is `$XDG_DATA_HOME/IsolatedStorage` (NOT `$HOME`-derived
        //    when XDG_DATA_HOME is set) — so we MUST redirect XDG_DATA_HOME, else it lands in the real user
        //    home and we never find it. Set HOME too for good measure. `dl` is the throwaway download target.
        let base = std::env::temp_dir().join(format!("propnix-steam-login-{}", std::process::id()));
        let home = base.join("home");
        let data = base.join("data"); // → $XDG_DATA_HOME; IsolatedStorage/…/account.config lands under here
        let dl = base.join("dl");
        for d in [&home, &data, &dl] {
            std::fs::create_dir_all(d).map_err(|e| format!("mkdir {}: {e}", d.display()))?;
        }
        // Best-effort cleanup guard: remove the scratch tree however we leave this function.
        let _guard = CleanupDir(base.clone());

        // 3. Drive the interactive login. DepotDownloader prompts for the Steam Guard code / mobile confirm on
        //    its own (inherited stdio); -remember-password makes it persist the JWT refresh token. We log in by
        //    fetching the tiny, universally-accessible Steamworks example app (480) purely to run auth to the
        //    point the token is saved — the download is discarded with the scratch dir.
        eprintln!(
            "propnix: logging in to Steam via DepotDownloader — follow its Steam Guard prompt.\n  \
             This is a ONE-TIME 2FA; the reusable token is then stored (like the GOG login)."
        );
        // The refresh token is persisted to account.config right after authentication, BEFORE the throwaway
        // app-480 download runs — so success is "account.config was written", not the exit code (the discarded
        // download can fail without meaning the login failed). We only hard-fail if DepotDownloader can't run.
        let _ = Command::new("DepotDownloader")
            .args([
                "-app",
                "480",
                "-username",
                &user,
                "-remember-password",
                "-dir",
            ])
            .arg(&dl)
            .env("HOME", &home)
            .env("XDG_DATA_HOME", &data)
            .status()
            .map_err(|e| format!("could not run DepotDownloader (is it on PATH?): {e}"))?;

        // 4. Capture account.config as a path-preserving tar (relative to $XDG_DATA_HOME). Its presence is the
        //    proof the login succeeded and the reusable token was stored.
        let cfg = find_file(&data, "account.config").ok_or_else(|| {
            "login did not persist a token (no account.config was written) — wrong password, declined/expired \
             Steam Guard, or cancelled. Re-run `propnix cred add steam` and complete the Steam Guard step."
                .to_string()
        })?;
        let rel = cfg
            .strip_prefix(&data)
            .map_err(|_| "account.config landed outside the scratch XDG_DATA_HOME".to_string())?;
        let out = Command::new("tar")
            .arg("-C")
            .arg(&data)
            .arg("-cf")
            .arg("-")
            .arg(rel)
            .output()
            .map_err(|e| format!("could not run tar to package the credential: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "tar failed packaging the credential: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }

        Ok(Credential {
            username: user,
            token: out.stdout,
        })
    }
}

/// Recursively find the first file named `name` under `dir`.
fn find_file(dir: &Path, name: &str) -> Option<PathBuf> {
    let rd = std::fs::read_dir(dir).ok()?;
    for entry in rd.flatten() {
        let p = entry.path();
        match entry.file_type() {
            Ok(t) if t.is_dir() => {
                if let Some(found) = find_file(&p, name) {
                    return Some(found);
                }
            }
            Ok(t) if t.is_file()
                && p.file_name().map(|n| n == name).unwrap_or(false) => {
                    return Some(p);
                }
            _ => {}
        }
    }
    None
}

/// RAII best-effort cleanup of the scratch login dir.
struct CleanupDir(PathBuf);
impl Drop for CleanupDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
