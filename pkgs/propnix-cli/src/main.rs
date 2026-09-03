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
    /// Which stored Steam account (if any) can fetch each of these depots? All answers ride the same
    /// login per account — Steam rate-limits logons hard enough that asking depot-by-depot in separate
    /// invocations once shut the account out for an hour. A login failure ABORTS rather than reporting
    /// "unowned": a refused logon says nothing about ownership.
    SteamProbe {
        #[arg(long)]
        app: u32,
        #[arg(long, default_value = "public")]
        branch: String,
        /// Which stored Steam account to try first; default: every stored account.
        #[arg(long)]
        steam_account: Option<String>,
        /// The depot ids to probe.
        #[arg(required = true)]
        depots: Vec<u32>,
    },
    /// Check a payload ALREADY on disk against the store's own per-chunk hashes.
    ///
    /// The arbiter when `hash` and `download` disagree: both are candidate answers, and `hash` is what
    /// produced the pins, so agreeing with the pin proves little. This reads the bytes back and re-hashes
    /// them at every offset the manifest declares, so the verdict comes from the store, not from us.
    Verify {
        #[command(subcommand)]
        what: VerifyCmd,
    },
    /// Download a pinned payload to a directory — what the payload FODs run.
    ///
    /// The same pipeline as `pin`/`hash` with files as the sink, so it shares the manifest decoders, the
    /// chunk transport, the failure policy, the throughput governor and the host scoring. The tree it writes
    /// is the one the pins already hash, so a FOD's content address does not move.
    Download {
        #[command(subcommand)]
        what: DownloadCmd,
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
    /// CEILING on concurrent chunk requests. The number actually in flight starts small and is moved
    /// by the throughput governor (see pin::concurrency), so this is a bound, not a setting to tune.
    #[arg(long, default_value_t = 128)]
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
        /// Ceiling on concurrent chunk requests; the governor picks the working value.
        #[arg(long, default_value_t = 128)]
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
        /// Ceiling on concurrent chunk requests; the governor picks the working value.
        #[arg(long, default_value_t = 128)]
        workers: usize,
        #[arg(long, default_value_t = 128)]
        window_mib: u64,
    },
}

#[derive(Subcommand)]
enum VerifyCmd {
    /// Verify a Steam depot tree on disk against its manifest.
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
        /// The tree to check.
        #[arg(long)]
        dir: std::path::PathBuf,
    },
}

#[derive(Subcommand)]
enum DownloadCmd {
    /// Download a Steam depot (replaces DepotDownloader).
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
        /// Where to write the depot. Created if missing.
        #[arg(long)]
        dir: std::path::PathBuf,
        #[arg(long, default_value_t = 128)]
        workers: usize,
        /// MiB of chunks admitted ahead of the disk — the download's memory bound.
        #[arg(long, default_value_t = 128)]
        window_mib: u64,
        /// Cache trust anchor: sha256 (hex) of the depot key, from the pin's `depotKeySha256`. With
        /// BOTH anchors present and the /propnix cache warm, the download makes no Steam login at all.
        #[arg(long)]
        depot_key_sha256: Option<String>,
        /// Cache trust anchor: sha256 (hex) of the raw manifest, from the pin's `manifestSha256`.
        #[arg(long)]
        manifest_sha256: Option<String>,
    },
    /// Download a GOG Galaxy build (replaces gogdl).
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
        /// Acknowledge the global dependency-repository build, for titles that install a dependency INTO
        /// the game directory (their tree is not pinned by buildId alone).
        #[arg(long)]
        deps_build_id: Option<String>,
        /// Which stored GOG account to use, when the credential store holds more than one.
        #[arg(long)]
        gog_account: Option<String>,
        /// Where to write the build. Created if missing.
        #[arg(long)]
        dir: std::path::PathBuf,
        #[arg(long, default_value_t = 128)]
        workers: usize,
        /// MiB of chunks admitted ahead of the disk — the download's memory bound.
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
    /// Materialize the declarative credential store from a config file. INTERNAL — run as root by the NixOS
    /// module's activation service, not by hand: it installs declared tokens, prunes dropped ones, and
    /// converges the store's ownership/permissions to contract.
    #[command(hide = true)]
    Materialize {
        /// Path to the JSON config the NixOS module renders.
        #[arg(value_name = "CONFIG")]
        config: std::path::PathBuf,
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
            CredAction::Materialize { config } => {
                cred::materialize::materialize(&config).map_err(Into::into)
            }
        },
        Command::Games { repo } => pin::all_games(&repo)
            .map(|gs| gs.iter().for_each(|g| println!("{g}")))
            .map_err(Into::into),
        Command::Pin(args) => cmd_pin(args),
        Command::Hash { what } => cmd_hash(what),
        Command::SteamProbe {
            app,
            branch,
            steam_account,
            depots,
        } => cmd_steam_probe(app, &branch, steam_account, &depots),
        Command::Download { what } => cmd_download(what),
        Command::Verify { what } => cmd_verify(what),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("propnix: {e}");
            // Exit 4 means "a human needs to act" — no/stale credential, the account does not own the
            // title, or a construct we refuse to guess at — as opposed to 1, which means the tool itself
            // hit something unexpected. CI uses the distinction to open an issue instead of failing.
            // EVERY subcommand maps the same way (pin wraps these in `Blocked`; the others surface the
            // raw store error), so scripts can rely on 4 regardless of which command met the problem.
            if pin::is_human_actionable(e.as_ref()) {
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

/// Validate a NAMED account selection (flag or env) against the store IMMEDIATELY — local token reads
/// only, never a login — so a typo'd `--steam-account` fails on the spot instead of weeks later on the
/// first run that actually has something to hash (classically in CI at the worst moment). No selection
/// means nothing to check: try-all stays lazy and anonymous flows stay anonymous.
fn validate_accounts(
    dir: &std::path::Path,
    gog: Option<&str>,
    steam: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    if gog.is_some() {
        pin::gog::gog_credentials(dir, gog)?;
    }
    if steam.is_some() {
        pin::steam::credentials_from_store(dir, steam)?;
    }
    Ok(())
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
    validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
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

fn cmd_steam_probe(
    app: u32,
    branch: &str,
    steam_account: Option<String>,
    depots: &[u32],
) -> Result<(), Box<dyn std::error::Error>> {
    let opts = pin::gog::HashOpts {
        workers: 1,
        window_bytes: 0,
        credential_dir: cred_dir(),
        gog_account: None,
        steam_account: steam_account.or_else(|| env_account("PROPNIX_STEAM_ACCOUNT")),
        progress: false,
    };
    validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
    for (depot, owner) in pin::steam::probe_depots(app, depots, branch, &opts)? {
        match owner {
            Some(account) => println!("{app}\t{depot}\towned\t{account}"),
            None => println!("{app}\t{depot}\tunowned"),
        }
    }
    Ok(())
}

fn cmd_download(what: DownloadCmd) -> Result<(), Box<dyn std::error::Error>> {
    use pin::{gog, steam};
    match what {
        DownloadCmd::Steam {
            app,
            depot,
            manifest,
            branch,
            anonymous,
            steam_account,
            dir,
            workers,
            window_mib,
            depot_key_sha256,
            manifest_sha256,
        } => {
            std::fs::create_dir_all(&dir)?;
            let opts = gog::HashOpts {
                workers,
                window_bytes: window_mib * 1024 * 1024,
                credential_dir: cred_dir(),
                gog_account: None,
                steam_account: steam_account.or_else(|| env_account("PROPNIX_STEAM_ACCOUNT")),
                progress: true,
            };
            validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
            // Both anchors or neither: a lone anchor can never complete the cache path, and passing a
            // half-pair through would just make `acquire` probe the cache for nothing.
            let anchors = depot_key_sha256.as_deref().zip(manifest_sha256.as_deref());
            let w = steam::download_depot_any(
                app, depot, manifest, &branch, anonymous, &dir, anchors, &opts,
            )?;
            eprintln!(
                "  wrote {} files, {} dirs, {} content bytes to {}",
                w.files,
                w.dirs,
                w.bytes,
                dir.display()
            );
            Ok(())
        }
        DownloadCmd::Gog {
            product_id,
            build_id,
            os,
            lang,
            dlc_id,
            deps_build_id,
            gog_account,
            dir,
            workers,
            window_mib,
        } => {
            std::fs::create_dir_all(&dir)?;
            let opts = gog::HashOpts {
                workers,
                window_bytes: window_mib * 1024 * 1024,
                credential_dir: cred_dir(),
                // Same precedence as `pin`: flag > PROPNIX_GOG_ACCOUNT > try every stored account.
                gog_account: gog_account.or_else(|| env_account("PROPNIX_GOG_ACCOUNT")),
                steam_account: None,
                progress: true,
            };
            validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
            // Same contract as `hash gog`: be explicit about a tree that buildId alone does not pin.
            let deps = deps_build_id.map(gog::DepsPin::Expect);
            let w = gog::download_build(
                &product_id,
                &build_id,
                &os,
                &lang,
                dlc_id.as_deref(),
                deps.as_ref(),
                &dir,
                &opts,
            )?;
            eprintln!(
                "  wrote {} files, {} dirs, {} content bytes to {}",
                w.files,
                w.dirs,
                w.bytes,
                dir.display()
            );
            Ok(())
        }
    }
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
            validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
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
            validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
            let (sri, stats, _, _anchors) = if anonymous {
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
        println!(
            "Add one with: propnix cred add <{}>",
            cred::provider::type_names().join("|")
        );
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
                // Annotate the exceptions to "mine, writable"; a plain line is your own account. Every
                // account listed is READABLE by a build regardless — the tag is about who may REWRITE it.
                //   (declarative)        — materialized from the host config; `cred rm` refuses it, and a
                //                          re-`cred add` would be overwritten at the next activation.
                //   (managed by <name>)  — a different human on this host added it; readable by builds,
                //                          not writable by you (an account dir is 0750, owned by its
                //                          creator). The multi-user store's isolation.
                // A ROOT-owned account is NOT tagged this way: on a plain (no-module) store `cred add`
                // keeps ownership with the human even through its sudo step, so a root owner means the
                // module put it there — already caught by the declarative check above — and a stray
                // root-owned token should not read as "another user".
                let tag = if store.is_declarative(&t.type_name, u) {
                    " (declarative)".to_string()
                } else {
                    match store.account_access(&t.type_name, u) {
                        cred::store::AccountAccess::Other { user, uid } if uid != 0 => {
                            format!(" (managed by {user})")
                        }
                        _ => String::new(),
                    }
                };
                println!("  - {u}{tag}");
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
    // The USERNAME is only known once the login has completed, so the replace/ownership checks can only
    // run now. These are the FRIENDLY versions; `put` re-checks everything as the authoritative gate
    // (declarative accounts skip straight to put's own refusal, which names the config option to edit).
    let token_path = store
        .root()
        .join(provider.type_name())
        .join(&cred.username)
        .join(provider.token_filename());
    let replacing = token_path.exists();
    if replacing && !store.is_declarative(provider.type_name(), &cred.username) {
        match store.account_access(provider.type_name(), &cred.username) {
            // Another human's account: adding over it would leave the token owned by you inside THEIR
            // account dir — a mixed-ownership state nothing expects. Point at the clean sequence instead.
            cred::store::AccountAccess::Other { user, uid } if uid != 0 => {
                return Err(format!(
                    "{} account '{}' already exists and belongs to {user} — have them refresh it \
                     themselves, or (as an administrator) remove it first: sudo propnix cred rm -t {} {}",
                    provider.display_name(),
                    cred.username,
                    provider.type_name(),
                    cred.username,
                ));
            }
            // Your own token: replacing it is the normal refresh flow, but make it deliberate — an
            // accidental duplicate `add` should not silently clobber a working credential. On a terminal,
            // ask; without one (automation), warn and proceed rather than hang.
            _ => {
                use std::io::{BufRead, IsTerminal, Write};
                if std::io::stdin().is_terminal() {
                    eprint!(
                        "propnix: {} account '{}' already has a stored token — replace it? [y/N] ",
                        provider.display_name(),
                        cred.username
                    );
                    let _ = std::io::stderr().flush();
                    let mut answer = String::new();
                    let _ = std::io::stdin().lock().read_line(&mut answer);
                    if !matches!(answer.trim(), "y" | "Y" | "yes") {
                        return Err(format!(
                            "left the existing token for '{}' in place",
                            cred.username
                        ));
                    }
                } else {
                    eprintln!(
                        "propnix: replacing the existing stored token for {} account '{}'",
                        provider.display_name(),
                        cred.username
                    );
                }
            }
        }
    }
    store.put(
        provider.type_name(),
        &cred.username,
        provider.token_filename(),
        &cred.token,
    )?;
    println!(
        "propnix: {} {} account '{}' → {}/{}/{}/{}",
        if replacing { "replaced" } else { "added" },
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

/// `propnix verify steam` — read a tree back and check it against the manifest's per-chunk hashes.
fn cmd_verify(what: VerifyCmd) -> Result<(), Box<dyn std::error::Error>> {
    use pin::{gog, steam};
    match what {
        VerifyCmd::Steam {
            app,
            depot,
            manifest,
            branch,
            anonymous,
            steam_account,
            dir,
        } => {
            let account = steam_account.or_else(|| env_account("PROPNIX_STEAM_ACCOUNT"));
            let opts = gog::HashOpts {
                workers: 1,
                window_bytes: 0,
                credential_dir: cred_dir(),
                gog_account: None,
                steam_account: account,
                progress: true,
            };
            validate_accounts(&opts.credential_dir, opts.gog_account.as_deref(), opts.steam_account.as_deref())?;
            let rep = steam::verify_depot_any(app, depot, manifest, &branch, anonymous, &dir, &opts)?;
            println!(
                "{} files, {} dirs, {} chunks checked",
                rep.files, rep.dirs, rep.chunks
            );
            if rep.gap_bytes > 0 {
                println!(
                    "  {} bytes in ranges no chunk covers (must read as zeros)",
                    rep.gap_bytes
                );
            }
            for p in &rep.problems {
                println!("  MISMATCH {p}");
            }
            if rep.ok() {
                println!("the tree matches the manifest");
                Ok(())
            } else {
                Err(format!(
                    "{} bad chunks, {} bad files ({} problems shown)",
                    rep.bad_chunks,
                    rep.bad_files,
                    rep.problems.len()
                )
                .into())
            }
        }
    }
}
