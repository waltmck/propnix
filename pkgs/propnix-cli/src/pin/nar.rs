//! Streaming NAR serialization — computes a Nix fixed-output hash in O(1) space.
//!
//! WHY THIS WORKS. A Nix recursive (`outputHashMode = "recursive"`) fixed-output hash is *exactly* sha256
//! of the NAR serialization of `$out`, and a NAR encodes only:
//!   * directory entries, sorted by name in BYTE order,
//!   * each node's type (directory / regular / symlink),
//!   * an "executable" marker on regular files,
//!   * symlink targets, and
//!   * file contents, u64-LE length-prefixed and zero-padded to a multiple of 8.
//!
//! It records no mtimes, no owners, and no permission bits besides the executable bit. Verified against
//! the real thing: `nix-store --dump d | nix-hash --type sha256 --flat` == `nix hash path d`.
//!
//! So the NAR byte stream is a pure function of (tree metadata) + (file bytes in tree order). Store
//! manifests carry the complete tree metadata, and both Steam's and GOG's CDNs are random-access at chunk
//! granularity — so the hash can be computed while holding nothing but a hash state and a small
//! read-ahead window. The game never touches disk.
//!
//! The alternative — download the title and run `nix hash path` — needs free disk equal to the game,
//! which for a modern AAA title is hundreds of GB and does not fit on a CI runner.
//!
//! NOTE ON BANDWIDTH: space is O(1); network is not, and cannot be. Manifests pin files by MD5/SHA-1, and
//! no SHA-256 is derivable from those, so every byte must cross the wire once. Only storage goes away.

use std::collections::BTreeMap;
use std::fmt;
use std::io::{self, Write};

use sha2::{Digest, Sha256};

/// A node in the tree to be serialized. `P` identifies a regular file's content to the fetcher.
pub enum Node<P> {
    /// `BTreeMap<Vec<u8>, _>` is load-bearing: its ordering is lexicographic over BYTES, which is exactly
    /// the order NAR requires. Sorting `String`s would compare by code point and silently emit an
    /// unsorted (invalid) NAR for non-ASCII names.
    Dir(BTreeMap<Vec<u8>, Node<P>>),
    Reg {
        executable: bool,
        size: u64,
        payload: P,
    },
    Link(Vec<u8>),
}

#[derive(Debug, Default, Clone, Copy)]
pub struct Stats {
    pub files: u64,
    pub dirs: u64,
    pub links: u64,
    pub content_bytes: u64,
    pub nar_bytes: u64,
}

#[derive(Debug)]
pub enum NarError {
    /// Two manifest entries claim the same path, or a file is used as a directory. Silently resolving
    /// this would yield a plausible but WRONG hash, so it is fatal.
    Conflict(String),
    /// The fetcher produced a different number of bytes than the manifest declared.
    Size { path: String, want: u64, got: u64 },
    Io(io::Error),
    Fetch(String),
}

impl fmt::Display for NarError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NarError::Conflict(p) => write!(f, "conflicting tree entries at {p:?}"),
            NarError::Size { path, want, got } => write!(
                f,
                "{path:?}: manifest declares {want} bytes but the source produced {got}"
            ),
            NarError::Io(e) => write!(f, "io error: {e}"),
            NarError::Fetch(m) => write!(f, "fetch failed: {m}"),
        }
    }
}

impl std::error::Error for NarError {}

impl From<io::Error> for NarError {
    fn from(e: io::Error) -> Self {
        NarError::Io(e)
    }
}

impl<P> Node<P> {
    pub fn dir() -> Self {
        Node::Dir(BTreeMap::new())
    }

    /// Insert `node` at `parts`, creating parent directories.
    ///
    /// An explicit directory entry may land on a directory that already exists implicitly (created as
    /// somebody's parent) — that is how manifests that list both `a/b` and `a` behave. Anything else is a
    /// genuine duplicate and is rejected.
    ///
    /// DEFENCE IN DEPTH on the path itself: an empty, `.` or `..` component would place the node
    /// somewhere other than where its literal path reads, so the NAR would not describe the tree the
    /// fetcher builds. The store modules refuse these at the manifest, where the error can name the
    /// manifest; this is the backstop for every future caller.
    pub fn insert(&mut self, parts: &[Vec<u8>], node: Node<P>) -> Result<(), NarError> {
        for p in parts {
            if p.is_empty() || p == b"." || p == b".." {
                return Err(NarError::Conflict(format!(
                    "{}: {:?} is not a usable path component",
                    show(parts),
                    String::from_utf8_lossy(p)
                )));
            }
        }
        let (leaf, dirs) = match parts.split_last() {
            Some(x) => x,
            None => return Err(NarError::Conflict("<empty path>".into())),
        };
        let mut cur = self;
        for (i, p) in dirs.iter().enumerate() {
            let entries = match cur {
                Node::Dir(m) => m,
                _ => return Err(NarError::Conflict(show(&parts[..=i]))),
            };
            cur = entries.entry(p.clone()).or_insert_with(Node::dir);
        }
        let entries = match cur {
            Node::Dir(m) => m,
            _ => return Err(NarError::Conflict(show(parts))),
        };
        match entries.get(leaf) {
            None => {
                entries.insert(leaf.clone(), node);
                Ok(())
            }
            // Merging an explicit-onto-implicit directory is only a no-op when the incoming one is
            // EMPTY. Accepting a populated one would silently DISCARD its children — a smaller tree
            // than the manifest describes, and a plausible-looking wrong hash.
            Some(Node::Dir(_)) => match &node {
                Node::Dir(m) if m.is_empty() => Ok(()),
                _ => Err(NarError::Conflict(show(parts))),
            },
            Some(_) => Err(NarError::Conflict(show(parts))),
        }
    }
}

fn show(parts: &[Vec<u8>]) -> String {
    parts
        .iter()
        .map(|p| String::from_utf8_lossy(p).into_owned())
        .collect::<Vec<_>>()
        .join("/")
}

/// A sink that feeds sha256 while counting. Nothing is buffered.
struct HashSink {
    h: Sha256,
    n: u64,
}

impl HashSink {
    fn raw(&mut self, b: &[u8]) {
        self.h.update(b);
        self.n += b.len() as u64;
    }

    fn pad(&mut self, n: u64) {
        let r = (n % 8) as usize;
        if r != 0 {
            self.raw(&[0u8; 8][..8 - r]);
        }
    }

    fn u64le(&mut self, v: u64) {
        self.raw(&v.to_le_bytes());
    }

    fn blob(&mut self, b: &[u8]) {
        self.u64le(b.len() as u64);
        self.raw(b);
        self.pad(b.len() as u64);
    }
}

/// Wraps the hash sink for a single file's contents so overruns are caught at the write, and so the
/// fetcher can be a plain `Write` implementation that knows nothing about NAR.
struct FileSink<'a> {
    inner: &'a mut HashSink,
    written: u64,
    limit: u64,
}

impl Write for FileSink<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.written += buf.len() as u64;
        if self.written > self.limit {
            return Err(io::Error::other(format!(
                "source produced {} bytes, more than the declared {}",
                self.written, self.limit
            )));
        }
        self.inner.raw(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Serialize `root` into a sha256, pulling each regular file's bytes on demand via `fetch`.
///
/// `fetch` must write exactly the declared number of bytes for the file. Peak memory is whatever buffer
/// the fetcher uses internally — no file, and no tree, is ever held.
pub fn nar_hash<P, F>(root: &Node<P>, mut fetch: F) -> Result<(String, Stats), NarError>
where
    F: FnMut(&P, &mut dyn Write) -> Result<(), NarError>,
{
    let mut sink = HashSink {
        h: Sha256::new(),
        n: 0,
    };
    let mut stats = Stats::default();
    sink.blob(b"nix-archive-1");
    emit(root, &mut sink, &mut stats, &mut fetch, &mut Vec::new())?;
    stats.nar_bytes = sink.n;
    let digest = sink.h.finalize();
    Ok((format!("sha256-{}", b64(&digest)), stats))
}

fn emit<P, F>(
    node: &Node<P>,
    sink: &mut HashSink,
    stats: &mut Stats,
    fetch: &mut F,
    path: &mut Vec<Vec<u8>>,
) -> Result<(), NarError>
where
    F: FnMut(&P, &mut dyn Write) -> Result<(), NarError>,
{
    sink.blob(b"(");
    sink.blob(b"type");
    match node {
        Node::Dir(entries) => {
            stats.dirs += 1;
            sink.blob(b"directory");
            for (name, child) in entries {
                sink.blob(b"entry");
                sink.blob(b"(");
                sink.blob(b"name");
                sink.blob(name);
                sink.blob(b"node");
                path.push(name.clone());
                emit(child, sink, stats, fetch, path)?;
                path.pop();
                sink.blob(b")");
            }
        }
        Node::Link(target) => {
            stats.links += 1;
            sink.blob(b"symlink");
            sink.blob(b"target");
            sink.blob(target);
        }
        Node::Reg {
            executable,
            size,
            payload,
        } => {
            stats.files += 1;
            sink.blob(b"regular");
            if *executable {
                sink.blob(b"executable");
                sink.blob(b"");
            }
            sink.blob(b"contents");
            sink.u64le(*size);
            let written = {
                let mut fs = FileSink {
                    inner: sink,
                    written: 0,
                    limit: *size,
                };
                fetch(payload, &mut fs)?;
                fs.written
            };
            if written != *size {
                return Err(NarError::Size {
                    path: show(path),
                    want: *size,
                    got: written,
                });
            }
            stats.content_bytes += written;
            sink.pad(*size);
        }
    }
    sink.blob(b")");
    Ok(())
}

fn b64(bytes: &[u8]) -> String {
    // Standard base64 with padding, matching Nix's SRI rendering. Hand-rolled to keep the dependency
    // tree at exactly one crate (sha2); this runs once per invocation on 32 bytes.
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let v = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(T[(v >> 18 & 63) as usize] as char);
        out.push(T[(v >> 12 & 63) as usize] as char);
        out.push(if c.len() > 1 {
            T[(v >> 6 & 63) as usize] as char
        } else {
            '='
        });
        out.push(if c.len() > 2 {
            T[(v & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// The regular files of `root`, in exactly the order `nar_hash` will ask for them.
///
/// A streaming fetcher must queue its work in this order — NAR emission is strictly sequential, so a
/// read-ahead queue built in any other order would deadlock or serve the wrong bytes.
pub fn flatten<P>(root: &Node<P>) -> Vec<&P> {
    fn walk<'a, P>(n: &'a Node<P>, out: &mut Vec<&'a P>) {
        match n {
            Node::Dir(entries) => {
                for child in entries.values() {
                    walk(child, out);
                }
            }
            Node::Reg { payload, .. } => out.push(payload),
            Node::Link(_) => {}
        }
    }
    let mut out = Vec::new();
    walk(root, &mut out);
    out
}

/// Build a tree from a real directory. Used by the offline tests to check this module against the
/// authority (`nix hash path`), and by `propnix-pin verify-local`.
pub fn local_tree(root: &std::path::Path) -> io::Result<Node<std::path::PathBuf>> {
    fn build(p: &std::path::Path) -> io::Result<Node<std::path::PathBuf>> {
        let md = std::fs::symlink_metadata(p)?;
        if md.file_type().is_symlink() {
            let t = std::fs::read_link(p)?;
            return Ok(Node::Link(
                std::os::unix::ffi::OsStrExt::as_bytes(t.as_os_str()).to_vec(),
            ));
        }
        if md.is_dir() {
            let mut m = BTreeMap::new();
            for e in std::fs::read_dir(p)? {
                let e = e?;
                m.insert(
                    std::os::unix::ffi::OsStrExt::as_bytes(e.file_name().as_os_str()).to_vec(),
                    build(&e.path())?,
                );
            }
            return Ok(Node::Dir(m));
        }
        use std::os::unix::fs::PermissionsExt;
        Ok(Node::Reg {
            executable: md.permissions().mode() & 0o111 != 0,
            size: md.len(),
            payload: p.to_path_buf(),
        })
    }
    build(root)
}

pub fn local_fetch(p: &std::path::PathBuf, out: &mut dyn Write) -> Result<(), NarError> {
    let mut f = std::fs::File::open(p)?;
    io::copy(&mut f, out)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hash_of(root: &Node<std::path::PathBuf>) -> String {
        nar_hash(root, |p, w| local_fetch(p, w)).unwrap().0
    }

    #[test]
    fn empty_dir_matches_nix() {
        // `nix hash path` on an empty directory.
        let d = tempdir();
        assert_eq!(
            hash_of(&local_tree(&d).unwrap()),
            "sha256-pQpattmS9VmO3ZIQUFn66az8GSmB4IvYhTTCFn6SUmo="
        );
    }

    #[test]
    fn single_file_matches_nix() {
        let d = tempdir();
        std::fs::write(d.join("f"), b"hello").unwrap();
        assert_eq!(
            hash_of(&local_tree(&d).unwrap()),
            "sha256-oXrRHZyHzNnIZMfEaXjY/Xck0qL62ktH+jE71iyavNc="
        );
    }

    #[test]
    fn byte_order_not_codepoint_order() {
        // Names that sort differently by byte than by Unicode scalar. If this module ever sorted
        // Strings instead of byte vectors, the NAR would be invalid and the hash wrong.
        let mut d: BTreeMap<Vec<u8>, Node<std::path::PathBuf>> = BTreeMap::new();
        for n in ["Z", "a", "\u{e9}", "~"] {
            d.insert(n.as_bytes().to_vec(), Node::Link(b"x".to_vec()));
        }
        let keys: Vec<&[u8]> = d.keys().map(|k| k.as_slice()).collect();
        let mut sorted = keys.clone();
        sorted.sort();
        assert_eq!(keys, sorted, "BTreeMap must already be in byte order");
        assert_eq!(keys[0], b"Z");
        assert_eq!(keys.last().unwrap(), &"\u{e9}".as_bytes());
    }

    #[test]
    fn duplicate_entry_is_fatal() {
        let mut root: Node<u32> = Node::dir();
        let p = vec![b"a".to_vec(), b"b".to_vec()];
        root.insert(
            &p,
            Node::Reg {
                executable: false,
                size: 0,
                payload: 1,
            },
        )
        .unwrap();
        assert!(root
            .insert(
                &p,
                Node::Reg {
                    executable: false,
                    size: 0,
                    payload: 2
                }
            )
            .is_err());
    }

    #[test]
    fn merging_directories_never_silently_drops_children() {
        let mut root: Node<u32> = Node::dir();
        // The legitimate case: an explicit EMPTY directory entry landing on one already created as
        // somebody's parent.
        root.insert(&[b"a".to_vec(), b"b".to_vec()], Node::Reg { executable: false, size: 0, payload: 1 })
            .unwrap();
        root.insert(&[b"a".to_vec()], Node::dir()).unwrap();

        // …but a POPULATED directory inserted over an existing one would have its children discarded.
        let mut populated: Node<u32> = Node::dir();
        populated
            .insert(&[b"child".to_vec()], Node::Reg { executable: false, size: 0, payload: 2 })
            .unwrap();
        assert!(
            root.insert(&[b"a".to_vec()], populated).is_err(),
            "silently dropping the inserted dir's children would yield a plausible but wrong hash"
        );
    }

    #[test]
    fn unusable_path_components_are_rejected() {
        let mut root: Node<u32> = Node::dir();
        let reg = || Node::Reg { executable: false, size: 0, payload: 0 };
        for bad in [b"".to_vec(), b".".to_vec(), b"..".to_vec()] {
            assert!(root.insert(&[b"a".to_vec(), bad.clone()], reg()).is_err(), "{bad:?}");
            assert!(root.insert(&[bad, b"a".to_vec()], reg()).is_err());
        }
        root.insert(&[b"a".to_vec(), b"b".to_vec()], reg()).unwrap();
    }

    #[test]
    fn short_read_is_fatal() {
        let mut root: Node<u32> = Node::dir();
        root.insert(
            &[b"f".to_vec()],
            Node::Reg {
                executable: false,
                size: 10,
                payload: 0,
            },
        )
        .unwrap();
        let r = nar_hash(&root, |_, w| {
            w.write_all(b"short")?;
            Ok(())
        });
        assert!(matches!(r, Err(NarError::Size { .. })));
    }

    #[test]
    fn overrun_is_fatal() {
        let mut root: Node<u32> = Node::dir();
        root.insert(
            &[b"f".to_vec()],
            Node::Reg {
                executable: false,
                size: 2,
                payload: 0,
            },
        )
        .unwrap();
        let r = nar_hash(&root, |_, w| {
            w.write_all(b"toolong")?;
            Ok(())
        });
        assert!(r.is_err());
    }

    #[test]
    fn base64_matches_known_vectors() {
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"foob"), "Zm9vYg==");
        assert_eq!(b64(&[0xff, 0xfe, 0xfd]), "//79");
    }

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "propnix-pin-test-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }
}
