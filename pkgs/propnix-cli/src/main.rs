//! `propnix` — the propnix CLI. Currently one command group: `propnix cred …`, which manages the account
//! credentials the credentialed game-payload fetchers consume (GOG today; the `Provider` abstraction lets
//! other account types slot in). The store lives at `/var/lib/propnix` (see `store.rs`), bound into the Nix
//! build sandbox at `/propnix`.

mod gog;
mod provider;
mod store;

use clap::{Parser, Subcommand};
use std::process::ExitCode;
use store::CredStore;

#[derive(Parser)]
#[command(
    name = "propnix",
    about = "propnix — manage the credentials the game-payload fetchers use",
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
    /// Remove the stored account with the given username.
    Rm {
        #[arg(value_name = "USERNAME")]
        username: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.command {
        Command::Cred { action } => match action {
            CredAction::List => cmd_list(),
            CredAction::Add { r#type } => cmd_add(&r#type),
            CredAction::Rm { username } => cmd_rm(&username),
        },
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("propnix: {e}");
            ExitCode::FAILURE
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
        let label = provider::by_name(&t.type_name)
            .map(|p| p.display_name().to_string())
            .unwrap_or_else(|| t.type_name.clone());
        println!("{label}:");
        if t.usernames.is_empty() {
            println!("  (none)");
        } else {
            for u in &t.usernames {
                println!("  - {u}");
            }
        }
    }
    Ok(())
}

fn cmd_add(type_name: &str) -> Result<(), String> {
    let provider = provider::by_name(type_name).ok_or_else(|| {
        format!(
            "unknown account type '{type_name}' (valid: {})",
            provider::type_names().join(", ")
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

fn cmd_rm(username: &str) -> Result<(), String> {
    let store = CredStore::from_env();
    let type_name = store.remove(username)?;
    println!("propnix: removed {type_name} account '{username}'");
    Ok(())
}
