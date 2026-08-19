//! `propnix cred …` — the account credentials the payload fetchers consume.
//!
//! `store` is the on-disk credential store (`/var/lib/propnix`, bound into the Nix build sandbox at
//! `/propnix`); `provider` is the account-type abstraction that lets a new backend slot in; `gog` and
//! `steam` are the two providers, each of which drives an interactive login and captures the reusable
//! token it produces.
//!
//! Kept as a sibling of `pin/` so the two halves of the CLI — getting credentials, and using them to
//! refresh content pins — are separable at a glance. Note `cred::gog`/`cred::steam` (logging IN to a
//! store) are unrelated to `pin::gog`/`pin::steam` (talking to a store's content API); that name
//! collision is precisely why each half lives in its own module.

pub mod gog;
pub mod provider;
pub mod steam;
pub mod store;
