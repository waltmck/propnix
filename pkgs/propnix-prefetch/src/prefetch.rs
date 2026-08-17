//! Per-file prefetch logic: collect files, then `posix_fadvise(WILLNEED)` each in ≤`chunk`-byte windows.
//!
//! On ZFS `zpl_fadvise` maps `WILLNEED` to `dmu_prefetch(…, ZIO_PRIORITY_ASYNC_READ)`, which issues real
//! async reads that land L0 data in the ARC at a priority the vdev scheduler runs *behind* synchronous
//! demand reads (so it yields to e.g. wine's page faults). The catch: `dmu_prefetch_by_dnode` prefetches
//! only the first `dmu_prefetch_max` bytes (default 128 MiB) of L0 DATA per call — beyond that only
//! indirect/metadata blocks. So we issue one `WILLNEED` per ≤128 MiB window, stepping the offset, to keep
//! every window on the L0-data path and cover the whole file without touching the global tunable.
//! (RESEARCH §19.) Fire-and-forget: this only issues the hints; the async reads proceed in the kernel/ZFS.
//! `fadvise` is chosen over plain reads as the more portable/idiomatic warmer (it degrades to real reads
//! on generic_fadvise filesystems); reads are ~1.5 s faster on this ZFS host but the difference is small.

use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

// int posix_fadvise(int fd, off_t offset, off_t len, int advice);  off_t is 64-bit on Linux.
extern "C" {
    fn posix_fadvise(fd: i32, offset: i64, len: i64, advice: i32) -> i32;
}
const POSIX_FADV_WILLNEED: i32 = 3; // asm-generic value (same on aarch64 and x86_64)

/// Recursively collect regular-file paths under `path` whose extension matches `exts` (see `wanted`). Never
/// recurses THROUGH a symlink (cycle-safe against e.g. a wine prefix's `dosdevices/z: -> /`, and it keeps
/// `dosdevices/c: -> ../drive_c` from walking the tree twice), but a symlink whose target is a regular file
/// is included — opening it later follows the link, which is what warms wine's store-linked DLLs (the whole
/// i386 syswow64 set is symlinks into `${wine}/lib/wine/i386-windows`).
pub fn collect(path: &Path, out: &mut Vec<PathBuf>, exts: &[&str]) {
    let md = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => return,
    };
    let ft = md.file_type();
    if ft.is_dir() {
        if let Ok(entries) = fs::read_dir(path) {
            for entry in entries.flatten() {
                collect(&entry.path(), out, exts);
            }
        }
    } else if !wanted(path, exts) {
        // Filtered out before the (cheap, but not free) stat that resolves a symlink's target.
    } else if ft.is_symlink() {
        if let Ok(target) = fs::metadata(path) {
            if target.is_file() {
                out.push(path.to_path_buf());
            }
        }
    } else if ft.is_file() {
        out.push(path.to_path_buf());
    }
}

/// Does this file's extension match the allowlist? An EMPTY `exts` accepts every file (warm everything);
/// otherwise the extension must match one entry case-insensitively — Windows trees are case-insensitive by
/// convention, so a game shipping `Foo.DLL` alongside wine's lowercase `kernel32.dll` must still match.
/// An extensionless file never matches a non-empty allowlist.
fn wanted(path: &Path, exts: &[&str]) -> bool {
    if exts.is_empty() {
        return true;
    }
    match path.extension().and_then(|e| e.to_str()) {
        Some(ext) => exts.iter().any(|w| ext.eq_ignore_ascii_case(w)),
        None => false,
    }
}

/// Issue `posix_fadvise(WILLNEED)` over the whole file in `chunk`-byte windows (≤ `dmu_prefetch_max`), so
/// ZFS async-prefetches every L0 record, not just the first `dmu_prefetch_max`. Returns true if handled.
pub fn advise(path: &Path, chunk: u64) -> bool {
    let f = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    let len = match f.metadata() {
        Ok(m) => m.len(),
        Err(_) => return false,
    };
    let fd = f.as_raw_fd();
    let step = chunk.max(1);
    let mut off: u64 = 0;
    while off < len {
        let this = step.min(len - off);
        // Return value is an errno (0 == ok); ignore failures (best-effort).
        unsafe {
            posix_fadvise(fd, off as i64, this as i64, POSIX_FADV_WILLNEED);
        }
        off += this;
    }
    true
}
