//! The on-disk credential store. Layout (default root `/var/lib/propnix`, overridable via `PROPNIX_CRED_DIR`
//! for testing):
//!
//!   <root>/credentials.toml                       # the fetcher's pointer: `credentialDir = "/propnix"`
//!   <root>/<type>/<username>/<token_filename>      # e.g. gog/alice/galaxy_tokens.json
//!
//! `<root>` is bound into the Nix build sandbox at `/propnix`, so the fetcher reads `/propnix/credentials.toml`
//! and `/propnix/gog/*/galaxy_tokens.json`. Token files are group-owned by the build group (`nixbld`) and
//! mode 0640 so the sandbox builder can read them; dirs are 0755 (their names aren't secret) so a plain user
//! can `cred list` without privilege. Writes/removes touch a system dir, so they sudo-escalate when the
//! invoking user can't write the store — while the interactive login itself runs unprivileged (the browser).

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct CredStore {
    root: PathBuf,
    build_group: String,
}

/// One account type's stored accounts, for `cred list`.
pub struct TypeListing {
    pub type_name: String,
    pub usernames: Vec<String>,
}

impl CredStore {
    pub fn from_env() -> CredStore {
        let root = std::env::var_os("PROPNIX_CRED_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/var/lib/propnix"));
        let build_group =
            std::env::var("PROPNIX_BUILD_GROUP").unwrap_or_else(|_| "nixbld".to_string());
        CredStore { root, build_group }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Enumerate stored accounts grouped by type (each type = a subdir of the root, each account = a subdir
    /// holding the token file). Empty vec when the store doesn't exist yet.
    pub fn list(&self) -> Vec<TypeListing> {
        let mut out = Vec::new();
        let Ok(types) = std::fs::read_dir(&self.root) else {
            return out;
        };
        let mut types: Vec<_> = types.flatten().filter(|e| e.path().is_dir()).collect();
        types.sort_by_key(|e| e.file_name());
        for t in types {
            let mut usernames: Vec<String> = std::fs::read_dir(t.path())
                .into_iter()
                .flatten()
                .flatten()
                .filter(|e| e.path().is_dir())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect();
            usernames.sort();
            out.push(TypeListing {
                type_name: t.file_name().to_string_lossy().into_owned(),
                usernames,
            });
        }
        out
    }

    /// Find the (type, dir) of a stored account by username. `type_filter` (from `--type`) restricts the
    /// search to one account type — needed to disambiguate the SAME username under multiple backends (e.g. a
    /// GOG `alice` and a Steam `alice`). Err if none match, or if >1 match (only possible without a filter).
    pub fn find(&self, username: &str, type_filter: Option<&str>) -> Result<(String, PathBuf), String> {
        let matches: Vec<(String, PathBuf)> = self
            .list()
            .into_iter()
            .filter(|t| type_filter.map_or(true, |tf| t.type_name == tf))
            .flat_map(|t| {
                let ty = t.type_name.clone();
                t.usernames.into_iter().filter(|u| u == username).map(move |u| {
                    (ty.clone(), self.root.join(&ty).join(&u))
                })
            })
            .collect();
        match matches.len() {
            0 => Err(match type_filter {
                Some(tf) => format!("no {tf} credential found for username '{username}'"),
                None => format!("no credential found for username '{username}'"),
            }),
            1 => Ok(matches.into_iter().next().unwrap()),
            _ => {
                let types: Vec<String> = matches.iter().map(|(t, _)| t.clone()).collect();
                Err(format!(
                    "username '{username}' exists under multiple types ({}) — disambiguate with:\n  \
                     propnix cred rm --type <{}> {username}",
                    types.join(", "),
                    types.join("|")
                ))
            }
        }
    }

    /// Persist a minted credential at `<root>/<type>/<username>/<filename>` (token 0640, group = build group;
    /// dirs 0755), and ensure the fetcher pointer `credentials.toml` exists. Escalates via sudo when needed.
    pub fn put(
        &self,
        type_name: &str,
        username: &str,
        filename: &str,
        token: &[u8],
    ) -> Result<(), String> {
        // Stage the token to a private user temp first, then install it into the (root-owned) store.
        let tmp = self.stage_temp(token)?;
        let acct_dir = self.root.join(type_name).join(username);
        let dest = acct_dir.join(filename);

        let install_d = |d: &Path| -> Result<(), String> {
            self.priv_run(
                "install",
                &["-d", "-m", "0755", "-g", &self.build_group, &d.to_string_lossy()],
            )
        };
        install_d(&self.root)?;
        install_d(&self.root.join(type_name))?;
        install_d(&acct_dir)?;
        self.priv_run(
            "install",
            &[
                "-m",
                "0640",
                "-g",
                &self.build_group,
                &tmp.to_string_lossy(),
                &dest.to_string_lossy(),
            ],
        )?;
        let _ = std::fs::remove_file(&tmp);
        self.ensure_pointer()?;
        Ok(())
    }

    /// Remove a stored account, disambiguated by `type_filter` (`--type`) when the username is not unique.
    /// Escalates via sudo when needed. Returns the removed account's type.
    pub fn remove(&self, username: &str, type_filter: Option<&str>) -> Result<String, String> {
        let (type_name, dir) = self.find(username, type_filter)?;
        self.priv_run("rm", &["-rf", "--", &dir.to_string_lossy()])?;
        Ok(type_name)
    }

    /// Write the fetcher pointer `credentials.toml` (naming the in-sandbox root `/propnix`) if absent.
    fn ensure_pointer(&self) -> Result<(), String> {
        let ptr = self.root.join("credentials.toml");
        if ptr.exists() {
            return Ok(());
        }
        let body = "# propnix credential pointer — NAMES the in-sandbox credential root (bound at /propnix).\n\
                    # Contains NO secret; tokens live under <root>/<type>/<username>/ and never enter the store.\n\
                    credentialDir = \"/propnix\"\n";
        let tmp = self.stage_temp(body.as_bytes())?;
        self.priv_run(
            "install",
            &[
                "-m",
                "0644",
                "-g",
                &self.build_group,
                &tmp.to_string_lossy(),
                &ptr.to_string_lossy(),
            ],
        )?;
        let _ = std::fs::remove_file(&tmp);
        Ok(())
    }

    /// Write bytes to a fresh 0600 temp file owned by the invoking user (never world/group readable while it
    /// briefly holds the token). Returns its path.
    fn stage_temp(&self, bytes: &[u8]) -> Result<PathBuf, String> {
        use std::io::Write;
        let base = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        // A pid-suffixed name is unique enough for this short-lived staging file.
        let path = base.join(format!("propnix-cred-{}.tmp", std::process::id()));
        let mut f = open_private(&path)?;
        f.write_all(bytes).map_err(|e| format!("writing {}: {e}", path.display()))?;
        Ok(path)
    }

    /// Run a filesystem command, prefixing `sudo` when the store isn't writable by the current user (so the
    /// interactive login stays unprivileged and only the /var/lib write escalates).
    fn priv_run(&self, program: &str, args: &[&str]) -> Result<(), String> {
        let (prog, full_args): (&str, Vec<&str>) = if self.needs_sudo() {
            let mut v = vec![program];
            v.extend_from_slice(args);
            ("sudo", v)
        } else {
            (program, args.to_vec())
        };
        let status = Command::new(prog)
            .args(&full_args)
            .status()
            .map_err(|e| format!("running {prog}: {e}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("`{prog} {}` failed ({status})", args.join(" ")))
        }
    }

    fn needs_sudo(&self) -> bool {
        !is_root() && !writable(&self.root)
    }
}

fn is_root() -> bool {
    unsafe { libc::geteuid() == 0 }
}

/// Is the nearest existing ancestor of `path` writable by the current user? (Determines whether store writes
/// need sudo — creating `/var/lib/propnix` probes `/var/lib`.)
fn writable(path: &Path) -> bool {
    let mut p = path;
    loop {
        if p.exists() {
            let Ok(c) = CString::new(p.as_os_str().as_bytes()) else {
                return false;
            };
            return unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0;
        }
        match p.parent() {
            Some(par) if par != p => p = par,
            _ => return false,
        }
    }
}

/// Create/truncate a file readable+writable only by the owner (0600).
fn open_private(path: &Path) -> Result<std::fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("creating {}: {e}", path.display()))
}
