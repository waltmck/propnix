//! The on-disk credential store. Layout (default root `/var/lib/propnix`, overridable via `PROPNIX_CRED_DIR`
//! for testing):
//!
//!   <root>/credentials.toml                       # the fetcher's pointer: `credentialDir = "/propnix"`
//!   <root>/<type>/<username>/<token_filename>      # e.g. gog/alice/galaxy_tokens.json
//!
//! `<root>` is bound into the Nix build sandbox at `/propnix`, so the fetcher reads `/propnix/credentials.toml`
//! and `/propnix/gog/*/galaxy_tokens.json`. A token has EXACTLY TWO readers, and its permissions name them
//! both: `owner = the human who created it` (reads via the owner bits — which is what lets `propnix pin`
//! refresh a hash without sudo) and `group = the build-users group` (`$PROPNIX_BUILD_GROUP`, default
//! `nixbld` — reads via the group bits), mode 0640, never world-readable.
//!
//! Why group-OWNERSHIP and not a POSIX ACL: a sandboxed Nix build runs in a user namespace that keeps only
//! its single primary gid (`nixbld`) and drops every supplementary group, and — decisively on ZFS — the
//! kernel honors that primary gid through plain group-ownership bits but IGNORES a POSIX ACL group entry for
//! such a build. So the token must be group-owned by `nixbld`, not merely ACL-granted to it. (An earlier
//! iteration used an ACL; it silently failed to grant reads on ZFS.)
//!
//! Why that is possible unprivileged: a human is not a member of `nixbld` (and must not be — nix would pick
//! them to run builds as), so cannot `chgrp` a token into it. Instead the type directories (`steam/`,
//! `gog/`) are setgid `nixbld` and world-writable + sticky (the `/tmp` model), so any human creates their
//! account dir with no privilege and the account dir + token inherit the group for free. Not world-READABLE
//! despite the world-writable type dir: the account dir is 0750 (`other` cannot traverse in) and the token
//! is 0640. See `put` / `ensure_type_dir` / `ensure_account_dir`.
//!
//! Writes/removes touch a system dir, so they sudo-escalate when the invoking user can't write the store —
//! while the interactive login itself runs unprivileged (the browser). A store whose type dirs already exist
//! (the NixOS module pre-creates them, or a prior `cred add` did) needs no escalation: the type dir is
//! world-writable, so creating an account dir and a token beneath it is an ordinary unprivileged write.
//! `ensure_*` leave an existing dir untouched, which keeps the unprivileged path from tripping over the
//! root-owned store root.

use std::ffi::CString;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct CredStore {
    root: PathBuf,
    /// The group asked for by `$PROPNIX_BUILD_GROUP` (or the `nixbld` default) — kept for diagnostics. It
    /// is the BUILD-USERS group: the one a sandboxed builder runs as, and so the one that must own a token
    /// for the build to read it (see `put`).
    build_group: String,
    /// …that name resolved against the host's groups, so a store write can never fail on an `install -g` for
    /// a group nobody created. `None` = no suitable group exists (a single-user Nix has no `nixbld`), in
    /// which case token files simply keep the creator's primary group (which the builder — the same user —
    /// then reads as the owner).
    file_group: Option<String>,
}

/// One account type's stored accounts, for `cred list`.
pub struct TypeListing {
    pub type_name: String,
    pub usernames: Vec<String>,
}

/// Who may rewrite a stored account without sudo — the multi-user store's per-human isolation, reported
/// by `cred list`.
pub enum AccountAccess {
    /// The invoking user owns the account dir: writable (`cred rm`/refresh) without privilege.
    Mine,
    /// Someone else owns the account dir. Still READ by any build (group `nixbld`), not writable by you.
    /// `user` is their login name, or their raw uid when the host has no name for it (à la `ls -l`); the
    /// numeric `uid` is kept so the caller can special-case root (a sudo-created or module store), which
    /// should not read as "another user".
    Other { user: String, uid: u32 },
    /// No account directory to stat — ownership indeterminate (a flat legacy token, or a race).
    Unknown,
}

impl CredStore {
    pub fn from_env() -> CredStore {
        let root = std::env::var_os("PROPNIX_CRED_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/var/lib/propnix"));
        let build_group =
            std::env::var("PROPNIX_BUILD_GROUP").unwrap_or_else(|_| "nixbld".to_string());
        // Resolve now: the variable outlives the module in an already-open login session, and a host may
        // have no `nixbld` either.
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
        // `cache/` is the reserved artifact-cache sibling (pin/steamcache.rs), not an account type —
        // without this filter it shows up in `cred list` as a bogus "cache" type holding a "steam" account.
        let mut types: Vec<_> = types
            .flatten()
            .filter(|e| e.path().is_dir() && e.file_name() != "cache")
            .collect();
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

    /// Who owns an account's directory — i.e. who may `cred rm`/refresh it WITHOUT sudo. This is the
    /// isolation a multi-user store gives each human: an account dir is 0750, owned by its creator, so on
    /// a shared host every user adds and manages their own while every user's tokens are still readable by
    /// the build sandbox (group `nixbld`) and by no other human. `cred list` surfaces the distinction.
    pub fn account_access(&self, type_name: &str, username: &str) -> AccountAccess {
        use std::os::unix::fs::MetadataExt;
        let dir = self.root.join(type_name).join(username);
        match std::fs::metadata(&dir) {
            Ok(m) if m.uid() == invoking_uid_num() => AccountAccess::Mine,
            Ok(m) => AccountAccess::Other {
                user: username_of(m.uid()),
                uid: m.uid(),
            },
            // No account directory (a flat legacy token, a race, or a store we cannot stat) — leave the
            // caller to say nothing rather than guess.
            Err(_) => AccountAccess::Unknown,
        }
    }

    /// Is this account DECLARED in the host's configuration rather than added with `cred add`?
    ///
    /// The NixOS module records what it manages in a manifest beside the store (`<root>-declarative-\
    /// credentials`, one store-relative token path per line, world-readable), which it also uses to prune a
    /// credential dropped from the config. Reading it is exact, where guessing from ownership would only be a
    /// proxy. No manifest (a store nothing declares, or a non-NixOS host) means nothing is declarative.
    pub fn is_declarative(&self, type_name: &str, username: &str) -> bool {
        let prefix = format!("{type_name}/{username}/");
        std::fs::read_to_string(self.manifest_path())
            .map(|s| s.lines().any(|l| l.starts_with(&prefix)))
            .unwrap_or(false)
    }

    /// The declarative-credentials manifest the NixOS module's materializer keeps BESIDE the store — the
    /// record `is_declarative` reads, and the file to delete when a host stops running the module (nothing
    /// maintains it then, and its stale entries would keep refusing `cred add`/`cred rm` forever).
    fn manifest_path(&self) -> PathBuf {
        PathBuf::from(format!(
            "{}-declarative-credentials",
            self.root.to_string_lossy().trim_end_matches('/')
        ))
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

    /// Persist a minted credential at `<root>/<type>/<username>/<filename>`. The token ends up
    /// `owner = the invoking human`, `group = the build-users group` (`$PROPNIX_BUILD_GROUP`, default
    /// `nixbld`), mode 0640 — the exact two readers a token is allowed: its OWNER (via the owner bits, so
    /// `propnix pin` reads it) and a SANDBOXED Nix builder (via the group bits). The group leg is what a
    /// user-namespaced build reliably reads: a build keeps only its primary gid (`nixbld`), no
    /// supplementary groups, and — crucially on ZFS — the kernel honors that primary gid through plain
    /// group-ownership bits but NOT through a POSIX ACL group entry, so the token is group-OWNED by the
    /// build group rather than ACL-granted to it.
    ///
    /// The token's group is set by SETGID INHERITANCE, never a chgrp: a human is not (and must not be — nix
    /// would pick them to run builds as) a member of `nixbld`, so cannot chgrp a file into it. Instead the
    /// type directories (`steam/`, `gog/`) are setgid `nixbld` and world-writable + sticky (the /tmp model),
    /// so any human creates their account dir there with no privilege, and the account dir + token beneath
    /// inherit the group for free. Not world-READABLE despite the world-writable type dir: the account dir
    /// is 0750 (`other` cannot even traverse into it) and the token is 0640.
    pub fn put(
        &self,
        type_name: &str,
        username: &str,
        filename: &str,
        token: &[u8],
    ) -> Result<(), String> {
        self.note_group_fallback();
        // Every field is exactly ONE path level of `<root>/<type>/<username>/<file>` — and the USERNAME is
        // not always operator-typed: the GOG provider takes it from the API's userData response, so it must
        // be validated like any external input or a hostile value walks the write (and its sudo escalation)
        // out of the layout. Same check the materializer applies to declared credentials.
        crate::cred::materialize::check_component("account type", type_name)?;
        crate::cred::materialize::check_component("username", username)?;
        crate::cred::materialize::check_component("token filename", filename)?;
        if type_name == "cache" {
            return Err("'cache' is the artifact cache, not a credential type".to_string());
        }
        // A declaratively-managed account belongs to the host configuration: writing a token here would
        // be clobbered back at the next activation (the materializer owns the account dir root-owned and
        // re-copies the declared secret), so the "success" would be a lie. Refuse and name the config,
        // exactly as `remove` does — and BEFORE touching the store, so nothing is half-written. (Only the
        // module writes the declarative manifest, so this can never misfire on an imperative account.)
        if self.is_declarative(type_name, username) {
            return Err(format!(
                "{type_name} credential '{username}' is managed declaratively — it is materialized from \
                 your NixOS configuration, so a token added here would be overwritten at the next \
                 activation.\n  Change it in services.propnix.credentials.{type_name}.{username} (and the \
                 secret it points at, e.g. sops.secrets) and rebuild.\n  (If this host no longer runs the \
                 propnix NixOS module, nothing maintains that record any more — delete \
                 {} to release the account.)",
                self.manifest_path().display()
            ));
        }
        let acct_dir = self.root.join(type_name).join(username);
        let dest = acct_dir.join(filename);

        let owner = self.owner_uid();
        // Settle the directories BEFORE staging the token: every refusal here (declined sudo, an account
        // path someone else created) then exits without a token copy ever having touched a shared temp dir.
        self.ensure_root()?;
        self.ensure_type_dir(&self.root.join(type_name))?;
        self.ensure_account_dir(&acct_dir)?;
        // …and bring the account dir onto the contract whatever layout created it: group = build group,
        // mode 0750-equivalent. Doing this only when the token would need an explicit `-g` is not enough:
        // a dir can carry the right group yet deny group traversal (2700 — the token becomes unreachable
        // however correct its own bits), or GRANT group write (an older 2775 layout — chgrp'ing that to
        // the build group would hand every build user replace rights over the token).
        self.converge_account_dir(&acct_dir)?;
        // Stage the token to a private user temp, then install it into the store.
        let tmp = self.stage_temp(token)?;
        // NB: the artifact cache (`cache/steam`) is deliberately NOT set up here. It must be readable and
        // writable with NO privilege — a sandboxed FOD warms and reads it and cannot sudo — so it cannot
        // depend on a root-created setgid dir. Instead steamcache.rs manages it entirely unprivileged:
        // each writer stores entries under its own uid/group (a build user's group IS nixbld, so builds
        // share; a host-side pin's are its own), 0640 not world-readable, and a reader simply skips any
        // entry it cannot read. See pin/steamcache.rs.
        let tmp_s = tmp.to_string_lossy();
        let dest_s = dest.to_string_lossy();
        // ATOMIC placement: install to a sibling temp IN THE ACCOUNT DIR, then rename onto the final name.
        // GNU `install` writes straight to its dest (unlink-then-create, not temp+rename), so installing
        // directly onto the token path would — if interrupted (disk full, ^C) — unlink the good token and
        // leave a PARTIAL one at the real path, and a truncated token then fails to parse and strands every
        // fetch for this account. The rename makes the final name appear all-or-nothing and never disturbs
        // an existing good token until it succeeds. The temp is a sibling so the rename stays within one
        // filesystem (a cross-fs `mv` would silently degrade to copy+unlink, reintroducing the gap).
        let dest_tmp = acct_dir.join(format!(".{filename}.{}.tmp", std::process::id()));
        let dest_tmp_s = dest_tmp.to_string_lossy();
        // Install WITHOUT -g only when the token will RELIABLY inherit the build group — i.e. the account
        // dir is setgid AND its group already IS the build group. Then a plain unprivileged `install`
        // produces a group-`nixbld` token with no sudo. Otherwise (dir not setgid, or setgid with some
        // OTHER group — which happens on a 1777-fallback type dir where the account dir inherited the
        // human's primary group and setgid stuck because it matched) pass an explicit `-g`, which names the
        // build group and rides the sudo escalation. Testing the actual gid, not just the setgid bit, is
        // what makes this correct on every filesystem — an is_setgid-only check would wrongly omit -g for a
        // setgid-but-wrong-group dir and leave the token unreadable by builds.
        let inherits_build_group = is_setgid(&acct_dir)
            && self
                .file_group
                .as_deref()
                .and_then(gid_of_group)
                .is_some_and(|want| gid_of(&acct_dir) == Some(want));
        let mut args: Vec<&str> = vec!["-m", "0640", "-o", &owner];
        if !inherits_build_group {
            args.extend(self.group_args());
        }
        args.push(&tmp_s);
        args.push(&dest_tmp_s);
        let install_res = self.run_escalating("install", &args);
        // Always remove the staging temp (it holds the token) even when the install failed — sudo declined,
        // ^C at the prompt, disk full — so a failed `cred add` never leaves a secret behind in /tmp.
        let _ = std::fs::remove_file(&tmp);
        if let Err(e) = install_res {
            // `install` writes its dest directly, so a failure can still have left a (possibly partial)
            // token copy at the sibling temp name — and as a dotfile nothing else would ever reclaim it.
            // A plain unlink suffices on every path here: even a sudo-made temp sits in a dir the invoker
            // owns and may unlink from.
            let _ = std::fs::remove_file(&dest_tmp);
            return Err(e);
        }
        // `-T`: the dest must be REPLACED, never descended into — without it, a directory sitting at the
        // token's final path would make `mv` silently move the temp INSIDE it and report success, leaving
        // no token at the path every fetch reads.
        if let Err(e) = self.run_escalating("mv", &["-fT", &dest_tmp_s, &dest_s]) {
            let _ = self.run_escalating("rm", &["-f", "--", &dest_tmp_s]);
            return Err(e);
        }
        self.ensure_pointer()?;
        Ok(())
    }

    /// Run a store write UNPRIVILEGED FIRST, retrying once under sudo only when that fails (and we are not
    /// already root). This is what keeps the two setups honest at once: on a module-managed store every
    /// normal write lands in a world-writable type dir or the human's own account dir, so the first attempt
    /// succeeds and NO PROMPT ever appears; on a plain store exactly the operations that genuinely need
    /// root (creating the root, naming the build group on a type dir) fall through to one sudo prompt each.
    /// The old shape — deciding sudo up front from the store root's writability — got both cases wrong:
    /// it prompted for writes the world-writable layout permits, and it ran `install -g nixbld`
    /// unprivileged where only root may name that group.
    fn run_escalating(&self, program: &str, args: &[&str]) -> Result<(), String> {
        let plain = run_command(program, args);
        if plain.is_ok() || is_root() {
            return plain;
        }
        let mut v = vec![program];
        v.extend_from_slice(args);
        run_command("sudo", &v).map_err(|sudo_err| {
            format!("{sudo_err} (unprivileged attempt: {})", plain.unwrap_err())
        })
    }

    /// The store root, created only if missing (the NixOS module owns it — root-owned; adjusting it as a
    /// plain user is EPERM even though writing *inside* it is allowed, so an existing root is left alone).
    fn ensure_root(&self) -> Result<(), String> {
        if self.root.is_dir() {
            return Ok(());
        }
        let owner = self.owner_uid();
        self.run_escalating(
            "install",
            &["-d", "-m", "0755", "-o", &owner, &self.root.to_string_lossy()],
        )
    }

    /// A type directory (`steam/`, `gog/`), created only if missing. The load-bearing dir of the whole
    /// contract: setgid `nixbld` (so tokens beneath inherit the build group), world-writable + sticky (so
    /// any human creates an account dir here without being in that group, `/tmp`-style — the sticky bit
    /// stops one user removing another's). The NixOS module pre-creates these identically, so on a managed
    /// store this is a no-op; a plain store creates it via the sudo retry (naming the build group is a
    /// root-only act for a human outside it). No secret lives at this level — only account-dir names.
    fn ensure_type_dir(&self, dir: &Path) -> Result<(), String> {
        match std::fs::symlink_metadata(dir) {
            Ok(m) if !m.is_dir() => {
                return Err(format!(
                    "{} exists but is not a real directory — remove it and retry",
                    dir.display()
                ));
            }
            Ok(_) => {
                // An existing type dir is trusted as-is (the module owns it) — EXCEPT the one shape that
                // voids `ensure_account_dir`'s validation: world-writable WITHOUT sticky, where any user
                // can rename a just-validated account entry away and substitute another between our lstat
                // and the write. Both layouts this code creates (3777, 1777) are sticky; only a manual
                // chmod produces the broken shape, so name the repair rather than work around it.
                if mode_of(dir).is_some_and(|m| m & 0o002 != 0 && m & 0o1000 == 0) {
                    return Err(format!(
                        "type dir {} is world-writable but not sticky, so account entries in it can be \
                         swapped out from under their owners — chmod +t it (the contract layout is 3777)",
                        dir.display()
                    ));
                }
                return Ok(());
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("stat {}: {e}", dir.display())),
        }
        let path = dir.to_string_lossy();
        // 3777 = setgid + sticky + rwx for all. Some environments refuse the setgid chmod outright even
        // for root's own dir (a user namespace over ZFS EPERMs instead of dropping the bit) — fall back
        // to 1777 there: the layout loses group inheritance, and `put` notices the missing setgid bit
        // and names the group explicitly instead.
        let install_d = |mode: &str| {
            let mut args: Vec<&str> = vec!["-d", "-m", mode];
            args.extend(self.group_args());
            args.push(&path);
            self.run_escalating("install", &args)
        };
        let res = install_d("3777").or_else(|_| install_d("1777"));
        if res.is_err() {
            // A failed `install -d` can still have CREATED the dir (the mkdir succeeded; applying the
            // mode/group did not). Leaving it would wedge every later run — the dir would exist, be
            // trusted above, and carry none of the contract. Remove only what this call just made:
            // rmdir refuses a non-empty or foreign (symlink/file) path, so it cannot take anything else.
            let _ = std::fs::remove_dir(dir);
        }
        res
    }

    /// The per-account directory (`<type>/<username>/`): owned by the human, `2750`, group `nixbld`. The
    /// setgid bit is what lets the token inside inherit `nixbld` with NO privilege, and getting it there is
    /// the subtle part, because a human is not a member of `nixbld`:
    ///
    ///   * Unprivileged (the common path): a RAW `mkdir`, and afterwards neither `chmod` nor `chown`. The
    ///     account dir INHERITS its group and the setgid bit from the setgid type dir at creation time
    ///     (`inode_init_owner` forces `S_ISGID` onto a directory made under a setgid parent — generic VFS,
    ///     every filesystem), and BOTH follow-up syscalls can silently destroy that bit for this caller: a
    ///     `chmod` requesting 2750 by a non-member of `nixbld` without `CAP_FSETID` comes back rc=0 but
    ///     stores 0750 (measured on ZFS and ext4 — generic kernel behavior), and a `chown` clears a dir's
    ///     setgid on SOME filesystems (measured: ZFS clears it even chowning to self — the pre-fix
    ///     `install -o` layout bug — while ext4 retains it; either is permitted). (GNU `install -d -m`
    ///     happens to survive — strace shows it is `mkdir(path, mode)` with no chmod — but that is an
    ///     implementation accident, and its `-o` form chowns.) A raw mkdir needs neither syscall: the
    ///     creator already owns it, and umask 0027 makes it land 0750, raised to 2750 by the inherited
    ///     setgid.
    ///   * As root (`sudo propnix cred add`): `install` names owner + group + setgid directly. Root holds
    ///     `CAP_FSETID`, so its setgid chmod is NOT stripped; and we must NOT raw-mkdir-then-chown here, as
    ///     `chown` also clears a directory's setgid bit.
    ///
    /// If the type dir itself is not setgid (a filesystem that refused even root's setgid — the 1777
    /// fallback in `ensure_type_dir`), the raw mkdir won't inherit setgid, and `put`'s group check installs
    /// the token with an explicit `-g` instead.
    fn ensure_account_dir(&self, dir: &Path) -> Result<(), String> {
        // A pre-existing entry at the account path is only usable if it is what this function would have
        // created: a REAL directory owned by the invoking human (or root — a module-declared account).
        // The type dir above is world-writable, so the path may instead hold something another user made
        // — a symlink, a plain file, a directory of theirs — and writing a token through such an entry
        // would land it at a path (symlink) or under an owner (foreign dir) the contract does not
        // describe: `is_dir()` follows symlinks, so it cannot make this distinction. lstat and check.
        // (Once validated, a sticky type dir also keeps the entry from being swapped out from under us —
        // the same guarantee /tmp gives the staging temp.)
        match std::fs::symlink_metadata(dir) {
            Ok(m) if !m.is_dir() => {
                return Err(format!(
                    "{} already exists but is not a real directory (a symlink or file someone created \
                     there) — remove it and retry",
                    dir.display()
                ));
            }
            Ok(m) => {
                use std::os::unix::fs::MetadataExt;
                if m.uid() != invoking_uid_num() && m.uid() != 0 {
                    return Err(format!(
                        "account dir {} belongs to {} — a token stored there would be managed by them, \
                         not you; have them remove it or pick a different username",
                        dir.display(),
                        username_of(m.uid())
                    ));
                }
                return Ok(());
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("stat {}: {e}", dir.display())),
        }
        if is_root() {
            let owner = self.owner_uid();
            let path = dir.to_string_lossy();
            let mut args: Vec<&str> = vec!["-d", "-m", "2750", "-o", &owner];
            args.extend(self.group_args());
            args.push(&path);
            return self.run_escalating("install", &args);
        }
        // Unprivileged: raw mkdir, umask-limited, so the inherited setgid survives (see above).
        let old = unsafe { libc::umask(0o027) };
        let res = std::fs::DirBuilder::new().create(dir);
        unsafe {
            libc::umask(old);
        }
        match res {
            // A concurrent creator (a second `cred add`, the module's activation materializing the same
            // account) is not an error — whatever appeared gets exactly the validation a pre-existing
            // entry would have received. Erroring here would fail the add AFTER the interactive login.
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => self.ensure_account_dir(dir),
            other => other.map_err(|e| format!("create account dir {}: {e}", dir.display())),
        }
    }

    /// Bring an account dir onto the contract whatever layout created it: group = the build group, and the
    /// permission bits exactly 0750 — owner rwx; group rx (build users must TRAVERSE to the token but never
    /// write: group-write would let a build replace the token); other nothing. Piecewise no-ops on a
    /// compliant dir, so the common layouts never prompt; where a chgrp is genuinely needed it rides the
    /// same sudo escalation the token's `install -g` does. Setgid/sticky: the symbolic mode names neither
    /// and GNU chmod carries a directory's existing bits through — though the kernel silently drops a
    /// dir's setgid when a non-member without CAP_FSETID chmods it (see ensure_account_dir's notes). That
    /// is fine: `put` computes the inheritance check AFTER this and reads the dir fresh, so a dropped
    /// setgid just routes the token through the explicit `-g` leg instead.
    fn converge_account_dir(&self, dir: &Path) -> Result<(), String> {
        let dir_s = dir.to_string_lossy();
        if let Some(group) = self.file_group.as_deref() {
            if gid_of_group(group).is_some_and(|want| gid_of(dir) != Some(want)) {
                self.run_escalating("chgrp", &[group, &dir_s])?;
            }
        }
        if mode_of(dir).is_some_and(|m| m & 0o777 != 0o750) {
            self.run_escalating("chmod", &["u=rwx,g=rx,o=", &dir_s])?;
        }
        Ok(())
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
                 points at, e.g. sops.secrets) and rebuild.\n  (If this host no longer runs the propnix \
                 NixOS module, nothing maintains that record any more — delete {} to release the account.)",
                self.manifest_path().display()
            ));
        }
        // Ownership gate: another human's account is deletable only DELIBERATELY as root — an admin must be
        // able to clean up (`sudo propnix cred rm` always works), but an unprivileged run must not stumble
        // through rm's sticky-bit stderr into a surprise sudo prompt that deletes a colleague's credential.
        // `Mine` and `Unknown` proceed as before; a ROOT-owned yet non-declarative account is a partial-
        // activation leftover that cleanup must be able to remove, so it proceeds too (via the sudo retry).
        match self.account_access(&type_name, username) {
            AccountAccess::Other { user, uid } if uid != 0 => {
                if is_root() {
                    eprintln!(
                        "propnix: removing {type_name} account '{username}' owned by {user} (running as \
                         root)"
                    );
                } else {
                    return Err(format!(
                        "{type_name} account '{username}' belongs to {user} — only they (or root) may \
                         remove it. As an administrator: sudo propnix cred rm -t {type_name} {username}"
                    ));
                }
            }
            _ => {}
        }
        // An account dir is owned by the human who added it (in a world-writable + sticky type dir), so a
        // plain `rm` removes your own with no prompt; a root-owned leftover is sticky-protected, so the
        // escalating run falls through to one sudo prompt — which `cred rm` is an explicit-enough act to
        // justify.
        self.run_escalating("rm", &["-rf", "--", &dir.to_string_lossy()])?;
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
        // No group: the pointer holds no secret (it names `/propnix`) and is world-readable 0644, so its
        // group is irrelevant — and NOT passing `-g` is what lets the human write it into a root they own
        // (a plain store) without an `install -g nixbld` that only root could run.
        let args: Vec<&str> = vec!["-m", "0644", "-o", &owner, &tmp_s, &ptr_s];
        let res = self.run_escalating("install", &args);
        let _ = std::fs::remove_file(&tmp); // clean the staging temp even on failure
        res
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
    /// The uid that should own the store: the human running the command, even when the write itself is
    /// escalated. Under `sudo propnix …` our own uid is 0, so honour SUDO_UID; otherwise we are already
    /// the user and sudo is only spawned for the individual `install` calls.
    fn owner_uid(&self) -> String {
        invoking_uid()
    }
}

/// The human running the command, even under `sudo propnix …` (honour SUDO_UID).
fn invoking_uid() -> String {
    invoking_uid_num().to_string()
}

fn invoking_uid_num() -> u32 {
    std::env::var("SUDO_UID")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .unwrap_or_else(|| unsafe { libc::getuid() })
}

/// The login name of a uid, or its number as a string when the host has no name for it. Single-threaded
/// on every path that calls this, so plain `getpwuid` is fine.
fn username_of(uid: u32) -> String {
    let pw = unsafe { libc::getpwuid(uid) };
    if pw.is_null() {
        return uid.to_string();
    }
    let name = unsafe { (*pw).pw_name };
    if name.is_null() {
        return uid.to_string();
    }
    unsafe { std::ffi::CStr::from_ptr(name) }
        .to_str()
        .map(str::to_string)
        .unwrap_or_else(|_| uid.to_string())
}

fn is_root() -> bool {
    unsafe { libc::geteuid() == 0 }
}

/// Run one filesystem command, mapping a non-zero exit or a spawn failure to a legible error. `sudo` is
/// applied by the caller (`run_escalating`) only as a retry, never speculatively — so the common,
/// permitted write runs bare and prompts for nothing.
fn run_command(program: &str, args: &[&str]) -> Result<(), String> {
    match Command::new(program).args(args).status() {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("`{program} {}` failed ({s})", args.join(" "))),
        Err(e) => Err(format!("running {program}: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn store_at(root: &Path) -> CredStore {
        // A numeric gid is always a valid `install -g`, and our own is the one group we can hand to
        // setgid dirs unprivileged — it stands in for the build group in these layout tests.
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

    fn mode_of(p: &Path) -> u32 {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(p).unwrap().mode() & 0o7777
    }

    fn gid_of(p: &Path) -> u32 {
        use std::os::unix::fs::MetadataExt;
        std::fs::metadata(p).unwrap().gid()
    }

    #[test]
    fn the_layout_names_exactly_two_readers() {
        // The whole point of the contract: a token is readable by its OWNER (owner bits) and by the
        // BUILD GROUP (group bits, inherited from the setgid type dir) — and by nobody else, because
        // the account dir refuses `other` traversal even though the type dir above is world-writable.
        let root = tmp_root("two-readers");
        let store = store_at(&root);
        store.put("gog", "alice", "galaxy_tokens.json", b"{}").unwrap();

        let type_dir = root.join("gog");
        let acct = type_dir.join("alice");
        let token = acct.join("galaxy_tokens.json");
        let gid: u32 = unsafe { libc::getgid() };

        // Type dir: the /tmp model — setgid (group inheritance) + sticky + world-writable, so any
        // human can create their account dir here without being a member of the build group.
        if is_setgid(&type_dir) {
            assert_eq!(mode_of(&type_dir), 0o3777, "type dir is the setgid+sticky /tmp model");
            assert_eq!(gid_of(&type_dir), gid, "type dir carries the build group");
            // Account dir: owned by the human, group inherited from the setgid parent, no `other` bits.
            assert_eq!(mode_of(&acct) & 0o0777, 0o750, "account dir must refuse `other` traversal");
            assert_eq!(gid_of(&acct), gid, "account dir inherits the build group");
        } else {
            eprintln!("setgid did not stick on this filesystem; group falls back to explicit -g");
        }
        // The token itself: 0640, group = the build group — HOWEVER it got there (inheritance on a
        // setgid layout, explicit -g on the fallback).
        assert_eq!(mode_of(&token), 0o640, "token is owner rw, group r, other NOTHING");
        assert_eq!(gid_of(&token), gid, "token must be group-owned by the build group");
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
        // A store with no NixOS module: `put` bootstraps the type dir itself (same /tmp-model layout
        // the module would pre-create) and the token still lands 0640 with the right bytes.
        let root = tmp_root("plain-put");
        let store = store_at(&root);
        store
            .put("gog", "alice", "galaxy_tokens.json", b"{\"access_token\":\"x\"}")
            .unwrap();

        let acct = root.join("gog").join("alice");
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
    fn adding_over_a_declarative_credential_is_refused_before_touching_the_store() {
        let root = tmp_root("add-declarative");
        let store = store_at(&root);
        std::fs::write(
            PathBuf::from(format!("{}-declarative-credentials", root.display())),
            "gog/alice/galaxy_tokens.json\n",
        )
        .unwrap();
        let err = store.put("gog", "alice", "galaxy_tokens.json", b"{}").unwrap_err();
        assert!(err.contains("managed declaratively"), "got: {err}");
        assert!(
            err.contains("services.propnix.credentials.gog.alice"),
            "the error must name the option to edit; got: {err}"
        );
        assert!(
            err.contains("-declarative-credentials"),
            "the error must name the manifest to delete when the module is gone; got: {err}"
        );
        assert!(
            !root.join("gog").join("alice").exists(),
            "the refusal must not have created anything in the store"
        );
        // An imperative account of the SAME type is unaffected.
        store.put("gog", "bob", "galaxy_tokens.json", b"{}").unwrap();
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
    fn ensure_dirs_leave_an_existing_dir_alone() {
        // The module owns the store root and pre-creates the type dirs; adjusting either as a plain user
        // would be EPERM, so an existing dir must never be touched.
        let root = tmp_root("existing");
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o0705)).unwrap();
        let store = store_at(&root);
        store.ensure_root().unwrap();
        assert_eq!(mode_of(&root), 0o0705, "an existing root keeps its mode");
        let t = root.join("gog");
        std::fs::create_dir(&t).unwrap();
        std::fs::set_permissions(&t, std::fs::Permissions::from_mode(0o0700)).unwrap();
        store.ensure_type_dir(&t).unwrap();
        assert_eq!(mode_of(&t), 0o0700, "an existing type dir keeps its mode");
    }

    #[test]
    fn put_refuses_an_account_path_that_is_not_a_real_directory() {
        // The type dir is world-writable, so the account path can hold an entry somebody else created.
        // A symlink there would have the token installed at whatever it points to; a plain file is junk
        // `install` would fail against confusingly. Both must be refused up front, touching nothing.
        let root = tmp_root("squat");
        let store = store_at(&root);
        store.put("gog", "alice", "t.json", b"{}").unwrap(); // seeds the layout

        let elsewhere = root.join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, root.join("gog").join("bob")).unwrap();
        let err = store.put("gog", "bob", "t.json", b"{}").unwrap_err();
        assert!(err.contains("not a real directory"), "got: {err}");
        assert!(
            std::fs::read_dir(&elsewhere).unwrap().next().is_none(),
            "nothing may be written through the symlink"
        );

        std::fs::write(root.join("gog").join("carol"), b"junk").unwrap();
        let err = store.put("gog", "carol", "t.json", b"{}").unwrap_err();
        assert!(err.contains("not a real directory"), "got: {err}");
        assert_eq!(
            std::fs::read(root.join("gog").join("carol")).unwrap(),
            b"junk",
            "the pre-existing entry must be left alone"
        );
    }

    #[test]
    fn a_fallback_layout_converges_the_account_dirs_group_alongside_the_token() {
        // On the layouts where the token needs an explicit `-g` (no setgid inheritance), the account DIR
        // must get the build group too: a 0750 dir left with the creator's group is untraversable by the
        // build user, so the correctly-grouped token inside would still be unreadable by every build.
        // Exercised with a supplementary group standing in for the build group (the one other group we
        // can chgrp to unprivileged); hosts where the test user has no second group skip.
        let me = unsafe { libc::getgid() };
        let mut groups = [0 as libc::gid_t; 128];
        let n = unsafe { libc::getgroups(groups.len() as libc::c_int, groups.as_mut_ptr()) };
        let Some(other) = (n > 0)
            .then(|| groups[..n as usize].iter().map(|&g| g as u32).find(|&g| g != me))
            .flatten()
        else {
            eprintln!("no supplementary group on this host — skipping the dir-group convergence check");
            return;
        };

        let root = tmp_root("dir-group");
        let store = CredStore {
            root: root.clone(),
            build_group: other.to_string(),
            file_group: Some(other.to_string()),
        };
        // A pre-existing NON-setgid type dir — what ensure_type_dir's 1777 fallback leaves on a
        // filesystem that refuses setgid — so the account dir cannot inherit the build group.
        let type_dir = root.join("gog");
        std::fs::create_dir(&type_dir).unwrap();
        std::fs::set_permissions(&type_dir, std::fs::Permissions::from_mode(0o1777)).unwrap();

        store.put("gog", "alice", "t.json", b"{}").unwrap();
        let acct = type_dir.join("alice");
        assert_eq!(
            gid_of(&acct),
            other,
            "the account dir must carry the build group, or the group can never reach the token"
        );
        assert_eq!(
            mode_of(&acct) & 0o777,
            0o750,
            "the account dir must be exactly 0750: group traversal, no group write, no other bits"
        );
        assert_eq!(gid_of(&acct.join("t.json")), other, "the token carries the build group");
        assert_eq!(mode_of(&acct.join("t.json")), 0o640);
    }

    #[test]
    fn put_converges_a_noncompliant_account_dir_it_adopts() {
        // Two pre-existing shapes the convergence must repair even though `put` did not create the dir:
        // one that already carries the right group but denies group traversal (2700 — the token would
        // inherit the right group, so the no-`-g` path is taken, yet the build group could never REACH
        // it), and one that grants group/other write (0777 — left as-is, the build group could REPLACE
        // the token). After put, both must sit at exactly 0750.
        let root = tmp_root("adopt");
        let store = store_at(&root);
        let type_dir = root.join("gog");
        std::fs::create_dir(&type_dir).unwrap();

        let tight = type_dir.join("alice");
        std::fs::create_dir(&tight).unwrap();
        std::fs::set_permissions(&tight, std::fs::Permissions::from_mode(0o0700)).unwrap();
        store.put("gog", "alice", "t.json", b"{}").unwrap();
        assert_eq!(mode_of(&tight) & 0o777, 0o750, "group regains traversal, others stay shut out");
        assert_eq!(mode_of(&tight.join("t.json")), 0o640);

        let loose = type_dir.join("bob");
        std::fs::create_dir(&loose).unwrap();
        std::fs::set_permissions(&loose, std::fs::Permissions::from_mode(0o777)).unwrap();
        store.put("gog", "bob", "t.json", b"{}").unwrap();
        assert_eq!(mode_of(&loose) & 0o777, 0o750, "group/other write must be stripped");
    }

    #[test]
    fn a_world_writable_but_nonsticky_type_dir_is_refused() {
        // The one pre-existing type-dir shape `put` must not build on: world-writable without sticky,
        // where any user can swap a just-validated account entry between the lstat check and the write.
        // Both layouts this code creates (3777, 1777) are sticky; only a manual chmod produces this.
        let root = tmp_root("nonsticky");
        let store = store_at(&root);
        let type_dir = root.join("gog");
        std::fs::create_dir(&type_dir).unwrap();
        std::fs::set_permissions(&type_dir, std::fs::Permissions::from_mode(0o777)).unwrap();
        let err = store.put("gog", "alice", "t.json", b"{}").unwrap_err();
        assert!(err.contains("not sticky"), "got: {err}");
        assert!(
            !type_dir.join("alice").exists(),
            "nothing may be created under the refused type dir"
        );
    }
}

/// The group token files should carry: the requested one if it exists, else nix's own default build group,
/// else none at all. That fallback chain is what keeps `cred add` working on a host whose configured group
/// name is stale (a login session from an older generation), while a single-user Nix — no `nixbld` at all,
/// builds run as the human — needs no group leg in the first place.
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
    gid_of_group(name).is_some()
}

/// The numeric gid of a group name — used to compare a dir's actual group against the one the contract
/// wants, and (via `group_exists`) to decide whether a configured group name is usable at all. A numeric
/// string is accepted (the tests' numeric `file_group`), but only if a group with that gid actually
/// exists: blindly trusting any number would let a stale numeric `PROPNIX_BUILD_GROUP` skip the `nixbld`
/// fallback and group-own tokens by a gid nobody has — unreadable by every build, and every unprivileged
/// `install -g`/`chgrp` failing into sudo prompts. `None` for an unknown group. Single-threaded on every
/// path that calls this, so plain getgrnam/getgrgid are fine.
fn gid_of_group(name: &str) -> Option<u32> {
    if let Ok(n) = name.parse::<u32>() {
        let gr = unsafe { libc::getgrgid(n) };
        return if gr.is_null() { None } else { Some(n) };
    }
    let c = CString::new(name).ok()?;
    let gr = unsafe { libc::getgrnam(c.as_ptr()) };
    if gr.is_null() {
        None
    } else {
        Some(unsafe { (*gr).gr_gid })
    }
}

/// Does `path` carry the setgid bit? Used on the ACCOUNT dir in `put` to decide whether a plain
/// unprivileged `install` will inherit the build group from the dir (the setgid-inheritance leg of the
/// contract) or whether the token needs an explicit `-g` riding the sudo escalation instead.
fn is_setgid(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path)
        .map(|m| m.mode() & 0o2000 != 0)
        .unwrap_or(false)
}

/// The gid owning `path`, or `None` if it can't be stat'd. Used to decide whether a token installed into
/// an account dir will inherit the build group (see `put`).
fn gid_of(path: &Path) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| m.gid())
}

/// The permission bits of `path`, or `None` if it can't be stat'd.
fn mode_of(path: &Path) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|m| m.mode() & 0o7777)
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
