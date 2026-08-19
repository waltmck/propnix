//! `propnix` — the propnix CLI. Two command groups:
//!   * `propnix cred …` manages the account credentials the payload fetchers consume (see `store.rs`;
//!     the store lives at `/var/lib/propnix`, bound into the Nix build sandbox at `/propnix`).
//!   * `propnix pin …` recomputes the content pins in `pkgs/games/*/versions.json` by streaming, so a
//!     re-pin costs O(1) disk instead of a full copy of the game (see `pin/`).
//!
//! `propnix hash …` exposes the individual hashers underneath `pin`, which is what the regression
//! harnesses drive.

mod cred;
mod pin;

use clap::{Args, Parser, Subcommand};
use std::process::ExitCode;
use cred::store::CredStore;

#[derive(Parser)]
#[command(
    name = "propnix",
    about = "propnix — manage the payload fetchers' account credentials (`cred`) and refresh the \
             content pins in pkgs/games/*/versions.json (`pin`)",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Manage stored account credentials (used by the credentialed payload fetchers).
    Cred {
        #[command(subcommand)]
        action: CredAction,
    },
    /// Rewrite one game's versions.json in place, moving its pins to the newest upstream build.
    ///
    /// A game is re-pinned as a UNIT — base payloads and every DLC, or nothing — because moving a base
    /// game forward while a DLC stays behind is exactly the mismatch that breaks at runtime.
    Pin(PinArgs),
    /// List the game directories that carry a versions.json.
    Games {
        #[arg(long, default_value = ".")]
        repo: std::path::PathBuf,
    },
    /// Compute a single payload's hash directly (diagnostics and regression tests).
    Hash {
        #[command(subcommand)]
        what: HashCmd,
    },
}

/// `propnix pin`'s flags. A flattenable `Args` struct rather than an inline variant, so the twenty-odd
/// fields exist ONCE — the previous shape declared them in the subcommand and again in a mirror struct,
/// and the two could silently drift apart.
#[derive(Args)]
struct PinArgs {
    /// Game directory name under pkgs/games/.
    #[arg(value_name = "GAME")]
    game: String,
    /// Repository root.
    #[arg(long, default_value = ".")]
    repo: std::path::PathBuf,
    /// Only report whether upstream has moved, as JSON. Anonymous — needs no credential.
    #[arg(long, conflicts_with_all = ["recompute", "latest", "new", "stdout"])]
    check: bool,
    /// Write the new document to stdout instead of rewriting versions.json in place.
    #[arg(long)]
    stdout: bool,
    /// Keep the version currently pinned but recompute its outputHash from scratch, ignoring the
    /// recorded one. Use this when a pin's hash looks wrong: it answers "what SHOULD this be?"
    /// without moving the game to a new version.
    #[arg(long, conflicts_with_all = ["latest", "new"])]
    recompute: bool,
    /// Ignore the recorded build/manifest AND the release branch it implies; go to the newest build
    /// and rehash. Bypasses the never-move-backwards guard, so it can move a game onto a different
    /// release track — say which with --gog-branch.
    #[arg(long, conflicts_with = "new")]
    latest: bool,
    /// Pin a game that has NO versions.json yet, from the identity flags below. This is the
    /// expensive half of adding a game: resolving the newest build and hashing it.
    #[arg(long)]
    new: bool,
    /// GOG release track to use in --latest / --new mode. Omit for the default (unnamed) branch.
    #[arg(long)]
    gog_branch: Option<String>,
    /// Which stored GOG account to use. Default: PROPNIX_GOG_ACCOUNT, else try every stored account
    /// until one owns the title (what the fetchers do).
    #[arg(long)]
    gog_account: Option<String>,
    /// Which stored Steam account to use. Default: PROPNIX_STEAM_ACCOUNT, else try every stored
    /// account until one owns the depot.
    #[arg(long)]
    steam_account: Option<String>,
    /// --new: pin a GOG Galaxy product.
    #[arg(long, requires = "new")]
    gog: bool,
    /// --new --gog: the numeric GOG product id.
    #[arg(long, requires = "gog")]
    product_id: Option<String>,
    #[arg(long, default_value = "windows", requires = "gog")]
    os: String,
    #[arg(long, default_value = "en", requires = "gog")]
    lang: String,
    /// --new --gog: a DLC to pin alongside the base game, as NAME=DLCID. Repeatable.
    #[arg(long = "dlc", requires = "gog", value_parser = parse_dlc)]
    dlc: Vec<(String, String)>,
    /// --new: pin a Steam app.
    #[arg(long, requires = "new")]
    steam: bool,
    /// --new --steam: the Steam AppID.
    #[arg(long, requires = "steam")]
    app: Option<u32>,
    /// --new --steam: a depot to pin. Repeatable.
    #[arg(long = "depot", requires = "steam")]
    depots: Vec<u32>,
    /// Override the propnix emulatedPlatform the scaffolded rows land under (e.g. i386-windows).
    #[arg(long, requires = "new")]
    platform: Option<String>,
    #[arg(long, default_value_t = 32)]
    workers: usize,
    #[arg(long, default_value_t = 128)]
    window_mib: u64,
    /// Steam branch, overriding each row's own `branch`. Omit to use the row's (absent = public).
    #[arg(long)]
    branch: Option<String>,
}

#[derive(Subcommand)]
enum HashCmd {
    /// Hash a LOCAL directory the way Nix would — checks this tool against `nix hash path`.
    Path {
        path: std::path::PathBuf,
        #[arg(long)]
        expect: Option<String>,
    },
    /// Hash a GOG Galaxy build by streaming.
    Gog {
        #[arg(long)]
        product_id: String,
        #[arg(long)]
        build_id: String,
        #[arg(long, default_value = "windows")]
        os: String,
        #[arg(long, default_value = "en")]
        lang: String,
        #[arg(long)]
        dlc_id: Option<String>,
        /// Acknowledge the global dependency-repository build, for titles that install a dependency
        /// INTO the game directory (their tree is not pinned by buildId alone).
        #[arg(long)]
        deps_build_id: Option<String>,
        #[arg(long)]
        expect: Option<String>,
        #[arg(long, default_value_t = 32)]
        workers: usize,
        #[arg(long, default_value_t = 128)]
        window_mib: u64,
    },
    /// Hash a Steam depot by streaming.
    Steam {
        #[arg(long)]
        app: u32,
        #[arg(long)]
        depot: u32,
        #[arg(long)]
        manifest: u64,
        #[arg(long, default_value = "public")]
        branch: String,
        /// Use Steam's anonymous account (free / anonymous-entitled depots only).
        #[arg(long)]
        anonymous: bool,
        /// Which stored Steam account to use, when the credential holds more than one.
        #[arg(long)]
        steam_account: Option<String>,
        #[arg(long)]
        expect: Option<String>,
        #[arg(long, default_value_t = 32)]
        workers: usize,
        #[arg(long, default_value_t = 128)]
        window_mib: u64,
    },
}

#[derive(Subcommand)]
enum CredAction {
    /// List stored credentials, grouped by account type and labelled by username.
    List,
    /// Add an account of the given type (e.g. `gog`) via an interactive browser login.
    Add {
        /// Account type: `gog` (more later).
        #[arg(value_name = "TYPE")]
        r#type: String,
    },
    /// Remove a stored account by username. If the same username exists under multiple account types (e.g. a
    /// GOG and a Steam `alice`), pass `--type` to say which.
    Rm {
        /// Account type, to disambiguate a username stored under more than one backend (e.g. `gog`, `steam`).
        #[arg(short = 't', long = "type", value_name = "TYPE")]
        r#type: Option<String>,
        #[arg(value_name = "USERNAME")]
        username: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result: Result<(), Box<dyn std::error::Error>> = match cli.command {
        Command::Cred { action } => match action {
            CredAction::List => cmd_list().map_err(Into::into),
            CredAction::Add { r#type } => cmd_add(&r#type).map_err(Into::into),
            CredAction::Rm { r#type, username } => {
                cmd_rm(&username, r#type.as_deref()).map_err(Into::into)
            }
        },
        Command::Games { repo } => pin::all_games(&repo)
            .map(|gs| gs.iter().for_each(|g| println!("{g}")))
            .map_err(Into::into),
        Command::Pin(args) => cmd_pin(args),
        Command::Hash { what } => cmd_hash(what),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("propnix: {e}");
            // Exit 4 means "a human needs to act" — no credential, the account does not own the title,
            // or a construct we refuse to guess at — as opposed to 1, which means the tool itself hit
            // something unexpected. CI uses the distinction to open an issue instead of failing.
            if e.downcast_ref::<pin::Blocked>().is_some() {
                ExitCode::from(4)
            } else {
                ExitCode::FAILURE
            }
        }
    }
}

/// The credential store root, honouring the same env override `propnix cred` uses.
fn cred_dir() -> std::path::PathBuf {
    CredStore::from_env().root().to_path_buf()
}

/// NAME=DLCID for `--dlc`.
fn parse_dlc(s: &str) -> Result<(String, String), String> {
    s.split_once('=')
        .map(|(n, i)| (n.to_string(), i.to_string()))
        .ok_or_else(|| format!("expected NAME=DLCID, got {s:?}"))
}

/// An account selection from the environment, ignoring an empty value (CI sets these unconditionally).
fn env_account(var: &str) -> Option<String> {
    std::env::var(var).ok().filter(|s| !s.trim().is_empty())
}

fn cmd_pin(a: PinArgs) -> Result<(), Box<dyn std::error::Error>> {
    let opts = pin::Opts {
        repo: a.repo,
        game: a.game,
        credential_dir: cred_dir(),
        workers: a.workers,
        window_bytes: a.window_mib * 1024 * 1024,
        branch: a.branch,
        mode: if a.recompute {
            pin::Mode::Recompute
        } else if a.latest {
            pin::Mode::Latest
        } else {
            pin::Mode::Update
        },
        gog_branch: a.gog_branch,
        // Precedence: flag > env > try every stored account.
        gog_account: a.gog_account.or_else(|| env_account("PROPNIX_GOG_ACCOUNT")),
        steam_account: a.steam_account.or_else(|| env_account("PROPNIX_STEAM_ACCOUNT")),
    };
    if a.new {
        // Refuse BEFORE the expensive resolve-and-hash, not at landing time. A scaffold is generic
        // placeholders, and — since `pin` writes in place — landing one over an existing versions.json
        // would silently replace the curated file: dlc entries, the pin policy, house-style pnames.
        // Updating an existing game is plain `propnix pin <game>`; `--stdout` still previews freely.
        if !a.stdout {
            let path = pin::versions_path(&opts.repo, &opts.game);
            if path.exists() {
                return Err(format!(
                    "{} already exists — refusing to scaffold over it. Run `propnix pin {}` to update \
                     the existing pins, or add --stdout to preview a fresh scaffold without writing.",
                    path.display(),
                    opts.game
                )
                .into());
            }
        }
        let spec = match (a.gog, a.steam) {
            (true, false) => pin::NewSpec::Gog {
                product_id: a
                    .product_id
                    .ok_or("--new --gog needs --product-id")?,
                os: a.os,
                lang: a.lang,
                platform: a.platform,
                dlc: a.dlc,
            },
            (false, true) => {
                if a.depots.is_empty() {
                    return Err("--new --steam needs at least one --depot".into());
                }
                pin::NewSpec::Steam {
                    app: a.app.ok_or("--new --steam needs --app")?,
                    depots: a.depots,
                    platform: a.platform,
                }
            }
            _ => return Err("--new needs exactly one of --gog or --steam".into()),
        };
        let doc = pin::scaffold(&opts, &spec)?;
        return land(&opts, &doc, a.stdout, true);
    }
    if a.check {
        return match pin::check(&opts) {
            Ok((report, _)) => {
                println!("{}", report.to_json());
                Ok(())
            }
            Err(e) => {
                // A check that ends Blocked STILL OWES CI A REPORT. Exiting 4 with empty stdout left
                // ci/pin-refresh.sh with a zero-byte check.json, on which ci/pin-issue.sh died under
                // `set -e` — taking the issues step and every step after it down with it. Non-Blocked
                // errors still print nothing: those are red runs, not issues.
                if e.downcast_ref::<pin::Blocked>().is_some() {
                    println!("{}", pin::blocked_report_json(&opts.game, &e.to_string()));
                }
                Err(e)
            }
        };
    }
    let doc = pin::emit(&opts)?;
    land(&opts, &doc, a.stdout, false)
}

/// Land the emitted document.
///
/// IN PLACE by default. The invocation this replaces — `propnix pin <game> > versions.json` — truncated
/// its own INPUT before the process even started, so it was a guaranteed parse failure plus a zero-byte
/// versions.json. `--stdout` keeps the pipe form for callers that want to validate before swapping
/// (ci/pin-refresh.sh does).
///
/// The write is temp-file + SAME-DIRECTORY rename: atomic, no EXDEV, and a run that dies half way can
/// never leave a partially written pin behind. An up-to-date run writes NOTHING — not even an mtime
/// touch — so `git diff` and every mtime-driven cache stay honest.
fn land(
    opts: &pin::Opts,
    doc: &str,
    to_stdout: bool,
    create_dir: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if to_stdout {
        print!("{doc}");
        return Ok(());
    }
    let path = pin::versions_path(&opts.repo, &opts.game);
    let dir = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    if create_dir {
        std::fs::create_dir_all(dir)?;
    }
    if std::fs::read_to_string(&path).is_ok_and(|old| old == doc) {
        eprintln!("  {}: unchanged — {} left untouched", opts.game, path.display());
        return Ok(());
    }
    let tmp = dir.join(format!(".versions.json.tmp-{}", std::process::id()));
    std::fs::write(&tmp, doc)?;
    if let Err(e) = std::fs::rename(&tmp, &path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(Box::new(e));
    }
    eprintln!("  wrote {}", path.display());
    Ok(())
}

fn cmd_hash(what: HashCmd) -> Result<(), Box<dyn std::error::Error>> {
    use pin::{gog, nar, steam};
    let check = |sri: String, expect: Option<String>| -> Result<(), Box<dyn std::error::Error>> {
        println!("{sri}");
        if let Some(want) = expect {
            if want != sri {
                return Err(format!("MISMATCH: expected {want}, computed {sri}").into());
            }
            eprintln!("  matches the pinned hash");
        }
        Ok(())
    };
    match what {
        HashCmd::Path { path, expect } => {
            let tree = nar::local_tree(&path)?;
            let (sri, stats) = nar::nar_hash(&tree, |p, w| nar::local_fetch(p, w))?;
            eprintln!(
                "  {} files, {} dirs, {} symlinks, {} content bytes",
                stats.files, stats.dirs, stats.links, stats.content_bytes
            );
            check(sri, expect)
        }
        HashCmd::Gog {
            product_id,
            build_id,
            os,
            lang,
            dlc_id,
            deps_build_id,
            expect,
            workers,
            window_mib,
        } => {
            let opts = gog::HashOpts {
                workers,
                window_bytes: window_mib * 1024 * 1024,
                credential_dir: cred_dir(),
                gog_account: env_account("PROPNIX_GOG_ACCOUNT"),
                steam_account: None,
                progress: true,
            };
            // `Expect` when the flag is given, and NO DepsPin at all when it is not: the harness
            // contract is to be explicit about a tree buildId does not pin, so a bare `hash gog` on
            // such a build is refused with the current repository build named. (`propnix pin` passes
            // `UseCurrent` instead — it MAINTAINS the recorded value rather than asserting it.)
            let deps = deps_build_id.map(gog::DepsPin::Expect);
            let (sri, stats, plan) = gog::hash_build(
                &product_id,
                &build_id,
                &os,
                &lang,
                dlc_id.as_deref(),
                deps.as_ref(),
                &opts,
            )?;
            eprintln!(
                "  installDirectory={:?} {} files, {} dirs, {} content bytes",
                plan.install_directory, stats.files, stats.dirs, stats.content_bytes
            );
            check(sri, expect)
        }
        HashCmd::Steam {
            app,
            depot,
            manifest,
            branch,
            anonymous,
            steam_account,
            expect,
            workers,
            window_mib,
        } => {
            let account = steam_account.or_else(|| env_account("PROPNIX_STEAM_ACCOUNT"));
            let opts = gog::HashOpts {
                workers,
                window_bytes: window_mib * 1024 * 1024,
                credential_dir: cred_dir(),
                gog_account: None,
                steam_account: account.clone(),
                progress: true,
            };
            let (sri, stats, _) = if anonymous {
                steam::hash_depot(
                    app,
                    depot,
                    manifest,
                    None,
                    &branch,
                    steam::Auth::Anonymous,
                    &opts,
                )?
            } else {
                steam::hash_depot_any(app, depot, manifest, None, &branch, &opts)?
            };
            eprintln!(
                "  {} files, {} dirs, {} content bytes",
                stats.files, stats.dirs, stats.content_bytes
            );
            check(sri, expect)
        }
    }
}

fn cmd_list() -> Result<(), String> {
    let store = CredStore::from_env();
    let listing = store.list();
    if listing.is_empty() {
        println!("No credentials stored ({}).", store.root().display());
        println!("Add one with: propnix cred add gog");
        return Ok(());
    }
    for t in &listing {
        // Label the type by its provider's display name when known, else the raw dir name.
        let label = cred::provider::by_name(&t.type_name)
            .map(|p| p.display_name().to_string())
            .unwrap_or_else(|| t.type_name.clone());
        println!("{label}:");
        if t.usernames.is_empty() {
            println!("  (none)");
        } else {
            for u in &t.usernames {
                // Flag the ones materialized from the host's configuration: `cred rm` won't remove those,
                // and re-adding one with `cred add` would be overwritten at the next activation.
                if store.is_declarative(&t.type_name, u) {
                    println!("  - {u} (declarative)");
                } else {
                    println!("  - {u}");
                }
            }
        }
    }
    Ok(())
}

fn cmd_add(type_name: &str) -> Result<(), String> {
    let provider = cred::provider::by_name(type_name).ok_or_else(|| {
        format!(
            "unknown account type '{type_name}' (valid: {})",
            cred::provider::type_names().join(", ")
        )
    })?;
    let store = CredStore::from_env();
    let cred = provider.login()?;
    store.put(
        provider.type_name(),
        &cred.username,
        provider.token_filename(),
        &cred.token,
    )?;
    println!(
        "propnix: added {} account '{}' → {}/{}/{}/{}",
        provider.display_name(),
        cred.username,
        store.root().display(),
        provider.type_name(),
        cred.username,
        provider.token_filename(),
    );
    Ok(())
}

fn cmd_rm(username: &str, type_filter: Option<&str>) -> Result<(), String> {
    let store = CredStore::from_env();
    let removed_type = store.remove(username, type_filter)?;
    println!("propnix: removed {removed_type} account '{username}'");
    Ok(())
}
