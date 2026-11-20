//! Unity player facts, read off a payload's own bytes for the pin rows: `unityVersion` and
//! `unityChangeset` from the player binary's version string, `unityScripting` from the file list. They
//! are recorded by `propnix pin` (a tap on the streaming hash, so a re-pin costs nothing extra) and
//! backfilled by `propnix pin --fingerprint`; the Nix side derives `unity.mono.stream` from them and
//! selects the native ARM64 player by the exact version, with a build-time check that the payload agrees.
//!
//! The version string. Every player carries `<major>.<minor>.<patch><type><n> (<12-hex changeset>)` —
//! what Player.log prints as `Initialize engine version:` — in UTF-16 from Unity 2022.3 on, and in ASCII
//! in every measured player (docs/research/unity-player-facts.md). Players also carry version-shaped
//! DECOYS (`5.0.0a1`, `2018.3.0a1`), which in most players precede the real string in file order, so
//! the hash form is matched before any bare `<version>` form, UTF-16 before ASCII — the order
//! lib/builders/unity-mono-tree.nix reads the same string in, so the pin and the build-time check agree.
//! A release type can carry a suffix (`6000.0.50f1-uum-100966-branch1`, an internal branch); it is kept
//! verbatim, since that is the version the player reports and the one no public download exists for.

use std::io::Write;

/// What a player binary says about itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    /// `6000.0.61f1`, or with its suffix (`6000.0.50f1-uum-100966-branch1`).
    pub version: String,
    /// The 12-hex changeset beside it, which keys Unity's download URLs. Absent only for a player that
    /// carries no hash form at all (none measured; the bare fallback).
    pub changeset: Option<String>,
}

/// The scripting backend a build was made with, from its file list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scripting {
    Mono,
    Il2cpp,
}

impl Scripting {
    pub fn as_str(self) -> &'static str {
        match self {
            Scripting::Mono => "mono",
            Scripting::Il2cpp => "il2cpp",
        }
    }
}

/// Is this manifest path the Unity player binary? By basename, so it needs no knowledge of the game
/// module. `UnityPlayer.dll` on Windows, `UnityPlayer.so` on Linux; a player that predates the split
/// (Unity 5) keeps the version in the exe, which no row needs today.
pub fn is_player(path: &str) -> bool {
    let base = path.rsplit(['/', '\\']).next().unwrap_or(path);
    matches!(base, "UnityPlayer.dll" | "UnityPlayer.so")
}

/// The scripting backend a file list implies: an IL2CPP build ships its compiled C# as
/// `GameAssembly.{dll,so}` (and `<Data>/il2cpp_data/`); a Mono build ships the runtime under
/// `MonoBleedingEdge/` (`Mono/EmbedRuntime/` in older players). Case-insensitive — GOG manifests keep the
/// upstream casing and resolve paths case-insensitively. `None` for a non-Unity payload.
pub fn scripting_of<'a>(paths: impl IntoIterator<Item = &'a str>) -> Option<Scripting> {
    let mut mono = false;
    for p in paths {
        let lower = p.to_ascii_lowercase();
        let base = lower.rsplit(['/', '\\']).next().unwrap_or(&lower);
        if base == "gameassembly.dll" || base == "gameassembly.so" {
            return Some(Scripting::Il2cpp);
        }
        let mut comps = lower.split(['/', '\\']);
        if comps.any(|c| c == "il2cpp_data") {
            return Some(Scripting::Il2cpp);
        }
        let comps: Vec<&str> = lower.split(['/', '\\']).collect();
        if comps.iter().any(|c| *c == "monobleedingedge")
            || comps.windows(2).any(|w| w == ["mono", "embedruntime"])
        {
            mono = true;
        }
    }
    mono.then_some(Scripting::Mono)
}

/// The player's version string, hash form first (UTF-16 then ASCII), bare form only after that.
pub fn scan_player(bytes: &[u8]) -> Option<Facts> {
    let utf16 = utf16_strings(bytes, 6);
    let ascii = ascii_strings(bytes, 6);
    for s in utf16.iter().chain(ascii.iter()) {
        if let Some(f) = parse_hash_form(s) {
            return Some(f);
        }
    }
    for s in utf16.iter().chain(ascii.iter()) {
        if let Some(v) = parse_bare_form(s) {
            // The known decoys are never a player's version; skipping them keeps the bare fallback from
            // answering `5.0.0a1` for a player whose real string is in a form this scanner does not know.
            if v == "5.0.0a1" || v == "2018.3.0a1" {
                continue;
            }
            return Some(Facts {
                version: v.to_string(),
                changeset: None,
            });
        }
    }
    None
}

/// `<version> (<12 hex>)` at the start of the string.
fn parse_hash_form(s: &str) -> Option<Facts> {
    let n = version_token_len(s)?;
    let rest = &s[n..];
    let rest = rest.strip_prefix(" (")?;
    if rest.len() < 13 {
        return None;
    }
    let (hash, tail) = rest.split_at(12);
    if !tail.starts_with(')') || !hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
        return None;
    }
    Some(Facts {
        version: s[..n].to_string(),
        changeset: Some(hash.to_string()),
    })
}

/// `<major>.<minor>.<patch><type><n>` at the start of the string (no suffix: the bare form is the
/// release's own name).
fn parse_bare_form(s: &str) -> Option<&str> {
    let core = version_core_len(s)?;
    Some(&s[..core])
}

/// Length of `<digits>.<digits>.<digits><letter><digits>` at the start of `s`.
fn version_core_len(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let mut i = 0;
    for field in 0..3 {
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return None;
        }
        if field < 2 {
            if i >= b.len() || b[i] != b'.' {
                return None;
            }
            i += 1;
        }
    }
    if i >= b.len() || !b[i].is_ascii_lowercase() {
        return None;
    }
    i += 1;
    let start = i;
    while i < b.len() && b[i].is_ascii_digit() {
        i += 1;
    }
    (i > start).then_some(i)
}

/// The core plus any `[^ ]*` suffix (`-uum-100966-branch1`), up to the space before the changeset.
fn version_token_len(s: &str) -> Option<usize> {
    let mut i = version_core_len(s)?;
    let b = s.as_bytes();
    while i < b.len() && b[i] != b' ' {
        i += 1;
    }
    Some(i)
}

fn is_printable(b: u8) -> bool {
    (0x20..0x7f).contains(&b)
}

/// Runs of printable ASCII of at least `min` bytes, in file order (what `strings` prints).
fn ascii_strings(bytes: &[u8], min: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, &b) in bytes.iter().enumerate() {
        match (is_printable(b), start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                if i - s >= min {
                    out.push(String::from_utf8_lossy(&bytes[s..i]).into_owned());
                }
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        if bytes.len() - s >= min {
            out.push(String::from_utf8_lossy(&bytes[s..]).into_owned());
        }
    }
    out
}

/// Runs of printable ASCII encoded as UTF-16LE (`xx 00` pairs) of at least `min` characters, at either
/// byte alignment, in file order (what `strings -el` prints).
fn utf16_strings(bytes: &[u8], min: usize) -> Vec<String> {
    let mut out = Vec::new();
    for align in 0..2 {
        let mut run = String::new();
        let mut i = align;
        while i + 1 < bytes.len() {
            let (lo, hi) = (bytes[i], bytes[i + 1]);
            if hi == 0 && is_printable(lo) {
                run.push(lo as char);
            } else {
                if run.len() >= min {
                    out.push(std::mem::take(&mut run));
                } else {
                    run.clear();
                }
            }
            i += 2;
        }
        if run.len() >= min {
            out.push(run);
        }
    }
    out
}

/// A writer that keeps a copy of everything written through it, for scanning a file after the hash
/// has consumed it. Only the player binary (tens of MB) is ever routed through one.
pub struct Tee<'a> {
    inner: &'a mut dyn Write,
    pub buf: Vec<u8>,
}

impl<'a> Tee<'a> {
    pub fn new(inner: &'a mut dyn Write) -> Self {
        Tee {
            inner,
            buf: Vec::new(),
        }
    }

    /// The wrapped writer, for bytes that should NOT be copied (every file but the player).
    pub fn inner_mut(&mut self) -> &mut dyn Write {
        self.inner
    }
}

impl Write for Tee<'_> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        let n = self.inner.write(data)?;
        self.buf.extend_from_slice(&data[..n]);
        Ok(n)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utf16(s: &str) -> Vec<u8> {
        s.encode_utf16().flat_map(|u| u.to_le_bytes()).collect()
    }

    fn join(parts: &[&[u8]]) -> Vec<u8> {
        let mut v = Vec::new();
        for p in parts {
            v.extend_from_slice(p);
            v.extend_from_slice(&[0, 0, 0xff, 0]);
        }
        v
    }

    #[test]
    fn hash_form_beats_the_decoys_that_precede_it() {
        // The measured ASCII order of a Unity 6 player: both decoys before the real string.
        let bytes = join(&[
            b"2018.3.0a1",
            b"6000.0.61f1",
            b"6000.0.61f1_74a0adb02c31",
            b"6000.0.61f1 (74a0adb02c31)",
            b"5.0.0a1",
        ]);
        assert_eq!(
            scan_player(&bytes),
            Some(Facts {
                version: "6000.0.61f1".into(),
                changeset: Some("74a0adb02c31".into())
            })
        );
    }

    #[test]
    fn utf16_hash_form_is_read_before_ascii() {
        let bytes = join(&[
            b"2019.4.18f1 (3310a4d4f880)",
            &utf16("6000.0.61f1 (74a0adb02c31)"),
        ]);
        assert_eq!(
            scan_player(&bytes).unwrap().changeset.as_deref(),
            Some("74a0adb02c31")
        );
    }

    #[test]
    fn internal_branch_suffix_is_kept_verbatim() {
        let bytes = join(&[&utf16("6000.0.50f1-uum-100966-branch1 (16f07294548e)")]);
        let f = scan_player(&bytes).unwrap();
        assert_eq!(f.version, "6000.0.50f1-uum-100966-branch1");
        assert_eq!(f.changeset.as_deref(), Some("16f07294548e"));
    }

    #[test]
    fn bare_fallback_skips_the_decoys() {
        let bytes = join(&[b"5.0.0a1", b"2018.3.0a1", b"2017.4.40f1", b"2017.4.40f1_6e14067f8a9a"]);
        assert_eq!(
            scan_player(&bytes),
            Some(Facts {
                version: "2017.4.40f1".into(),
                changeset: None
            })
        );
        assert_eq!(scan_player(&join(&[b"5.0.0a1", b"not a version"])), None);
    }

    #[test]
    fn a_malformed_hash_is_not_a_hash_form() {
        // 11 hex digits, an uppercase digit, a missing paren: each falls through to the bare form.
        for s in [
            "6000.0.61f1 (74a0adb02c3)",
            "6000.0.61f1 (74A0ADB02C31)",
            "6000.0.61f1 (74a0adb02c31",
        ] {
            let f = scan_player(&join(&[s.as_bytes()])).unwrap();
            assert_eq!(f.version, "6000.0.61f1", "{s}");
            assert_eq!(f.changeset, None, "{s}");
        }
    }

    #[test]
    fn player_paths_by_basename() {
        assert!(is_player("UnityPlayer.dll"));
        assert!(is_player("Hollow Knight_Data/../UnityPlayer.dll"));
        assert!(is_player("UnityPlayer.so"));
        assert!(is_player(r"sub\dir\UnityPlayer.dll"));
        assert!(!is_player("UnityPlayer.pdb"));
        assert!(!is_player("UnityCrashHandler64.exe"));
    }

    #[test]
    fn scripting_backend_from_the_file_list() {
        let mono = ["Hollow Knight.exe", "MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll"];
        assert_eq!(scripting_of(mono), Some(Scripting::Mono));
        let old_mono = ["game.exe", "Game_Data/Mono/EmbedRuntime/mono.dll"];
        assert_eq!(scripting_of(old_mono), Some(Scripting::Mono));
        let il2cpp = ["game.exe", "GameAssembly.dll", "Game_Data/il2cpp_data/Metadata/global-metadata.dat"];
        assert_eq!(scripting_of(il2cpp), Some(Scripting::Il2cpp));
        // IL2CPP wins even when a stray Mono directory ships beside it.
        let both = ["MonoBleedingEdge/etc/mono/config", "GameAssembly.so"];
        assert_eq!(scripting_of(both), Some(Scripting::Il2cpp));
        assert_eq!(scripting_of(["stellaris", "pdx_online_assets/x"]), None);
        // Case-insensitive, either separator.
        assert_eq!(scripting_of([r"MONOBLEEDINGEDGE\x"]), Some(Scripting::Mono));
    }

    #[test]
    fn tee_copies_what_it_forwards() {
        let mut sink = Vec::new();
        let mut t = Tee::new(&mut sink);
        t.write_all(b"abc").unwrap();
        t.write_all(b"def").unwrap();
        assert_eq!(t.buf, b"abcdef");
        assert_eq!(sink, b"abcdef");
    }
}
