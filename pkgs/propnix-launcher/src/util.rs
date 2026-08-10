//! Small shared helpers: `$VAR`/`${VAR}` expansion, XDG base-dir resolution, and the symlink-farm
//! filesystem primitives (rm_rf / force_symlink / no-clobber recursive copy).

use std::fs;
use std::io;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

/// Expand `$VAR` and `${VAR}` references against the process environment (unknown vars → empty, like a
/// shell with `set -u` off). Used for `save.hostDefault` (e.g. `"$HOME/.config/unity3d/..."`), which is
/// authored as a shell-style path in the game's tuning.
pub fn expand_env(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' && i + 1 < bytes.len() {
            let (name, next) = if bytes[i + 1] == b'{' {
                // ${VAR}
                match input[i + 2..].find('}') {
                    Some(rel) => (&input[i + 2..i + 2 + rel], i + 2 + rel + 1),
                    None => {
                        out.push('$');
                        i += 1;
                        continue;
                    }
                }
            } else {
                // $VAR — VAR is [A-Za-z_][A-Za-z0-9_]*
                let start = i + 1;
                let mut end = start;
                while end < bytes.len()
                    && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_')
                    && !(end == start && bytes[end].is_ascii_digit())
                {
                    end += 1;
                }
                if end == start {
                    out.push('$');
                    i += 1;
                    continue;
                }
                (&input[start..end], end)
            };
            out.push_str(&std::env::var(name).unwrap_or_default());
            i = next;
        } else {
            // Push the whole next UTF-8 char (input is valid UTF-8).
            let ch = input[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

fn base(xdg: &str, home_rel: &str) -> PathBuf {
    match std::env::var_os(xdg) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => home_dir().join(home_rel),
    }
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// `$XDG_STATE_HOME` (persistent app state: the prefix) — defaults to `~/.local/state`.
pub fn state_home() -> PathBuf {
    base("XDG_STATE_HOME", ".local/state")
}

/// `$XDG_CACHE_HOME` (regenerable caches: DXVK shaders) — defaults to `~/.cache`.
pub fn cache_home() -> PathBuf {
    base("XDG_CACHE_HOME", ".cache")
}

/// `$XDG_RUNTIME_DIR` (the single-instance lock) — falls back to a per-uid /tmp dir if unset.
pub fn runtime_dir() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(format!("/tmp/propnix-{}", unsafe { libc::getuid() })),
    }
}

/// Remove a path whether it is a symlink, file, or directory — WITHOUT following symlinks (so we never
/// delete through a link into the store or a save). Missing path is not an error.
pub fn rm_rf(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(md) => {
            if md.file_type().is_dir() {
                fs::remove_dir_all(path)
            } else {
                fs::remove_file(path)
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// `ln -sfn target link`: clear whatever is at `link` (link/file/dir) then create the symlink. Never
/// `symlink` onto an existing name (that errors) — always clear first.
pub fn force_symlink(target: &Path, link: &Path) -> io::Result<()> {
    rm_rf(link)?;
    symlink(target, link)
}

/// `cp -an src/. dst/`: recursively copy, NEVER clobbering a file that already exists under dst (host
/// copies stay authoritative). Directories are merged. Used for the one-time save migration in save.rs.
pub fn copy_dir_noclobber(src: &Path, dst: &Path) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        let ft = entry.file_type()?;
        if ft.is_dir() {
            copy_dir_noclobber(&from, &to)?;
        } else if ft.is_symlink() {
            if !to.exists() {
                symlink(fs::read_link(&from)?, &to)?;
            }
        } else if !to.exists() {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}
