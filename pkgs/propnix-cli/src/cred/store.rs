//! The on-disk credential store. Layout (default root `/var/lib/propnix`, overridable via `PROPNIX_CRED_DIR`
//! for testing):
//!
//!   <root>/credentials.toml                       # the fetcher's pointer: `credentialDir = "/propnix"`
//!   <root>/<type>/<username>/<token_filename>      # e.g. gog/alice/galaxy_tokens.json
//!
//! `<root>` is bound into the Nix build sandbox at `/propnix`, so the fetcher reads `/propnix/credentials.toml`
//! and `/propnix/gog/*/galaxy_tokens.json`. Token files are OWNED BY THE USER WHO CREATED THEM and
//! group-owned by the build group (`$PROPNIX_BUILD_GROUP`, default `nixbld`), mode 0640: the sandbox builder
//! reads them via the group, and the owner reads them without any privilege — which is what lets
//! `propnix pin` refresh a hash without sudo. Leaving them root-owned would have meant every re-pin needed
//! root just to read a token it had already been granted. Dirs are 0755 (their names aren't secret).
//! (An older propnix DID write tokens root-owned; the first read that fails on one converges it back onto
//! this contract automatically — see `repair_unreadable_token` — instead of asking for a manual chown.)
//!
//! Writes/removes touch a system dir, so they sudo-escalate when the invoking user can't write the store —
//! while the interactive login itself runs unprivileged (the browser). A GROUP-MANAGED store needs no
//! escalation at all: the NixOS module makes the store dirs setgid + group-writable by a humans-only group
//! (`propnix`) while the tokens carry a wider group that also contains the build users (`propnix-fetch`), so
//! a member can add and remove credentials while a build can still only read them. `make_dir` detects that
//! layout from the parent's setgid bit and leaves existing dirs untouched, which is what keeps the
//! unprivileged path from tripping over a root-owned store root.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct CredStore {
    root: PathBuf,
    /// The group asked for by `$PROPNIX_BUILD_GROUP` (or the `nixbld` default) — kept for diagnostics.
    build_group: String,
    /// …that name resolved against the host's groups, so a store write can never fail on an `install -g` for
    /// a group nobody created. `None` = no suitable group exists (a single-user Nix has no `nixbld`), in
    /// which case token files simply keep the creator's primary group.
    file_group: Option<String>,
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
        // Resolve now: the NixOS module points this at `propnix-fetch`, but the variable outlives the module
        // in an already-open login session, and a host may have no `nixbld` either.
        let file_group = resolve_file_group(&build_group);
        CredStore {
            root,
            build_group,
            file_group,
        }
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

    /// Is this account DECLARED in the host's configuration rather than added with `cred add`?
    ///
    /// The NixOS module records what it manages in a manifest beside the store (`<root>-declarative-\
    /// credentials`, one store-relative token path per line, world-readable), which it also uses to prune a
    /// credential dropped from the config. Reading it is exact, where guessing from ownership would only be a
    /// proxy. No manifest (a store nothing declares, or a non-NixOS host) means nothing is declarative.
    pub fn is_declarative(&self, type_name: &str, username: &str) -> bool {
        let prefix = format!("{type_name}/{username}/");
        let manifest = PathBuf::from(format!(
            "{}-declarative-credentials",
            self.root.to_string_lossy().trim_end_matches('/')
        ));
        std::fs::read_to_string(manifest)
            .map(|s| s.lines().any(|l| l.starts_with(&prefix)))
            .unwrap_or(false)
    }

    /// Find the (type, dir) of a stored account by username. `type_filter` (from `--type`) restricts the
    /// search to one account type — needed to disambiguate the SAME username under multiple backends (e.g. a
    /// GOG `alice` and a Steam `alice`). Err if none match, or if >1 match (only possible without a filter).
    pub fn find(&self, username: &str, type_filter: Option<&str>) -> Result<(String, PathBuf), String> {
        let matches: Vec<(String, PathBuf)> = self
            .list()
            .into_iter()
            .filter(|t| type_filter.is_none_or(|tf| t.type_name == tf))
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

    /// Persist a minted credential at `<root>/<type>/<username>/<filename>` (token 0640, owner = the
    /// invoking user, group = build group), creating whatever dirs are missing on the way. Escalates via
    /// sudo when needed — but the result is owned by the user, not by root.
    pub fn put(
        &self,
        type_name: &str,
        username: &str,
        filename: &str,
        token: &[u8],
    ) -> Result<(), String> {
        self.note_group_fallback();
        // Stage the token to a private user temp first, then install it into the store.
        let tmp = self.stage_temp(token)?;
        let acct_dir = self.root.join(type_name).join(username);
        let dest = acct_dir.join(filename);

        let owner = self.owner_uid();
        self.make_dir(&self.root)?;
        self.make_dir(&self.root.join(type_name))?;
        self.make_dir(&acct_dir)?;
        let tmp_s = tmp.to_string_lossy();
        let dest_s = dest.to_string_lossy();
        let mut args: Vec<&str> = vec!["-m", "0640", "-o", &owner];
        args.extend(self.group_args());
        args.push(&tmp_s);
        args.push(&dest_s);
        self.priv_run("install", &args)?;
        let _ = std::fs::remove_file(&tmp);
        self.ensure_pointer()?;
        Ok(())
    }

    /// Create one store directory IF IT IS MISSING, and otherwise leave it exactly as it is. Never adjusting
    /// an existing directory is what lets the whole `cred add` run unprivileged: the NixOS module owns the
    /// store root (root-owned, group-writable), and chowning that as a plain user is EPERM even though
    /// writing *inside* it is allowed.
    ///
    /// A new dir inherits the parent's setgid group when the parent has one — that is how it picks up the
    /// module's dir group, which is deliberately NOT the group the tokens carry (a build user is in the
    /// latter, so group-writing anything to it would hand builds the store). Under a setgid parent the dir is
    /// group-writable too, so any member of that group can later `cred rm` the account; without one, the
    /// historical 0755 owner-only layout is kept.
    fn make_dir(&self, dir: &Path) -> Result<(), String> {
        if dir.is_dir() {
            return Ok(());
        }
        let owner = self.owner_uid();
        let path = dir.to_string_lossy();

        // A plain store: the historical owner-only layout, group set explicitly.
        if !dir.parent().is_some_and(is_setgid) {
            let mut args: Vec<&str> = vec!["-d", "-m", "0755", "-o", &owner];
            args.extend(self.group_args());
            args.push(&path);
            return self.priv_run("install", &args);
        }

        // A group-managed store. mkdir inherits the parent's group either way; the mode we ask for is only
        // about who may manage the account LATER, so carrying the setgid bit down is a nicety, not the point
        // — and setting it is a privileged operation on some filesystems (ZFS returns EPERM for an
        // unprivileged setgid chmod inside a user namespace instead of dropping the bit). Fall back to plain
        // group-write rather than failing the whole `cred add` over it.
        let install_d = |mode: &str| {
            self.priv_run("install", &["-d", "-m", mode, "-o", &owner, &path])
        };
        install_d("2775").or_else(|_| install_d("0775"))
    }

    /// `["-g", <group>]` for an `install` call, or nothing when no configured group exists on this host —
    /// the file then keeps the creator's primary group, which is all that a single-user Nix (builds run as
    /// you, no `nixbld`) needs.
    fn group_args(&self) -> Vec<&str> {
        match &self.file_group {
            Some(g) => vec!["-g", g],
            None => vec![],
        }
    }

    /// Say so, once, when the configured build group isn't the one being used — most likely a login session
    /// still exporting `PROPNIX_BUILD_GROUP` from a NixOS generation that no longer defines that group.
    fn note_group_fallback(&self) {
        if self.file_group.as_deref() == Some(self.build_group.as_str()) {
            return;
        }
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| match &self.file_group {
            Some(g) => eprintln!(
                "propnix: group '{}' does not exist here — storing credentials with group '{g}' instead",
                self.build_group
            ),
            None => eprintln!(
                "propnix: group '{}' does not exist here — storing credentials with your own primary group \
                 (fine for a single-user Nix; a multi-user daemon build reads them via its build group)",
                self.build_group
            ),
        });
    }

    /// Remove a stored account, disambiguated by `type_filter` (`--type`) when the username is not unique.
    /// Escalates via sudo when needed. Returns the removed account's type.
    pub fn remove(&self, username: &str, type_filter: Option<&str>) -> Result<String, String> {
        let (type_name, dir) = self.find(username, type_filter)?;
        // A declared credential belongs to the host's configuration: deleting the files here would only have
        // them restored at the next activation (and the module keeps the account dir root-owned so the
        // unprivileged path can't even try). Point at the config instead of failing on permissions.
        if self.is_declarative(&type_name, username) {
            return Err(format!(
                "{type_name} credential '{username}' is declarative — it is materialized from your NixOS \
                 configuration, so removing it here would come back at the next activation.\n  \
                 Remove it from services.propnix.credentials.{type_name}.{username} (and the secret it \
                 points at, e.g. sops.secrets) and rebuild."
            ));
        }
        // Not declared, but still not ours to delete: a store the module manages is group-writable, so `rm`
        // needs no sudo — say what is wrong rather than leaking `rm: Permission denied`.
        if !self.needs_sudo() && !is_root() && !writable(&dir) {
            return Err(format!(
                "{type_name} credential '{username}' is not writable by you ({}).\n  \
                 Retry as its owner, or with: sudo propnix cred rm --type {type_name} {username}",
                dir.display()
            ));
        }
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
        let owner = self.owner_uid();
        let tmp_s = tmp.to_string_lossy();
        let ptr_s = ptr.to_string_lossy();
        let mut args: Vec<&str> = vec!["-m", "0644", "-o", &owner];
        args.extend(self.group_args());
        args.push(&tmp_s);
        args.push(&ptr_s);
        self.priv_run("install", &args)?;
        let _ = std::fs::remove_file(&tmp);
        Ok(())
    }

    /// Write bytes to a fresh 0600 temp file owned by the invoking user (never world/group readable while it
    /// briefly holds the token). Returns its path.
    ///
    /// EXCLUSIVE CREATE, UNPREDICTABLE NAME. With `XDG_RUNTIME_DIR` unset this lands in the shared
    /// `/tmp`, and the old pid-only name plus a plain `O_CREAT` let any local user pre-create the path —
    /// or point a symlink at one of their own files — and then read the freshly written token out of it.
    /// `create_new` (O_CREAT|O_EXCL) refuses ANY pre-existing path, symlink included, and the nanosecond
    /// component means a retry after a genuine collision picks a different name.
    fn stage_temp(&self, bytes: &[u8]) -> Result<PathBuf, String> {
        let base = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        stage_temp_in(&base, bytes)
    }
}

/// The staging write itself, with the directory passed in so a test can exercise it without mutating
/// the process environment.
fn stage_temp_in(base: &Path, bytes: &[u8]) -> Result<PathBuf, String> {
    use std::io::Write;
    let mut last = String::new();
    for attempt in 0..64u32 {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        let path = base.join(format!(
            "propnix-cred-{}-{nonce:09}-{attempt}.tmp",
            std::process::id()
        ));
        match open_private(&path) {
            Ok(mut f) => {
                f.write_all(bytes)
                    .map_err(|e| format!("writing {}: {e}", path.display()))?;
                return Ok(path);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                last = format!("{} already exists", path.display());
            }
            Err(e) => return Err(format!("creating {}: {e}", path.display())),
        }
    }
    Err(format!(
        "could not create a private staging file under {} ({last}) — something is creating them \
         faster than we can pick names, which is not normal",
        base.display()
    ))
}

impl CredStore {

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

    /// The uid that should own the store: the human running the command, even when the write itself is
    /// escalated. Under `sudo propnix …` our own uid is 0, so honour SUDO_UID; otherwise we are already
    /// the user and sudo is only spawned for the individual `install` calls.
    fn owner_uid(&self) -> String {
        invoking_uid()
    }
}

/// The human running the command, even under `sudo propnix …` (honour SUDO_UID).
fn invoking_uid() -> String {
    std::env::var("SUDO_UID")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or_else(|| unsafe { libc::getuid() })
        .to_string()
}

/// Make a token file the current user was DENIED reading readable again, by converging it onto the store
/// contract: owner = the invoking user, group = the resolved file group, mode 0640. This is the one-off
/// repair for stores created by an older propnix, which wrote tokens root-owned — the issue instructions
/// used to ask for a manual `sudo chown` instead. Escalates with sudo exactly like store writes do.
///
/// A DECLARATIVE token is refused: the NixOS module keeps those root-owned on purpose (humans read them
/// via the `propnix-fetch` group), so a denied read there means missing group membership, and a chown
/// would only be undone by the next activation.
pub fn repair_unreadable_token(root: &Path, token: &Path) -> Result<(), String> {
    if declared_token(root, token) {
        return Err(format!(
            "{} is declarative and readable only via the `propnix-fetch` group — add yourself to \
             services.propnix.allowedUsers (or users.users.<you>.extraGroups = [ \"propnix\" ]), rebuild, \
             and re-log-in so the membership takes effect",
            token.display()
        ));
    }
    let uid = invoking_uid();
    let spec = match resolve_file_group(
        &std::env::var("PROPNIX_BUILD_GROUP").unwrap_or_else(|_| "nixbld".to_string()),
    ) {
        Some(g) => format!("{uid}:{g}"),
        None => uid,
    };
    let path = token.to_string_lossy();
    eprintln!(
        "propnix: {path} is not readable by you — the store predates user-ownership; converging it with \
         a one-off `chown {spec}` (this may ask for your sudo password)"
    );
    let run = |program: &str, args: &[&str]| -> Result<(), String> {
        let (prog, full): (&str, Vec<&str>) = if is_root() {
            (program, args.to_vec())
        } else {
            let mut v = vec![program];
            v.extend_from_slice(args);
            ("sudo", v)
        };
        match Command::new(prog).args(&full).status() {
            Ok(s) if s.success() => Ok(()),
            Ok(s) => Err(format!("`{prog} {}` failed ({s})", full.join(" "))),
            Err(e) => Err(format!("running {prog}: {e}")),
        }
    };
    run("chown", &[&spec, &path])?;
    // The contract mode, best-effort: an old token is normally 0640 already, and owner-readability —
    // checked below — is what actually matters.
    let _ = run("chmod", &["0640", &path]);
    if !readable(token) {
        return Err(format!(
            "{path} is still not readable after the repair; fix it by hand with: \
             sudo chown {spec} {path} && sudo chmod 0640 {path}"
        ));
    }
    Ok(())
}

/// Is this exact token path one the NixOS module declares — a line of the manifest beside the store?
/// (`CredStore::is_declarative` answers the same question per ACCOUNT; this is the per-file form the
/// repair path needs.)
fn declared_token(root: &Path, token: &Path) -> bool {
    let Ok(rel) = token.strip_prefix(root) else {
        return false;
    };
    let rel = rel.to_string_lossy();
    let manifest = PathBuf::from(format!(
        "{}-declarative-credentials",
        root.to_string_lossy().trim_end_matches('/')
    ));
    std::fs::read_to_string(manifest)
        .map(|s| s.lines().any(|l| l == rel))
        .unwrap_or(false)
}

/// Can the current user read `path`?
fn readable(path: &Path) -> bool {
    let Ok(c) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    unsafe { libc::access(c.as_ptr(), libc::R_OK) == 0 }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn store_at(root: &Path) -> CredStore {
        // A numeric gid is always a valid `install -g`, and our own is always one we may chown to.
        let gid = unsafe { libc::getgid() }.to_string();
        CredStore {
            root: root.to_path_buf(),
            build_group: gid.clone(),
            file_group: Some(gid),
        }
    }

    fn tmp_root(tag: &str) -> PathBuf {
        let mut d = std::env::temp_dir();
        d.push(format!(
            "propnix-store-{}-{}-{:?}",
            tag,
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Make `path` look like the NixOS module's store root, reporting whether the environment allowed it: an
    /// unprivileged setgid chmod is refused on some filesystems (ZFS inside the Nix build sandbox's user
    /// namespace EPERMs instead of dropping the bit), and with no setgid parent there is no group-managed
    /// store to exercise. Tests that need one skip rather than fail there.
    fn make_group_managed(path: &Path) -> bool {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o2775)).is_ok()
            && is_setgid(path)
    }

    fn mode_of(p: &Path) -> u32 {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(p).unwrap().mode() & 0o7777
    }

    fn gid_of(p: &Path) -> u32 {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(p).unwrap().gid()
    }

    #[test]
    fn make_dir_creates_owner_only_dirs_by_default() {
        let root = tmp_root("plain");
        let store = store_at(&root);
        let d = root.join("gog");
        store.make_dir(&d).unwrap();
        assert_eq!(mode_of(&d), 0o755, "a plain store keeps the owner-only layout");
    }

    #[test]
    fn make_dir_inherits_group_management_from_a_setgid_parent() {
        // What the NixOS module's store root looks like: setgid, group-writable.
        let root = tmp_root("setgid");
        if !make_group_managed(&root) {
            eprintln!("skipped: this filesystem/namespace won't take an unprivileged setgid dir");
            return;
        }
        let store = store_at(&root);

        let type_dir = root.join("gog");
        store.make_dir(&type_dir).unwrap();
        assert_eq!(
            mode_of(&type_dir),
            0o2775,
            "a child of a setgid store dir must stay group-writable + setgid, so the next member \
             of the group can add or remove an account without sudo"
        );
        assert_eq!(
            gid_of(&type_dir),
            gid_of(&root),
            "the group must be INHERITED from the parent, never set to the token group"
        );

        // …and the inheritance carries down another level (type dir → account dir).
        let acct = type_dir.join("alice");
        store.make_dir(&acct).unwrap();
        assert_eq!(mode_of(&acct), 0o2775);
        assert_eq!(gid_of(&acct), gid_of(&root));
    }

    #[test]
    fn an_absent_configured_group_falls_back_instead_of_failing() {
        // `install -g` errors out on an unknown group, so a stale PROPNIX_BUILD_GROUP (a login session from a
        // generation that still had the module) must never reach it.
        let bogus = "propnix-fetch-does-not-exist-here";
        let got = resolve_file_group(bogus);
        assert_ne!(got.as_deref(), Some(bogus), "must not use a nonexistent group");
        assert!(
            got.as_deref().is_none_or(group_exists),
            "whatever it resolves to must actually exist, got {got:?}"
        );
        if group_exists("nixbld") {
            assert_eq!(
                got.as_deref(),
                Some("nixbld"),
                "with no module-provided group, the historical nixbld layout is the fallback"
            );
            assert_eq!(resolve_file_group("nixbld").as_deref(), Some("nixbld"));
        }
    }

    #[test]
    fn put_writes_the_plain_layout_when_no_module_manages_the_store() {
        // A store with no setgid root — i.e. no NixOS module: dirs 0755, token 0640, everything ours.
        let root = tmp_root("plain-put");
        let store = store_at(&root);
        store
            .put("gog", "alice", "galaxy_tokens.json", b"{\"access_token\":\"x\"}")
            .unwrap();

        let acct = root.join("gog").join("alice");
        assert_eq!(mode_of(&root.join("gog")), 0o755);
        assert_eq!(mode_of(&acct), 0o755);
        assert_eq!(mode_of(&acct.join("galaxy_tokens.json")), 0o640);
        assert_eq!(
            std::fs::read_to_string(acct.join("galaxy_tokens.json")).unwrap(),
            "{\"access_token\":\"x\"}"
        );
        // …and the fetcher pointer is written alongside it.
        assert_eq!(mode_of(&root.join("credentials.toml")), 0o644);
        assert!(
            std::fs::read_to_string(root.join("credentials.toml"))
                .unwrap()
                .contains("credentialDir = \"/propnix\""),
        );
    }

    #[test]
    fn declarative_accounts_are_read_from_the_modules_manifest() {
        let root = tmp_root("manifest");
        let store = store_at(&root);
        assert!(
            !store.is_declarative("gog", "alice"),
            "no manifest → nothing is declarative"
        );

        // What the NixOS module writes beside the store, listing only what IT manages.
        std::fs::write(
            PathBuf::from(format!("{}-declarative-credentials", root.display())),
            "gog/alice/galaxy_tokens.json\nsteam/bob/depotdownloader-store.tar\n",
        )
        .unwrap();
        assert!(store.is_declarative("gog", "alice"));
        assert!(store.is_declarative("steam", "bob"));
        assert!(
            !store.is_declarative("gog", "dave"),
            "an imperatively added account must not be flagged"
        );
        assert!(
            !store.is_declarative("gog", "ali"),
            "the match is on the whole <type>/<username>/ path, not a name prefix"
        );
        assert!(!store.is_declarative("steam", "alice"), "type must match too");
    }

    #[test]
    fn removing_a_declarative_credential_names_the_config_option() {
        let root = tmp_root("rm-declarative");
        let store = store_at(&root);
        let acct = root.join("gog").join("alice");
        std::fs::create_dir_all(&acct).unwrap();
        std::fs::write(acct.join("galaxy_tokens.json"), "{}").unwrap();
        std::fs::write(
            PathBuf::from(format!("{}-declarative-credentials", root.display())),
            "gog/alice/galaxy_tokens.json\n",
        )
        .unwrap();

        let err = store.remove("alice", Some("gog")).unwrap_err();
        assert!(err.contains("declarative"), "got: {err}");
        assert!(
            err.contains("services.propnix.credentials.gog.alice"),
            "the error must name the option to edit; got: {err}"
        );
        assert!(
            acct.join("galaxy_tokens.json").exists(),
            "the refusal must not have deleted anything"
        );
    }

    #[test]
    fn declared_token_matches_exact_manifest_lines() {
        let root = tmp_root("declared-token");
        std::fs::write(
            PathBuf::from(format!("{}-declarative-credentials", root.display())),
            "gog/alice/galaxy_tokens.json\n",
        )
        .unwrap();
        assert!(declared_token(&root, &root.join("gog/alice/galaxy_tokens.json")));
        // The match is the whole line, not a prefix, and only for paths under this root.
        assert!(!declared_token(&root, &root.join("gog/alice/galaxy_tokens.json.bak")));
        assert!(!declared_token(&root, &root.join("gog/alice")));
        assert!(!declared_token(&root, Path::new("/elsewhere/gog/alice/galaxy_tokens.json")));
    }

    #[test]
    fn repair_refuses_a_declarative_token_and_names_the_fix() {
        // A declared token is root-owned ON PURPOSE (read via the propnix-fetch group), so the repair
        // must refuse — before spawning any command — and point at group membership instead.
        let root = tmp_root("repair-declarative");
        let token = root.join("gog/alice/galaxy_tokens.json");
        std::fs::write(
            PathBuf::from(format!("{}-declarative-credentials", root.display())),
            "gog/alice/galaxy_tokens.json\n",
        )
        .unwrap();
        let err = repair_unreadable_token(&root, &token).unwrap_err();
        assert!(err.contains("declarative"), "got: {err}");
        assert!(err.contains("allowedUsers"), "must name the option to edit; got: {err}");
    }

    #[test]
    fn staging_a_token_never_opens_a_path_somebody_else_made() {
        // The attack this closes: with XDG_RUNTIME_DIR unset the staging file lands in a shared /tmp,
        // and a predictable name plus a non-exclusive create let a local user pre-place a symlink and
        // capture the token. `open_private` must refuse ANY pre-existing path.
        let root = tmp_root("stage");
        let victim = root.join("victim");
        std::fs::write(&victim, b"").unwrap();
        let err = open_private(&victim).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
        let link = root.join("link");
        std::os::unix::fs::symlink(&victim, &link).unwrap();
        let err = open_private(&link).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists, "a symlink must not be followed");
        assert_eq!(std::fs::read(&victim).unwrap(), b"", "the target must be untouched");

        // …and the happy path still produces a 0600 file with the bytes in it, twice in a row without
        // colliding with itself.
        let a = stage_temp_in(&root, b"tok-a").unwrap();
        let b = stage_temp_in(&root, b"tok-b").unwrap();
        assert_ne!(a, b, "two stagings in one process must not reuse a name");
        assert_eq!(mode_of(&a), 0o600);
        assert_eq!(std::fs::read(&a).unwrap(), b"tok-a");
        assert_eq!(std::fs::read(&b).unwrap(), b"tok-b");
    }

    #[test]
    fn make_dir_leaves_an_existing_dir_alone() {
        // The module owns the store root (root-owned, group-writable); adjusting it as a plain user would be
        // EPERM, so an existing dir must never be touched.
        let root = tmp_root("existing");
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o0705)).unwrap();
        let store = store_at(&root);
        store.make_dir(&root).unwrap();
        assert_eq!(mode_of(&root), 0o0705, "an existing dir keeps its mode");
    }
}

/// The group token files should carry: the requested one if it exists, else nix's own default build group,
/// else none at all. That fallback chain is what keeps `cred add` working on a host where the NixOS module
/// (and so the `propnix-fetch` group) was never installed or has since been removed — there it lands back on
/// the historical `nixbld` layout.
fn resolve_file_group(requested: &str) -> Option<String> {
    [requested, "nixbld"]
        .into_iter()
        .find(|g| group_exists(g))
        .map(str::to_string)
}

/// Is `name` a group on this host? `install -g` fails outright on an unknown group, so every group name is
/// checked before it is used — the store must still be writable on a host that never had the NixOS module
/// (or, for `nixbld`, on a single-user Nix that has no build users at all).
fn group_exists(name: &str) -> bool {
    let Ok(c) = CString::new(name) else {
        return false;
    };
    // getgrnam() yields NULL for an unknown group; we are single-threaded on this path.
    !unsafe { libc::getgrnam(c.as_ptr()) }.is_null()
}

/// Does `path` carry the setgid bit? On a store directory that is the marker that the store is under GROUP
/// management (the NixOS module's layout): a child created inside it inherits the dir group — which is the
/// humans-only group, not the wider group the tokens carry — and stays group-writable, so any member can
/// later add or remove an account without sudo.
fn is_setgid(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path)
        .map(|m| m.mode() & 0o2000 != 0)
        .unwrap_or(false)
}

/// Create a file readable+writable only by the owner (0600), failing if the path already exists in ANY
/// form. The exclusivity is the security property, not a nicety: without it a pre-created file (or a
/// symlink to somebody else's) would be opened and written with the token. Returns the raw io::Error so
/// the caller can tell a collision from a real failure.
fn open_private(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true) // O_CREAT | O_EXCL
        .mode(0o600)
        .open(path)
}
