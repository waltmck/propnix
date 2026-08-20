//! Writing a pinned payload to disk — the shared filesystem layer under `propnix download`.
//!
//! `propnix pin` and `propnix download` are the SAME pipeline with different sinks. Pin resolves a
//! manifest, pulls the chunks, and feeds them to a NAR hasher; download resolves the same manifest, pulls
//! the same chunks through the same transport, and feeds them to files. Everything expensive and everything
//! subtle — the manifest decoders, the chunk containers, the credential handling, the failure policy, the
//! throughput governor, the multiplicative-weights host scoring — is shared, and lives in the store
//! modules beside the hashers rather than being duplicated here.
//!
//! WHY THIS CAN BE TRUSTED TO REPLACE DepotDownloader / gogdl. The FOD hash of every existing pin IS the
//! NAR of what those tools wrote, and `propnix pin` reproduces those hashes today — which means the tree
//! model in `pin::steam::tree` / `pin::gog::tree` is already a verified description of their output,
//! quirks included (Steam's dir/exec flag semantics; gogdl's refusal cases). Download writes that same
//! model to disk, so the bytes Nix hashes are unchanged. The check is cheap to run and worth running after
//! any change here: download a depot, `propnix hash path` the result, compare with versions.json.
//!
//! WHAT IS NEW HERE is that a manifest is now untrusted input that names FILESYSTEM PATHS. Hashing never
//! touched the filesystem, so a hostile or merely broken path cost nothing; writing one could escape the
//! output directory. Every path therefore goes through `safe_join`, which refuses absolute paths, `..`,
//! and anything else that would not stay put.

use std::fs;
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Component, Path, PathBuf};

/// Join a manifest-supplied relative path onto `root`, refusing anything that could leave it.
///
/// Manifests are fetched over the network and their paths are not validated by anyone upstream. A `..`
/// component or a leading `/` in a depot manifest would otherwise let a download write outside the
/// directory it was given — inside a Nix builder that is someone else's `$out`, and outside one it is the
/// whole filesystem. Refused rather than sanitized: silently rewriting a path would change the tree, and
/// a tree that differs from the pin is a hash mismatch nobody can explain.
pub fn safe_join(root: &Path, rel: &str) -> Result<PathBuf, String> {
    if rel.is_empty() {
        return Err("manifest contains an empty path".into());
    }
    if rel.contains('\0') {
        return Err(format!("manifest path contains a NUL byte: {rel:?}"));
    }
    let mut out = root.to_path_buf();
    for part in Path::new(rel).components() {
        match part {
            Component::Normal(p) => out.push(p),
            // Every other component kind is a way out of `root`: RootDir/Prefix for an absolute path,
            // ParentDir for `..`, CurDir for a `.` that would at best be noise.
            _ => {
                return Err(format!(
                    "manifest path is not a plain relative path (refusing to write it): {rel:?}"
                ))
            }
        }
    }
    Ok(out)
}

/// Create a directory named by the manifest, and every parent it needs.
pub fn ensure_dir(root: &Path, rel: &str) -> Result<(), String> {
    let p = safe_join(root, rel)?;
    fs::create_dir_all(&p).map_err(|e| format!("mkdir {}: {e}", p.display()))
}

/// Open a manifest-named file for writing, creating its parents, with the exec bit the manifest asks for.
///
/// The mode is set AT CREATION rather than afterwards: a chmod after the fact is a second syscall per file
/// and, more importantly, leaves a window where the file exists with the wrong mode. Only the exec bit
/// survives into a NAR (Nix records executable-or-not and nothing else), so 0755/0644 is the whole story.
pub fn create_file(root: &Path, rel: &str, executable: bool) -> Result<fs::File, String> {
    let p = safe_join(root, rel)?;
    if let Some(parent) = p.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(if executable { 0o755 } else { 0o644 })
        .open(&p)
        .map_err(|e| format!("create {}: {e}", p.display()))
}

/// Progress reporting shared by both stores' download loops, in the same shape the hashers print.
pub struct Progress {
    total: u64,
    seen: u64,
    last_pct: u64,
    enabled: bool,
}

impl Progress {
    pub fn new(total: u64, enabled: bool) -> Self {
        Self {
            total,
            seen: 0,
            last_pct: 0,
            enabled,
        }
    }
    pub fn add(&mut self, n: u64) {
        self.seen += n;
        if !self.enabled {
            return;
        }
        let pct = self
            .seen
            .checked_mul(100)
            .and_then(|v| v.checked_div(self.total))
            .unwrap_or(100);
        if pct > self.last_pct {
            self.last_pct = pct;
            eprint!("\r  {pct:3}%  {} / {} MiB", self.seen >> 20, self.total >> 20);
        }
    }
    pub fn finish(&self) {
        if self.enabled {
            eprintln!();
        }
    }
}

/// What a download produced, for the caller to report.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Written {
    pub files: u64,
    pub dirs: u64,
    pub bytes: u64,
}

/// `fsync` the tree's parent so the caller cannot observe a half-durable result.
///
/// Not for crash-safety — a Nix builder that dies is retried from scratch — but because the next thing to
/// touch these bytes is usually a hash over them, and on some filesystems a rename/readdir immediately
/// after a large write can otherwise race.
pub fn sync_dir(root: &Path) -> io::Result<()> {
    fs::File::open(root)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_paths_that_escape_the_output_directory() {
        let root = Path::new("/out");
        // The whole point: a manifest is network input, and these are the shapes that would write
        // outside the directory a builder handed us.
        for bad in [
            "../etc/passwd",
            "a/../../etc/passwd",
            "/etc/passwd",
            "./x",
            "",
        ] {
            assert!(
                safe_join(root, bad).is_err(),
                "must refuse {bad:?}, got {:?}",
                safe_join(root, bad)
            );
        }
        assert!(safe_join(root, "a\0b").is_err(), "must refuse an embedded NUL");
    }

    #[test]
    fn accepts_ordinary_manifest_paths() {
        let root = Path::new("/out");
        assert_eq!(safe_join(root, "game.exe").unwrap(), Path::new("/out/game.exe"));
        assert_eq!(
            safe_join(root, "x64/data/errorcodes/american.txt").unwrap(),
            Path::new("/out/x64/data/errorcodes/american.txt")
        );
        // A space, a dot and a dash are all ordinary in real game trees.
        assert_eq!(
            safe_join(root, "Hollow Knight_Data/x86_64/lib.so.1").unwrap(),
            Path::new("/out/Hollow Knight_Data/x86_64/lib.so.1")
        );
    }

    #[test]
    fn writes_the_exec_bit_the_manifest_asks_for() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("propnix-dl-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        create_file(&dir, "sub/plain.txt", false).unwrap();
        create_file(&dir, "sub/run.sh", true).unwrap();
        let mode = |p: &str| {
            fs::metadata(dir.join(p)).unwrap().permissions().mode() & 0o777
        };
        // Only the exec bit survives into a NAR, so that is the bit that must be right.
        assert_eq!(mode("sub/plain.txt") & 0o111, 0, "plain file must not be executable");
        assert_ne!(mode("sub/run.sh") & 0o111, 0, "executable file must be");
        fs::remove_dir_all(&dir).unwrap();
    }
}
