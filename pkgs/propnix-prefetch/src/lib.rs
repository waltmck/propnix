//! propnix-prefetch — a LIBRARY the launcher links (not a separate binary): `warm` asynchronously heats the
//! ZFS ARC / page cache for a set of paths, without contending with a concurrent synchronous consumer (e.g.
//! wine's demand page-faults during a cold launch). The launcher's sole cold-launch prefetcher (RESEARCH §19).
//!
//! For every regular file under the given roots it issues `posix_fadvise(WILLNEED)` in ≤`chunk`-byte windows.
//! On ZFS that maps to `dmu_prefetch(…, ZIO_PRIORITY_ASYNC_READ)` — real reads that populate the ARC at a
//! priority the vdev scheduler runs *behind* synchronous demand reads, so wine keeps I/O priority; on
//! generic_fadvise filesystems it degrades to ordinary readahead. Chunking to ≤`dmu_prefetch_max` (default
//! 128 MiB) keeps every window on the L0-data path so whole files are covered. The calls are quick +
//! non-blocking; issuing them across many files is parallelised over a tokio blocking pool.
//!
//! Env: PROPNIX_PREFETCH_JOBS (default 16) concurrent fadvise workers; PROPNIX_PREFETCH_CHUNK (default
//! 134217728) bytes per WILLNEED window (≤ dmu_prefetch_max).

mod prefetch;

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::Semaphore;

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Best-effort: warm the ZFS ARC / page cache for every regular file under `roots`. Builds a small tokio
/// runtime + a bounded blocking pool of fadvise workers and blocks until they finish. Intended to run on a
/// detached launcher thread just before wine cold-starts (fire-and-forget; failures are ignored). No-op if
/// the roots contain no files.
pub fn warm(roots: &[PathBuf]) {
    // Directory walk is cheap → do it synchronously up front and collect the file list.
    let mut files: Vec<PathBuf> = Vec::new();
    for r in roots {
        prefetch::collect(r, &mut files);
    }
    if files.is_empty() {
        return;
    }

    let jobs = env_u64("PROPNIX_PREFETCH_JOBS", 16).max(1) as usize;
    let chunk = env_u64("PROPNIX_PREFETCH_CHUNK", 128 * 1024 * 1024).max(1);

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2) // just orchestration; the blocking pool (bounded by the Semaphore) does the work
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return, // best-effort — if we can't even build a runtime, skip warming
    };

    let advised = Arc::new(AtomicU64::new(0));
    rt.block_on(async {
        let sem = Arc::new(Semaphore::new(jobs));
        let mut handles = Vec::with_capacity(files.len());
        for f in files {
            let permit = match sem.clone().acquire_owned().await {
                Ok(p) => p,
                Err(_) => break,
            };
            let advised = advised.clone();
            handles.push(tokio::task::spawn_blocking(move || {
                let _permit = permit; // released when this blocking task finishes
                if prefetch::advise(&f, chunk) {
                    advised.fetch_add(1, Ordering::Relaxed);
                }
            }));
        }
        for h in handles {
            let _ = h.await;
        }
    });
}
