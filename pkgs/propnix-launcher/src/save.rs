//! Save/data binding (§6.1 + winefex L238-261).
//!
//! The declared save (config.save) is bound out of the prefix so it lives on the host filesystem (and can
//! be shared with a native build): a guest path under `drive_c/users/<user>` becomes a symlink to the host
//! save dir. §6.1: create the host save dir or REFUSE to launch — a game silently writing saves into a
//! rebuilt prefix would lose them. PROPNIX_WINE_BIND adds extra ';'-separated `GUESTREL|HOSTPATH` binds
//! (the winefex escape hatch); those are best-effort.
//!
//! Migration is once-only and loss-safe: if the guest path already holds real data (not already a
//! symlink), copy it out no-clobber and delete the source ONLY if the copy succeeded — this is the one
//! path touching irreplaceable saves.

use crate::config::Config;
use crate::settings::{Paths, Settings};
use crate::util::{self, copy_dir_noclobber, force_symlink, rm_rf};
use std::fs;
use std::path::{Path, PathBuf};

struct Bind {
    guest_rel: String,
    host: PathBuf,
    fatal: bool, // the declared save is fatal-on-failure (§6.1); extra binds are best-effort
}

pub fn apply(cfg: &Config, settings: &Settings, paths: &Paths) -> Result<(), String> {
    let userdir = paths
        .prefix
        .join("drive_c/users")
        .join(&cfg.wine_user);

    let mut binds: Vec<Bind> = Vec::new();

    // The declared save. PROPNIX_SAVE_DIR is a GLOBAL root override, namespaced per app
    // (`$PROPNIX_SAVE_DIR/<appid>`), so a user can point all games at one saves volume; absent it, the
    // baked hostDefault ($HOME-expanded) is used.
    let host = match &settings.save_dir_override {
        Some(root) => PathBuf::from(root).join(&settings.appid),
        None => PathBuf::from(util::expand_env(&cfg.save.host_default)),
    };
    binds.push(Bind {
        guest_rel: cfg.save.guest_rel.clone(),
        host: PathBuf::from(host),
        fatal: true,
    });

    // Extra binds from PROPNIX_WINE_BIND: ';'-separated "GUESTREL|HOSTPATH".
    if let Some(spec) = &settings.wine_bind {
        for pair in spec.split(';') {
            if pair.is_empty() {
                continue;
            }
            match pair.split_once('|') {
                Some((g, h)) if !g.is_empty() && !h.is_empty() => binds.push(Bind {
                    guest_rel: g.to_string(),
                    host: PathBuf::from(util::expand_env(h)),
                    fatal: false,
                }),
                _ => eprintln!("propnix: ignoring malformed PROPNIX_WINE_BIND entry {pair:?}"),
            }
        }
    }

    for b in binds {
        if let Err(e) = bind_one(&userdir, &b) {
            if b.fatal {
                return Err(format!(
                    "cannot prepare save dir {}: {e}",
                    b.host.display()
                ));
            }
            eprintln!("propnix: skipping bind {} -> {}: {e}", b.guest_rel, b.host.display());
        }
    }
    Ok(())
}

fn bind_one(userdir: &Path, b: &Bind) -> std::io::Result<()> {
    fs::create_dir_all(&b.host)?; // §6.1: create it (or the caller turns this into "refuse to launch")
    let guest = userdir.join(&b.guest_rel);
    if let Some(parent) = guest.parent() {
        fs::create_dir_all(parent)?;
    }

    let meta = fs::symlink_metadata(&guest);
    match meta {
        // Real directory with data → migrate once, loss-safe, then symlink.
        Ok(md) if md.file_type().is_dir() => {
            match copy_dir_noclobber(&guest, &b.host) {
                Ok(()) => {
                    rm_rf(&guest)?;
                    force_symlink(&b.host, &guest)?;
                }
                Err(e) => {
                    // Leave the data in the prefix and DON'T symlink over it (safer than winefex, which
                    // symlinked unconditionally); the game keeps using the in-prefix save this run.
                    eprintln!(
                        "propnix: save migration to {} failed ({e}) — leaving data in the prefix",
                        b.host.display()
                    );
                }
            }
        }
        // Already a symlink (or a stray file, or absent) → (re)point it at the host dir.
        _ => force_symlink(&b.host, &guest)?,
    }
    Ok(())
}
