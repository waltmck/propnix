//! Account-type abstraction. Each credential provider (GOG now; Steam/others later) implements `Provider`:
//! it knows its store subdirectory name, the on-disk token filename the fetchers expect, and how to run an
//! interactive login that yields a labelled credential. `cred add <type>` dispatches on the type name; the
//! store + `cred list`/`cred rm` are provider-agnostic (they just enumerate `<store>/<type>/<username>/`).

use crate::gog::Gog;

/// A minted credential ready to persist: the account label (username, for `cred list` + the dir name) and the
/// token file bytes to write verbatim as `<store>/<type>/<username>/<token_filename>`.
pub struct Credential {
    pub username: String,
    pub token: Vec<u8>,
}

pub trait Provider {
    /// Store subdirectory + the `cred add <type>` name, e.g. "gog".
    fn type_name(&self) -> &'static str;
    /// Human label for `cred list` headers, e.g. "GOG".
    fn display_name(&self) -> &'static str;
    /// The token filename the credentialed fetcher reads under the account dir, e.g. "galaxy_tokens.json".
    fn token_filename(&self) -> &'static str;
    /// Run the interactive login (open a browser, read back the code, exchange for tokens) and return the
    /// credential to store. Prints its own guidance to stderr/stdout.
    fn login(&self) -> Result<Credential, String>;
}

/// All known providers, in a stable display order.
pub fn all() -> Vec<Box<dyn Provider>> {
    vec![Box::new(Gog)]
}

/// Look up a provider by its `type_name` (the `cred add <type>` argument).
pub fn by_name(name: &str) -> Option<Box<dyn Provider>> {
    all().into_iter().find(|p| p.type_name() == name)
}

/// The valid `<type>` values, for usage/errors.
pub fn type_names() -> Vec<&'static str> {
    all().iter().map(|p| p.type_name()).collect()
}
