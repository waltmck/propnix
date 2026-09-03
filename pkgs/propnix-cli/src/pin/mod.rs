//! `propnix pin` — recompute the content pins in pkgs/games/*/versions.json by STREAMING.
//!
//! Every game payload is a fixed-output derivation pinned by the recursive sha256 of its fetched tree.
//! Refreshing a pin the obvious way means downloading the whole title and running `nix hash path`, which
//! needs free disk equal to the game — hundreds of GB for a modern AAA title, and far beyond a CI runner.
//! Instead the store's manifest describes the tree exactly, a NAR is a pure function of that metadata plus
//! the file bytes in tree order, and both CDNs are random-access per chunk — so the bytes are pulled in
//! NAR order and hashed as they fly past, and nothing is ever written to disk. See `nar` for the argument.
//!
//! Bandwidth is unchanged and cannot be reduced: manifests pin files by MD5/SHA-1, and no SHA-256 can be
//! derived from those, so every byte must cross the wire once. Only the storage requirement goes away.

pub mod concurrency;
pub mod dedup;
pub mod download;
pub mod engine;
pub mod gog;
pub mod hosts;
pub mod nar;
pub mod retry;
pub mod steam;
pub mod steamcache;
pub mod versions;

use std::collections::BTreeMap;

use versions::{Pin, PinLoc, Policy, Store, VersionsFile};

pub struct Opts {
    pub repo: std::path::PathBuf,
    pub game: String,
    pub credential_dir: std::path::PathBuf,
    pub workers: usize,
    pub window_bytes: u64,
    /// Force a Steam branch, overriding each row's own `branch`. `None` = use the row's (or `public`).
    pub branch: Option<String>,
    pub mode: Mode,
    /// Force a GOG release track instead of inferring it from the pinned build. Only meaningful in
    /// `Latest` and `Scaffold` modes, where there is no pin to infer from.
    pub gog_branch: Option<String>,
    /// Which stored account to use per store. `None` = try every stored account of that type until one
    /// owns the title, which is what the fetchers already do. Precedence is settled by the caller:
    /// flag > `PROPNIX_{GOG,STEAM}_ACCOUNT` > try-all.
    pub gog_account: Option<String>,
    pub steam_account: Option<String>,
}

/// Try each stored account until one can do the job — the ONE implementation of that policy, shared by
/// both stores because it is the fetchers' behaviour and getting it subtly different per store is how a
/// multi-account host ends up with "GOG works, Steam doesn't".
///
/// Advance ONLY on an OWNERSHIP-class refusal. A transport or parse failure aborts immediately: retrying
/// it against a second account cannot help and would bury the real error behind "no account owns this".
/// Both stores settle ownership before any bulk transfer (GOG resolves `secure_link` up front, Steam
/// asks for the depot key and a manifest request code), so a wrong account costs a round trip, not a
/// download.
pub(crate) fn try_accounts<C, T, E>(
    accounts: &[C],
    name: impl Fn(&C) -> String,
    is_not_owned: impl Fn(&E) -> bool,
    exhausted: impl FnOnce(Vec<String>, Vec<E>) -> E,
    mut attempt: impl FnMut(&C) -> Result<T, E>,
) -> Result<T, E>
where
    E: std::fmt::Display,
{
    let mut tried: Vec<String> = Vec::new();
    // Every ownership-class refusal, kept (not just the last, and not just its text): the caller's
    // `exhausted` needs the whole set to decide the aggregate CLASS — e.g. Steam must report a walk in
    // which some account never LOGGED IN as inconclusive, not as a definitive "no account owns this".
    let mut refusals: Vec<E> = Vec::new();
    for c in accounts {
        let n = name(c);
        tried.push(n.clone());
        match attempt(c) {
            Ok(v) => return Ok(v),
            Err(e) if is_not_owned(&e) => {
                eprintln!("  account {n:?} cannot fetch this ({e}); trying the next");
                refusals.push(e);
            }
            Err(e) => return Err(e),
        }
    }
    Err(exhausted(tried, refusals))
}

/// Which Steam branch a pin sits on: the explicit flag, else the row's own `branch`, else public.
///
/// A Steam manifest carries no branch of its own, so — unlike GOG, where the pinned build identifies its
/// release track — a beta pin cannot be inferred and must be RECORDED. Reading it from the row is what
/// makes a beta-pinned game auto-update on its own branch without anyone remembering a flag.
fn steam_branch(opts: &Opts, pin: &Pin) -> String {
    opts.branch
        .clone()
        .or_else(|| pin.opt_str("branch").map(str::to_string))
        .unwrap_or_else(|| "public".to_string())
}

/// How much of the existing pin to trust.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// Follow upstream: change only the pins upstream has moved past, on the branch each pin already
    /// sits on, and never backwards. This is what the weekly job runs.
    Update,
    /// Keep the version currently pinned but recompute its `outputHash` from scratch, ignoring the
    /// recorded one. This is the "the hash looks wrong" repair: it answers "what SHOULD this pin's hash
    /// be?" without moving the game.
    Recompute,
    /// Ignore the recorded build/manifest AND the inferred branch; go to the newest build and rehash.
    /// Deliberately bypasses the never-backwards guard, so it can move a game onto a different release
    /// track — say it explicitly with `--gog-branch`.
    Latest,
}

/// Why a game could not be re-pinned. Separated from real errors so callers (and CI) can treat these
/// as "ask a human", not "the tool is broken".
#[derive(Debug)]
pub enum Blocked {
    /// No usable credential for the store this game comes from.
    NoCredential(String),
    /// The account does not own the game, or one of its DLC.
    NotOwned(String),
    /// A construct we refuse to guess at (see the store modules for what and why).
    Refused(String),
}

impl std::fmt::Display for Blocked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Blocked::NoCredential(m) | Blocked::NotOwned(m) | Blocked::Refused(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for Blocked {}

/// One pin that upstream has moved past.
pub struct Change {
    pub loc: PinLoc,
    pub pname: String,
    /// The key that identifies the version: `buildId` for GOG, `manifestId` for Steam.
    pub key: &'static str,
    pub from: String,
    pub to: String,
    /// What to write into the row's `version` field, and what the PR table / commit message / issue
    /// row show. GOG gives a real `version_name`; Steam publishes none, so it gets the branch BUILD ID
    /// — the only monotonic, human-quotable label Steam has.
    pub version: Option<String>,
}

pub struct Report {
    pub game: String,
    pub changes: Vec<Change>,
    /// The game's declared policy, so callers can distinguish "nothing to do" from "deliberately held".
    pub policy: Policy,
}

impl Report {
    pub fn up_to_date(&self) -> bool {
        self.changes.is_empty()
    }

    /// Deliberately held back — so CI must not treat it as needing attention.
    pub fn held(&self) -> bool {
        self.policy.freeze
    }

    pub fn to_json(&self) -> String {
        let changes: Vec<serde_json::Value> = self
            .changes
            .iter()
            .map(|c| {
                serde_json::json!({
                    "where": c.loc.to_string(),
                    "pname": c.pname,
                    "key": c.key,
                    "from": c.from,
                    "to": c.to,
                    "version": c.version,
                })
            })
            .collect();
        serde_json::to_string_pretty(&serde_json::json!({
            "game": self.game,
            "upToDate": self.up_to_date(),
            // Present on EVERY report, so a consumer can read them unconditionally.
            "blocked": false,
            "detail": serde_json::Value::Null,
            "frozen": self.policy.freeze,
            "pinnedTo": self.policy.pinned_to(),
            "policyReason": self.policy.reason,
            "changes": changes,
        }))
        .unwrap_or_default()
    }

}

/// The report a `--check` still owes CI when it could not resolve upstream at all.
///
/// Exiting 4 with EMPTY stdout used to strand the whole weekly run: `pin-refresh.sh` recorded the game
/// `blocked` with a zero-byte check.json, and `pin-issue.sh` then died on it under `set -e`, taking the
/// issues step and every step after it — close sweeps, commits, the PR — with it. The exact games the
/// blocked mechanism exists for were the ones that killed the run.
pub fn blocked_report_json(game: &str, detail: &str) -> String {
    serde_json::to_string_pretty(&serde_json::json!({
        "game": game,
        "upToDate": false,
        "blocked": true,
        "detail": detail,
        "frozen": false,
        "pinnedTo": serde_json::Value::Null,
        "policyReason": serde_json::Value::Null,
        "changes": [],
    }))
    .unwrap_or_default()
}

pub fn versions_path(repo: &std::path::Path, game: &str) -> std::path::PathBuf {
    repo.join("pkgs/games").join(game).join("versions.json")
}

/// ANONYMOUS discovery: which pins has upstream moved past?
pub fn check(opts: &Opts) -> Result<(Report, VersionsFile), Box<dyn std::error::Error>> {
    check_inner(opts).map_err(|e| classify_check(e, &opts.game))
}

fn check_inner(opts: &Opts) -> Result<(Report, VersionsFile), Box<dyn std::error::Error>> {
    let file = VersionsFile::load(&versions_path(&opts.repo, &opts.game))?;
    let policy = file.policy()?;
    if policy.freeze && opts.mode == Mode::Update {
        // Frozen: report nothing to do and say why, so nobody has to go read versions.json to find out.
        eprintln!(
            "  {}: frozen, not following upstream — {}",
            opts.game,
            policy.reason.as_deref().unwrap_or("no reason recorded")
        );
        return Ok((
            Report { game: opts.game.clone(), changes: Vec::new(), policy },
            file,
        ));
    }
    let pins = file.pins()?;
    let mut changes = Vec::new();
    // One appinfo snapshot per (Steam app, branch): a single response is atomic across all its depots,
    // which is what keeps a base game and its DLC depots on the same moment in time. The branch is part
    // of the key because two rows of one app may legitimately sit on different branches.
    let mut appinfo: BTreeMap<(u32, String), steam::AppInfo> = BTreeMap::new();
    // Cache GOG build lookups too — a base game and its DLC share a productId.
    let mut gogbuild: BTreeMap<(String, String), (String, String)> = BTreeMap::new();

    for p in &pins {
        match p.store {
            Store::GogInstaller => continue, // latest-only slot upstream; there is no version to compare
            Store::GogGalaxy => {
                let product = p.str_field("productId")?.to_string();
                let os = p.opt_str("os").unwrap_or("windows").to_string();
                let cur = p.str_field("buildId")?;
                if opts.mode == Mode::Recompute {
                    // Keep the version, rehash it. `from == to` is what tells `emit` to leave the
                    // identity fields alone and replace only the hash.
                    changes.push(Change {
                        loc: p.loc.clone(),
                        pname: p.opt_str("pname").unwrap_or_default().to_string(),
                        key: "buildId",
                        from: cur.to_string(),
                        to: cur.to_string(),
                        version: None,
                    });
                    continue;
                }
                // Keyed by the CURRENT pin as well as the product: in Update mode the answer depends on
                // which release branch this pin sits on, and a base game and its DLC share both.
                let key = (product.clone(), format!("{os}:{cur}"));
                let (build, version) = match gogbuild.get(&key) {
                    Some(v) => v.clone(),
                    // An explicit `pin.version.gog` names the build to sit at, which may be BEHIND the
                    // newest — that is the point of it, so the backwards guard does not apply here.
                    None if policy.version.contains_key("gog") && opts.mode == Mode::Update => {
                        let want = policy.version["gog"].clone();
                        let all = gog::builds(&product, &os)?;
                        let b = all
                            .iter()
                            .find(|b| b.version_name == want || b.build_id == want)
                            .ok_or_else(|| {
                                gog::GogError::Unsupported(format!(
                                    "{}: pin.version.gog is {want:?}, but {product}/{os} lists no such \
                                     build (GOG returns only its most recent builds; versions seen: {})",
                                    p.loc,
                                    all.iter()
                                        .map(|b| b.version_name.as_str())
                                        .take(8)
                                        .collect::<Vec<_>>()
                                        .join(", ")
                                ))
                            })?;
                        gogbuild.insert(key, (b.build_id.clone(), b.version_name.clone()));
                        (b.build_id.clone(), b.version_name.clone())
                    }
                    None if opts.mode == Mode::Latest => {
                        let want = opts.gog_branch.clone();
                        let all = gog::builds(&product, &os)?;
                        let b = all
                            .iter()
                            .find(|b| b.public && b.branch.as_deref() == want.as_deref())
                            .ok_or_else(|| {
                                gog::GogError::Unsupported(format!(
                                    "{product}/{os} has no public build on branch {want:?} (branches \
                                     offered: {:?})",
                                    all.iter().map(|b| b.branch.clone()).collect::<std::collections::BTreeSet<_>>()
                                ))
                            })?;
                        gogbuild.insert(key, (b.build_id.clone(), b.version_name.clone()));
                        (b.build_id.clone(), b.version_name.clone())
                    }
                    None => {
                        let (newest, current) = gog::newest_on_pinned_branch(&product, &os, cur)?;
                        // NEVER MOVE BACKWARDS. GOG timestamps every build, so compare those rather
                        // than trusting list order or id magnitude. This is defence in depth: the
                        // branch rule above already stops the known way to pick an older build (a pin
                        // on a named release track like Factorio's "Experimental"), but a filter that
                        // can silently downgrade a game is worth guarding twice.
                        if !newest.date_published.is_empty()
                            && !current.date_published.is_empty()
                            && newest.date_published < current.date_published
                        {
                            // Typed, not a bare string: a rollback upstream is a human's call, so this
                            // has to reach CI as Blocked (an issue) rather than as a red run — the same
                            // treatment Steam's rollback refusal already got.
                            return Err(gog::GogError::Unsupported(format!(
                                "{}: refusing to move {} backwards — the newest build on branch {:?} \
                                 is {} ({}, published {}), older than the pinned {} ({}, published {})",
                                p.loc,
                                opts.game,
                                current.branch,
                                newest.build_id,
                                newest.version_name,
                                newest.date_published,
                                current.build_id,
                                current.version_name,
                                current.date_published,
                            ))
                            .into());
                        }
                        gogbuild.insert(key, (newest.build_id.clone(), newest.version_name.clone()));
                        (newest.build_id, newest.version_name)
                    }
                };
                if cur != build {
                    changes.push(Change {
                        loc: p.loc.clone(),
                        pname: p.opt_str("pname").unwrap_or_default().to_string(),
                        key: "buildId",
                        from: cur.to_string(),
                        to: build,
                        version: Some(version),
                    });
                }
            }
            Store::Steam => {
                let app = p.u64_field("appId")? as u32;
                let depot = p.u64_field("depotId")? as u32;
                if opts.mode == Mode::Recompute {
                    let cur = p.str_field("manifestId")?.to_string();
                    changes.push(Change {
                        loc: p.loc.clone(),
                        pname: p.opt_str("pname").unwrap_or_default().to_string(),
                        key: "manifestId",
                        from: cur.clone(),
                        to: cur,
                        version: None,
                    });
                    continue;
                }
                // HOLD SEMANTICS. Steam publishes no version→manifest mapping, so `pin.version.steam`
                // cannot RESOLVE anything — it asserts that the rows are already where they should be.
                // When they are, the pins are simply held: no appinfo request at all (cheaper, and it
                // makes this path testable offline). When one is not, only a human can move it.
                if let (Some(want), Mode::Update) = (policy.version.get("steam"), opts.mode) {
                    if p.opt_str("version") == Some(want.as_str()) {
                        continue;
                    }
                    return Err(steam::SteamError::Unsupported(format!(
                        "{}: pin.version.steam holds {} at {want:?}, but this row says {:?}. Steam \
                         publishes no version→manifest mapping, so this cannot be resolved \
                         automatically: look the build up (e.g. on SteamDB), edit the row's manifestId \
                         and version by hand, then run `propnix pin {} --recompute` — or drop \
                         pin.version.steam to follow upstream again.",
                        p.loc,
                        opts.game,
                        p.opt_str("version").unwrap_or("<unset>"),
                        opts.game,
                    ))
                    .into());
                }
                let branch = steam_branch(opts, p);
                let key = (app, branch.clone());
                if let std::collections::btree_map::Entry::Vacant(e) = appinfo.entry(key.clone()) {
                    e.insert(steam::app_info(app, &branch)?);
                }
                let info = &appinfo[&key];
                let Some(dinfo) = info.depots.get(&depot) else {
                    return Err(steam::SteamError::Unsupported(format!(
                        "{}: depot {depot} of app {app} is no longer listed on branch {branch:?} in \
                         Steam's appinfo — it may have been retired; this pin needs a human",
                        p.loc
                    ))
                    .into());
                };
                let gid = &dinfo.gid;
                let cur = p.str_field("manifestId")?;
                if cur != *gid {
                    changes.push(Change {
                        loc: p.loc.clone(),
                        pname: p.opt_str("pname").unwrap_or_default().to_string(),
                        key: "manifestId",
                        from: cur.to_string(),
                        to: gid.clone(),
                        // Steam has no version strings, but the branch BUILD ID is a real, monotonic
                        // label — without it the Steam column of every PR table and issue is blank.
                        //
                        // AND IT STAYS THE BUILD ID even where a human version looks derivable. Some
                        // vendors keep a version-NAMED branch pointing at the same manifest as their
                        // rolling channel (Factorio: `2.1.17` alongside `experimental`, exact gid match on
                        // every depot), which is tempting to write here instead of an opaque number. It
                        // was tried and rejected: ONE DEPOT CAN CARRY TWO ENGINE VERSIONS. Measured on
                        // Factorio's depot 427523 at the branch labelled 2.1.16, `bin/x64_/factorio`
                        // reports 2.1.16 and `bin/arm64/factorio` reports 2.1.15 — Wube does not rebuild
                        // ARM for every release — so a single per-row version string would be wrong for
                        // whichever ABI that row's `exe` names. The build id is opaque but it is true of
                        // the whole depot, which is what a row actually pins.
                        version: Some(info.build_id.clone()),
                    });
                }
            }
        }
    }
    Ok((
        Report {
            game: opts.game.clone(),
            changes,
            policy,
        },
        file,
    ))
}

/// Recompute every changed pin and return the new file text. Emits nothing unless ALL of them resolve.
pub fn emit(opts: &Opts) -> Result<String, Box<dyn std::error::Error>> {
    let (report, mut file) = check(opts)?;
    let pins = file.pins()?;
    if report.up_to_date() {
        if report.held() {
            eprintln!(
                "  {}: frozen — {}",
                opts.game,
                report.policy.reason.as_deref().unwrap_or("no reason recorded")
            );
        } else if let Some(v) = report.policy.pinned_to() {
            eprintln!("  {}: already at its pinned version {v}", opts.game);
        } else {
            eprintln!("  {}: already at the newest upstream version", opts.game);
        }
        return Ok(file.render());
    }

    let hopts = gog::HashOpts {
        workers: opts.workers,
        window_bytes: opts.window_bytes,
        credential_dir: opts.credential_dir.clone(),
        gog_account: opts.gog_account.clone(),
        steam_account: opts.steam_account.clone(),
        // stdout is a document here; keep the noise on stderr but make it useful.
        progress: true,
    };

    // Stage every recomputation first; only touch the file once all of them succeeded.
    let mut staged: Vec<(PinLoc, Vec<(String, String)>)> = Vec::new();
    // One hash per distinct CONTENT, not per row — see `content_key`.
    let mut hashed_by_content: BTreeMap<String, Hashed> = BTreeMap::new();
    for c in &report.changes {
        let pin = pins
            .iter()
            .find(|p| p.loc == c.loc)
            .ok_or_else(|| format!("{} vanished from versions.json", c.loc))?;
        eprintln!(
            "  {} {} -> {} ({})",
            c.loc,
            &c.from[..c.from.len().min(12)],
            &c.to[..c.to.len().min(12)],
            c.pname
        );
        let mut fields = vec![(c.key.to_string(), c.to.clone())];
        if let Some(v) = &c.version {
            if pin.opt_str("version").is_some() {
                fields.push(("version".to_string(), v.clone()));
            }
        }
        let key = content_key(pin, &c.to, opts);
        let hashed = match hashed_by_content.get(&key) {
            Some(h) => {
                eprintln!("      (identical content to an earlier row — reusing its hash)");
                h.clone()
            }
            None => {
                let h = hash_pin(pin, &c.to, &hopts, opts)?;
                hashed_by_content.insert(key, h.clone());
                h
            }
        };
        fields.push(("outputHash".to_string(), hashed.sri));
        // Record WHICH dependency-repository build this hash was computed against, for a build that
        // installs one into the game dir. `depsBuildId` is on the rewriter's insert allowlist, so a row
        // that has never carried it gains it here rather than the batch being refused.
        if let Some(d) = hashed.deps_build_id {
            fields.push(("depsBuildId".to_string(), d));
        }
        // The Steam cache trust anchors travel WITH the hash they were computed alongside — a row
        // whose outputHash moves gets matching anchors in the same batch, and a pre-anchor row gains
        // them on its first re-pin (both keys are on the insert allowlist).
        if let Some((key_sha, manifest_sha)) = hashed.anchors {
            fields.push(("depotKeySha256".to_string(), key_sha));
            fields.push(("manifestSha256".to_string(), manifest_sha));
        }
        staged.push((c.loc.clone(), fields));
    }

    // One all-or-nothing batch: every key is validated before anything is written.
    let edits: Vec<(PinLoc, String, String)> = staged
        .into_iter()
        .flat_map(|(loc, fields)| fields.into_iter().map(move |(k, v)| (loc.clone(), k, v)))
        .collect();
    file.apply_all(&edits)?;
    Ok(file.render())
}

/// The manifest to compare against for the never-move-backwards guard, or `None` to skip it.
///
/// `--latest` PROMISES to bypass the guard — that is what its help says, and what makes it the escape
/// hatch for a rollback. Passing `previous` regardless meant a public Steam rollback was unrecoverable
/// through the documented route, while GOG's `Latest` arm bypassed correctly: the asymmetry was the bug.
/// In `Update` the guard still applies (and a `pin.version.steam` hold never reaches hashing at all), so
/// nothing is weakened where it matters.
fn previous_manifest(mode: Mode, pin: &Pin) -> Option<u64> {
    match mode {
        Mode::Latest => None,
        _ => pin.str_field("manifestId").ok().and_then(|m| m.parse().ok()),
    }
}

/// One recomputed pin: the hash, plus any provenance the plan discovered that the row should record.
#[derive(Clone)]
struct Hashed {
    sri: String,
    deps_build_id: Option<String>,
    /// Steam cache trust anchors (depotKeySha256, manifestSha256) — recorded so the FOD that fetches
    /// this pin can take the loginless cache path. None for the GOG stores.
    anchors: Option<(String, String)>,
}

/// Identity of the CONTENT a pin resolves to — everything `hash_pin` would feed the hasher, and nothing
/// else. Two rows with the same key name the same bytes, so hashing the second is pure duplicated
/// download: Factorio pins ONE Steam Linux depot under both `aarch64-linux` and `x86_64-linux` (Wube ships
/// both ABIs in depot 427523), which without this streams ~2.3 GiB twice on every version bump. Keyed on
/// the NEW id, so a re-pin still hashes what it is moving to.
fn content_key(pin: &Pin, new_id: &str, opts: &Opts) -> String {
    match pin.store {
        Store::Steam => format!(
            "steam:{}:{}:{}:{}",
            pin.opt_str("appId").unwrap_or_default(),
            pin.opt_str("depotId").unwrap_or_default(),
            new_id,
            steam_branch(opts, pin),
        ),
        Store::GogGalaxy => format!(
            "gog:{}:{}:{}:{}:{}",
            pin.str_field("productId").unwrap_or_default(),
            new_id,
            pin.opt_str("os").unwrap_or("windows"),
            pin.opt_str("lang").unwrap_or("en"),
            pin.dlc_id().unwrap_or_default(),
        ),
        // No version pin at all — never shared, and `hash_pin` refuses it anyway.
        Store::GogInstaller => format!("installer:{}", pin.loc),
    }
}

fn hash_pin(
    pin: &Pin,
    new_id: &str,
    hopts: &gog::HashOpts,
    opts: &Opts,
) -> Result<Hashed, Box<dyn std::error::Error>> {
    let game = &opts.game;
    match pin.store {
        Store::GogInstaller => Err(format!("{}: the GOG installer path has no version pin", pin.loc).into()),
        Store::GogGalaxy => {
            let product = pin.str_field("productId")?;
            let os = pin.opt_str("os").unwrap_or("windows");
            let lang = pin.opt_str("lang").unwrap_or("en");
            let dlc = pin.dlc_id();
            // UseCurrent, never Expect: `propnix pin` MAINTAINS `depsBuildId` rather than asserting it,
            // so a repository that has moved on is recorded, not refused. (`propnix hash gog` keeps the
            // explicit contract — that is the regression harness, where being told is the point.)
            match gog::hash_build(product, new_id, os, lang, dlc, Some(&gog::DepsPin::UseCurrent), hopts)
            {
                Ok((sri, _, plan)) => Ok(Hashed {
                    sri,
                    deps_build_id: plan.deps_build_id,
                    anchors: None,
                }),
                Err(e) => Err(classify(e, pin, game, dlc.is_some())),
            }
        }
        Store::Steam => {
            let app = pin.u64_field("appId")? as u32;
            let depot = pin.u64_field("depotId")? as u32;
            let manifest: u64 = new_id
                .parse()
                .map_err(|_| format!("{}: manifest id {new_id:?} is not a number", pin.loc))?;
            let branch = steam_branch(opts, pin);
            let previous = previous_manifest(opts.mode, pin);
            match steam::hash_depot_any(app, depot, manifest, previous, &branch, hopts) {
                Ok((sri, _, _, anchors)) => Ok(Hashed {
                    sri,
                    deps_build_id: None,
                    anchors: Some((anchors.depot_key_sha256, anchors.manifest_sha256)),
                }),
                Err(e) => Err(classify(e, pin, game, pin.is_dlc())),
            }
        }
    }
}

/// Map a store error onto `Blocked` when it is something only a human can resolve.
///
/// BY TYPE, not by prose. The store modules already carry the semantics in their error enums, and the
/// substring list this replaces was load-bearing in the worst way: rewording any one message silently
/// turned an issue-worthy Blocked into a red run, or — via a "not owned"-shaped transport error — a red
/// run into a FALSE "the account does not own this title" issue. A `match` on the variant cannot drift.
///
/// Shared by the ANONYMOUS discovery pass and the credentialed hash pass on purpose. Discovery has its
/// own human-actionable failures — a pinned GOG build that has aged out of the (paginated) builds list,
/// a depot Steam no longer lists, a fetcher key this binary predates, a construct we refuse to guess at
/// — and if those exited as ordinary errors the weekly run would go red every single week and never
/// file the issue that tells somebody what to do about it.
/// The OUTER Option says whether the error was recognized by type at all; the inner one is that type's
/// verdict. A recognized type is AUTHORITATIVE — its verdict is never second-guessed by reading the
/// prose, which is what stopped `GogError::Http("503 … for a product not owned by …")` from being
/// mistaken for an ownership refusal.
type Verdict = Option<Option<fn(String) -> Blocked>>;

/// Is this error the exit-4 class — "a human must act" (no/stale credential, not owned, refused
/// construct) — rather than a tool/transport failure? `pin` reports these pre-wrapped in [`Blocked`];
/// every other subcommand surfaces the raw store error, so the exit-code mapping consults the same
/// by-type classifier for both. Shared so `steam-probe`/`hash`/`download`/`verify` cannot disagree with
/// `pin` about what a credential problem is.
pub fn is_human_actionable(e: &(dyn std::error::Error + 'static)) -> bool {
    if e.downcast_ref::<Blocked>().is_some() {
        return true;
    }
    matches!(blocked_ctor(e), Some(Some(_)))
}

fn blocked_ctor(e: &(dyn std::error::Error + 'static)) -> Verdict {
    if let Some(g) = e.downcast_ref::<gog::GogError>() {
        return Some(match g {
            gog::GogError::NoCredential(_) => Some(Blocked::NoCredential),
            gog::GogError::NotOwned(_) => Some(Blocked::NotOwned),
            // A rejected token needs a human to re-add a credential, same as Steam's LoginFailed — never a
            // false "not owned".
            gog::GogError::LoginFailed(_) => Some(Blocked::NoCredential),
            gog::GogError::Unsupported(_) => Some(Blocked::Refused),
            // Transport and parse failures are OUR problem, or the CDN's: a red run, so somebody looks.
            gog::GogError::Http(_) | gog::GogError::Parse(_) => None,
        });
    }
    if let Some(s) = e.downcast_ref::<steam::SteamError>() {
        return Some(match s {
            steam::SteamError::NoCredential(_) => Some(Blocked::NoCredential),
            steam::SteamError::NotOwned(_) => Some(Blocked::NotOwned),
            // A refused LOGIN needs a human either way: a stale token wants `cred add steam`, and the
            // rate limiter (which reports throttling as invalid credentials) wants patience — a red
            // run could only retry into the same wall.
            steam::SteamError::LoginFailed(_) => Some(Blocked::NoCredential),
            steam::SteamError::Unsupported(_) => Some(Blocked::Refused),
            steam::SteamError::Http(_) | steam::SteamError::Parse(_) => None,
        });
    }
    if let Some(v) = e.downcast_ref::<versions::Error>() {
        return Some(match v {
            // An older deployed propnix meeting a newer versions.json: upgrade the tool, don't debug it.
            versions::Error::UnknownFetcher(_) => Some(Blocked::Refused),
            _ => None,
        });
    }
    None
}

/// The remaining plain-`String` errors, which carry no type to read. Kept only as a fallback — every
/// new refusal should be a typed store error instead of a phrase added here.
fn blocked_from_message(msg: &str, what: String) -> Option<Blocked> {
    if msg.contains("run `propnix cred") {
        Some(Blocked::NoCredential(what))
    } else if msg.contains("not owned") || msg.contains("not available to this Steam account") {
        Some(Blocked::NotOwned(what))
    } else if msg.contains("refusing to hash") || msg.contains("needs a human") {
        Some(Blocked::Refused(what))
    } else {
        None
    }
}

fn blocked_from(e: &(dyn std::error::Error + 'static), what: String) -> Option<Blocked> {
    match blocked_ctor(e) {
        Some(verdict) => verdict.map(|ctor| ctor(what)),
        None => blocked_from_message(&e.to_string(), what),
    }
}

/// Wrap an anonymous-discovery error: human-actionable ones become `Blocked` (exit 4, an issue), the rest
/// stay ordinary errors (exit 1, a red run — which is then a real bug worth looking at).
fn classify_check(e: Box<dyn std::error::Error>, game: &str) -> Box<dyn std::error::Error> {
    let what = format!("{game}: upstream could not be resolved: {e}");
    match blocked_from(e.as_ref(), what.clone()) {
        Some(b) => Box::new(b),
        None => what.into(),
    }
}

/// Turn a store error into something a human can act on, and mark the all-or-nothing consequence when
/// the failure is a DLC.
fn classify(
    e: Box<dyn std::error::Error>,
    pin: &Pin,
    game: &str,
    is_dlc: bool,
) -> Box<dyn std::error::Error> {
    let what = if is_dlc {
        let name = match &pin.loc {
            PinLoc::Dlc { name } => name.clone(),
            other => other.to_string(),
        };
        format!(
            "DLC {name:?} of {game} could not be re-pinned: {e}\n  \
             Refusing to update {game} at all — moving the base game without its DLC risks a version \
             mismatch at runtime, so this is all-or-nothing."
        )
    } else {
        format!("{game} could not be re-pinned: {e}")
    };
    match blocked_from(e.as_ref(), what.clone()) {
        Some(b) => Box::new(b),
        None => what.into(),
    }
}

/// Every game directory in the repo, in a stable order. The error NAMES the path it tried — a bare
/// "No such file or directory" from a `propnix games` run outside a repo checkout points at nothing.
pub fn all_games(repo: &std::path::Path) -> std::io::Result<Vec<String>> {
    let games = repo.join("pkgs/games");
    let entries = std::fs::read_dir(&games).map_err(|e| {
        std::io::Error::new(
            e.kind(),
            format!("{}: {e} (run from a propnix checkout, or pass --repo)", games.display()),
        )
    })?;
    let mut out = Vec::new();
    for e in entries {
        let e = e?;
        if e.path().join("versions.json").exists() {
            out.push(e.file_name().to_string_lossy().into_owned());
        }
    }
    out.sort();
    Ok(out)
}

/// What to pin, when there is no versions.json yet.
pub enum NewSpec {
    Gog {
        product_id: String,
        os: String,
        lang: String,
        platform: Option<String>,
        dlc: Vec<(String, String)>,
    },
    Steam {
        app: u32,
        depots: Vec<u32>,
        platform: Option<String>,
    },
}

/// Emit a versions.json for a game that does not have one yet — the expensive half of adding a game.
///
/// Resolving the newest build and hashing it is the part a human cannot do by hand; the `pname`s and the
/// GOG `version` string this produces are reasonable placeholders, not house style, so rename them.
pub fn scaffold(opts: &Opts, spec: &NewSpec) -> Result<String, Box<dyn std::error::Error>> {
    let hopts = gog::HashOpts {
        workers: opts.workers,
        window_bytes: opts.window_bytes,
        credential_dir: opts.credential_dir.clone(),
        gog_account: opts.gog_account.clone(),
        steam_account: opts.steam_account.clone(),
        progress: true,
    };
    let mut root = serde_json::Map::new();
    let mut fetch_info = serde_json::Map::new();

    match spec {
        NewSpec::Gog {
            product_id,
            os,
            lang,
            platform,
            dlc,
        } => {
            let want = opts.gog_branch.clone();
            let all = gog::builds(product_id, os)?;
            let b = all
                .iter()
                .find(|b| b.public && b.branch.as_deref() == want.as_deref())
                .ok_or_else(|| {
                    format!("{product_id}/{os} has no public build on branch {want:?}")
                })?;
            let platform = platform.clone().unwrap_or_else(|| default_platform(os));
            eprintln!(
                "  {} build {} ({}) on branch {:?}",
                product_id, b.build_id, b.version_name, b.branch
            );

            // `depsBuildId` is only written when the build actually installs a dependency INTO the
            // game dir — that is the only case where buildId alone does not determine the tree.
            let with_deps = |mut row: serde_json::Value, deps: &Option<String>| {
                if let (serde_json::Value::Object(m), Some(d)) = (&mut row, deps) {
                    m.insert("depsBuildId".into(), serde_json::Value::String(d.clone()));
                }
                row
            };

            let mut rows = Vec::new();
            let (sri, _, plan) = gog::hash_build(
                product_id,
                &b.build_id,
                os,
                lang,
                None,
                Some(&gog::DepsPin::UseCurrent),
                &hopts,
            )?;
            rows.push(with_deps(
                gog_row(
                    &format!("{}-{}", opts.game, short_os(os)),
                    product_id,
                    &b.build_id,
                    &b.version_name,
                    &sri,
                    os,
                    lang,
                    "game",
                ),
                &plan.deps_build_id,
            ));
            fetch_info.insert(
                "gog".into(),
                serde_json::json!({ platform.clone(): serde_json::Value::Array(rows) }),
            );

            if !dlc.is_empty() {
                let mut dlc_map = serde_json::Map::new();
                for (name, id) in dlc {
                    let (sri, _, dplan) = gog::hash_build(
                        product_id,
                        &b.build_id,
                        os,
                        lang,
                        Some(id),
                        Some(&gog::DepsPin::UseCurrent),
                        &hopts,
                    )?;
                    let mut row = gog_row(
                        &format!("{}-{}-{}", opts.game, name, short_os(os)),
                        product_id,
                        &b.build_id,
                        &b.version_name,
                        &sri,
                        os,
                        lang,
                        "dlc",
                    );
                    // dlcId sits between `version` and `outputHash` in the existing files.
                    if let serde_json::Value::Object(m) = &mut row {
                        m.insert("dlcId".into(), serde_json::Value::String(id.clone()));
                    }
                    dlc_map.insert(name.clone(), with_deps(row, &dplan.deps_build_id));
                }
                root.insert("dlc".into(), serde_json::Value::Object(dlc_map));
            }
        }
        NewSpec::Steam {
            app,
            depots,
            platform,
        } => {
            let branch = opts.branch.clone().unwrap_or_else(|| "public".to_string());
            let info = steam::app_info(*app, &branch)?;
            let mut by_platform: BTreeMap<String, Vec<serde_json::Value>> = BTreeMap::new();
            for depot in depots {
                let d = info.depots.get(depot).ok_or_else(|| {
                    format!("depot {depot} is not listed among app {app}'s depots on branch {branch:?}")
                })?;
                let manifest: u64 = d.gid.parse()?;
                let plat = platform
                    .clone()
                    .unwrap_or_else(|| default_platform(d.oslist.as_deref().unwrap_or("windows")));
                eprintln!("  app {app} depot {depot} manifest {} ({plat})", d.gid);
                let (sri, _, _, anchors) =
                    steam::hash_depot_any(*app, *depot, manifest, None, &branch, &hopts)?;
                let mut row = serde_json::json!({
                    "pname": format!("{}-{}", opts.game, depot),
                    "appId": app,
                    "depotId": depot,
                    "manifestId": d.gid,
                    // Steam publishes no version strings, so the branch BUILD ID is the initial value.
                    // A human may overwrite it with a marketing string ("1.5.78.11"); that survives
                    // until the pin next MOVES, and a `pin.version.steam` hold never moves.
                    "version": info.build_id,
                    "outputHash": sri,
                    // The cache trust anchors (pin/steamcache.rs): with these on the row, the FOD can
                    // fetch this pin without a single Steam login when the cache is warm.
                    "depotKeySha256": anchors.depot_key_sha256,
                    "manifestSha256": anchors.manifest_sha256,
                    "title": format!("{} ({}, Steam)", opts.game, d.oslist.as_deref().unwrap_or("?")),
                });
                // A public pin carries no `branch` key at all — absent IS public, and every existing
                // row must stay byte-identical.
                if branch != "public" {
                    if let serde_json::Value::Object(m) = &mut row {
                        m.insert("branch".into(), serde_json::Value::String(branch.clone()));
                    }
                }
                by_platform.entry(plat).or_default().push(row);
            }
            let mut m = serde_json::Map::new();
            for (k, v) in by_platform {
                m.insert(k, serde_json::Value::Array(v));
            }
            fetch_info.insert("steam".into(), serde_json::Value::Object(m));
        }
    }

    // `fetchInfo` first, then `dlc` — the order every existing versions.json uses.
    let mut out = serde_json::Map::new();
    out.insert("fetchInfo".into(), serde_json::Value::Object(fetch_info));
    if let Some(d) = root.remove("dlc") {
        out.insert("dlc".into(), d);
    }
    let mut text = serde_json::to_string_pretty(&serde_json::Value::Object(out))?;
    text.push('\n');
    Ok(text)
}

#[allow(clippy::too_many_arguments)]
fn gog_row(
    pname: &str,
    product_id: &str,
    build_id: &str,
    version: &str,
    hash: &str,
    os: &str,
    lang: &str,
    kind: &str,
) -> serde_json::Value {
    serde_json::json!({
        "pname": pname,
        "productId": product_id,
        "buildId": build_id,
        "version": version,
        "outputHash": hash,
        "outputHashMode": "recursive",
        "os": os,
        "lang": lang,
        "kind": kind,
        "generation": 2,
    })
}

/// propnix's emulatedPlatform for a store's OS name. i386-windows exists too, but nothing upstream says
/// a build is 32-bit — pass `--platform` for those.
fn default_platform(os: &str) -> String {
    match os {
        "linux" => "x86_64-linux",
        _ => "x86_64-windows",
    }
    .to_string()
}

fn short_os(os: &str) -> &str {
    match os {
        "windows" => "win",
        "osx" | "mac" | "macos" => "osx",
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Factorio pins ONE Steam Linux depot under two platform keys (Wube ships both ABIs in depot 427523),
    /// so the refresher must recognise them as the same content and stream it once, not twice.
    #[test]
    fn rows_naming_the_same_depot_share_one_content_key() {
        let body = r#"{
  "fetchInfo": {
    "steam": {
      "aarch64-linux": [ { "pname": "f-linux", "appId": 427520, "depotId": 427523,
        "manifestId": "111", "branch": "experimental", "outputHash": "sha256-a" } ],
      "x86_64-linux": [ { "pname": "f-linux", "appId": 427520, "depotId": 427523,
        "manifestId": "111", "branch": "experimental", "outputHash": "sha256-a" } ],
      "x86_64-windows": [ { "pname": "f-win", "appId": 427520, "depotId": 427521,
        "manifestId": "222", "branch": "experimental", "outputHash": "sha256-b" } ]
    }
  }
}"#;
        let d = std::env::temp_dir().join(format!("propnix-ck-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let path = d.join("versions.json");
        std::fs::write(&path, body).unwrap();
        let f = VersionsFile::load(&path).unwrap();
        let pins = f.pins().unwrap();
        let opts = Opts {
            repo: d.clone(),
            game: "factorio".into(),
            credential_dir: d.clone(),
            workers: 1,
            window_bytes: 1,
            branch: None,
            mode: Mode::Update,
            gog_branch: None,
            gog_account: None,
            steam_account: None,
        };

        let keys: Vec<String> = pins
            .iter()
            .map(|p| content_key(p, p.opt_str("manifestId").unwrap(), &opts))
            .collect();
        assert_eq!(keys[0], keys[1], "the two Linux rows name the same depot: {keys:?}");
        assert_ne!(keys[0], keys[2], "the Windows depot is different content: {keys:?}");
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn a_report_serializes_what_ci_reads() {
        let r = Report {
            game: "factorio".into(),
            policy: Policy::default(),
            changes: vec![Change {
                loc: PinLoc::Dlc { name: "space-age".into() },
                pname: "factorio-space-age-win".into(),
                key: "buildId",
                from: "111".into(),
                to: "222".into(),
                version: Some("2.1.15".into()),
            }],
        };
        assert!(!r.up_to_date());
        let j: serde_json::Value = serde_json::from_str(&r.to_json()).unwrap();
        assert_eq!(j["upToDate"], false);
        assert_eq!(j["changes"][0]["where"], "dlc.space-age");
        assert_eq!(j["changes"][0]["key"], "buildId");
    }

    #[test]
    fn a_frozen_report_is_up_to_date_but_held() {
        let r = Report {
            game: "kerbal-space-program".into(),
            changes: vec![],
            policy: Policy::frozen_for_test("1.12.5 is the last build the mod stack supports"),
        };
        assert!(r.up_to_date());
        assert!(r.held(), "CI must be able to tell 'held' from 'nothing to do'");
        let j: serde_json::Value = serde_json::from_str(&r.to_json()).unwrap();
        assert_eq!(j["frozen"], true);
        assert_eq!(j["policyReason"], "1.12.5 is the last build the mod stack supports");
    }

    #[test]
    fn an_empty_report_is_up_to_date() {
        let r = Report { game: "x".into(), changes: vec![], policy: Policy::default() };
        assert!(r.up_to_date());
        let j: serde_json::Value = serde_json::from_str(&r.to_json()).unwrap();
        assert_eq!(j["upToDate"], true);
        assert_eq!(j["changes"].as_array().unwrap().len(), 0);
        // `blocked`/`detail` are on EVERY report, so `pin-issue.sh` can read them unconditionally.
        assert_eq!(j["blocked"], false);
        assert!(j["detail"].is_null());
    }

    #[test]
    fn a_multi_store_pin_renders_one_human_string() {
        let r = Report {
            game: "hollow-knight".into(),
            changes: vec![],
            policy: Policy::for_test(&[("gog", "1.5.12620"), ("steam", "1.5.78.11")], "held"),
        };
        let j: serde_json::Value = serde_json::from_str(&r.to_json()).unwrap();
        // `pinnedTo` is string-interpolated by ci/pin-refresh.sh, so it must stay a scalar.
        assert_eq!(j["pinnedTo"], "gog=1.5.12620 steam=1.5.78.11");
    }

    #[test]
    fn a_blocked_check_still_emits_a_report() {
        // Exiting 4 with empty stdout used to take the whole weekly run down (zero-byte check.json →
        // pin-issue.sh dies under set -e → no issues, no commits, no PR).
        let j: serde_json::Value =
            serde_json::from_str(&blocked_report_json("no-mans-sky", "aged out of the builds list"))
                .unwrap();
        assert_eq!(j["game"], "no-mans-sky");
        assert_eq!(j["blocked"], true);
        assert_eq!(j["upToDate"], false);
        assert_eq!(j["frozen"], false);
        assert_eq!(j["detail"], "aged out of the builds list");
        assert_eq!(j["changes"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn errors_are_classified_by_type_not_by_prose() {
        let what = || "what".to_string();
        let ck = |e: Box<dyn std::error::Error>| {
            blocked_from(e.as_ref(), what()).map(|b| match b {
                Blocked::NoCredential(_) => "cred",
                Blocked::NotOwned(_) => "owned",
                Blocked::Refused(_) => "refused",
            })
        };
        assert_eq!(ck(Box::new(gog::GogError::NoCredential("x".into()))), Some("cred"));
        assert_eq!(ck(Box::new(gog::GogError::NotOwned("x".into()))), Some("owned"));
        assert_eq!(ck(Box::new(gog::GogError::Unsupported("x".into()))), Some("refused"));
        assert_eq!(ck(Box::new(steam::SteamError::NoCredential("x".into()))), Some("cred"));
        assert_eq!(ck(Box::new(steam::SteamError::Unsupported("x".into()))), Some("refused"));
        // A refused/expired LOGIN is a credential problem for BOTH stores — never a false "not owned",
        // which is how throttled walks once filed bogus ownership issues.
        assert_eq!(ck(Box::new(steam::SteamError::LoginFailed("throttled".into()))), Some("cred"));
        assert_eq!(ck(Box::new(gog::GogError::LoginFailed("rejected".into()))), Some("cred"));
        // A fetcher key this binary predates is a human/upgrade problem, not a tool bug.
        assert_eq!(
            ck(Box::new(versions::Error::UnknownFetcher("unknown fetcher \"epic\"".into()))),
            Some("refused")
        );
        // Transport and parse failures stay RED — including ones whose text mentions ownership, which
        // is exactly what the old substring classifier got wrong.
        assert_eq!(ck(Box::new(gog::GogError::Http("503 for a product not owned by …".into()))), None);
        assert_eq!(ck(Box::new(steam::SteamError::Parse("truncated".into()))), None);
        assert_eq!(ck(Box::new(versions::Error::Schema("missing productId".into()))), None);
    }

    #[test]
    fn only_latest_bypasses_the_never_backwards_guard() {
        let mut obj = serde_json::Map::new();
        obj.insert("manifestId".into(), serde_json::Value::String("12345".into()));
        let pin = Pin {
            loc: PinLoc::Payload {
                fetcher: "steam".into(),
                platform: "x86_64-linux".into(),
                index: 0,
            },
            store: Store::Steam,
            obj,
        };
        assert_eq!(previous_manifest(Mode::Update, &pin), Some(12345));
        assert_eq!(previous_manifest(Mode::Recompute, &pin), Some(12345));
        assert_eq!(
            previous_manifest(Mode::Latest, &pin),
            None,
            "--latest promises to bypass the guard; passing `previous` made a Steam rollback \
             unrecoverable through the documented escape hatch"
        );
    }

    /// A synthetic steam-only game whose rows all sit at the held version. `--check` must report it
    /// up-to-date WITHOUT any network at all — which is the point of the hold, and why this test can
    /// exist offline.
    #[test]
    fn a_held_steam_pin_needs_no_network() {
        let dir = std::env::temp_dir().join(format!(
            "propnix-pin-hold-{}-{:?}/pkgs/games/heldgame",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let body = r#"{
  "pin": { "version": { "steam": "4.4.6" }, "reason": "4.5 breaks the mod stack" },
  "fetchInfo": {
    "steam": {
      "x86_64-linux": [
        { "pname": "held-a", "appId": 281990, "depotId": 281994,
          "manifestId": "290069498413929006", "version": "4.4.6", "outputHash": "sha256-A=",
          "title": "Held (Linux, Steam)" },
        { "pname": "held-b", "appId": 281990, "depotId": 281991,
          "manifestId": "3922771984290037884", "version": "4.4.6", "outputHash": "sha256-B=",
          "title": "Held (Linux, Steam)" }
      ]
    }
  }
}
"#;
        std::fs::write(dir.join("versions.json"), body).unwrap();
        let repo = dir.parent().unwrap().parent().unwrap().parent().unwrap().to_path_buf();
        let opts = Opts {
            repo,
            game: "heldgame".into(),
            credential_dir: std::path::PathBuf::from("/nonexistent"),
            workers: 1,
            window_bytes: 1 << 20,
            branch: None,
            mode: Mode::Update,
            gog_branch: None,
            gog_account: None,
            steam_account: None,
        };
        let (report, _) = check(&opts).expect("a held pin must resolve with no network");
        assert!(report.up_to_date());
        assert_eq!(report.policy.pinned_to().as_deref(), Some("steam=4.4.6"));

        // One row moved out from under the hold: Blocked, with the manual fix spelled out.
        std::fs::write(
            dir.join("versions.json"),
            body.replace("\"version\": \"4.4.6\", \"outputHash\": \"sha256-B=\"", "\"version\": \"4.5.0\", \"outputHash\": \"sha256-B=\""),
        )
        .unwrap();
        let Err(e) = check(&opts) else {
            panic!("a row outside the hold must be refused");
        };
        assert!(
            e.downcast_ref::<Blocked>().is_some(),
            "a hold mismatch is a human's job, not a red run: {e}"
        );
        let msg = e.to_string();
        assert!(msg.contains("--recompute"), "must say what to do; got: {msg}");
        assert!(msg.contains("manifestId"), "must name the field to edit; got: {msg}");
    }
}
