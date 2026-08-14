//! Small shared helpers: `$VAR`/`${VAR}` expansion and XDG base-dir resolution.

use std::path::PathBuf;

/// Expand `$VAR` and `${VAR}` references against the process environment (unknown vars → empty, like a
/// shell with `set -u` off). Used for PROPNIX_SAVE_DIR and PROPNIX_EXTRA_BINDS host paths, which are
/// authored shell-style (e.g. `"$HOME/games/saves"`).
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

/// Like `expand_env`, but returns `None` if ANY referenced `$VAR`/`${VAR}` is UNSET — so a caller can SKIP
/// the whole value rather than write one with a blank hole (e.g. an empty REG_DWORD). Used for `fpsUserReg`
/// values, whose `$PROPNIX_FPS` must resolve or the entry is dropped for this launch. Otherwise identical to
/// `expand_env` (same `$VAR`/`${VAR}` grammar).
pub fn expand_env_checked(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' && i + 1 < bytes.len() {
            let (name, next) = if bytes[i + 1] == b'{' {
                match input[i + 2..].find('}') {
                    Some(rel) => (&input[i + 2..i + 2 + rel], i + 2 + rel + 1),
                    None => {
                        out.push('$');
                        i += 1;
                        continue;
                    }
                }
            } else {
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
            out.push_str(&std::env::var(name).ok()?); // unset var → None (caller skips the entry)
            i = next;
        } else {
            let ch = input[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    Some(out)
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

/// `$XDG_DATA_HOME` (durable user data) — defaults to `~/.local/share`. Root of the default save location
/// (`<data_home>/propnix-saves`) when PROPNIX_SAVE_DIR is unset.
pub fn data_home() -> PathBuf {
    base("XDG_DATA_HOME", ".local/share")
}

/// `$XDG_RUNTIME_DIR` (the single-instance lock) — falls back to a per-uid /tmp dir if unset.
pub fn runtime_dir() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(format!("/tmp/propnix-{}", unsafe { libc::getuid() })),
    }
}

