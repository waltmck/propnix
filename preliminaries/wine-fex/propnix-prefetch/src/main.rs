//! propnix-prefetch — asynchronously warm the ZFS ARC for a set of paths, without contending with a
//! concurrent synchronous consumer (e.g. wine's demand page-faults during a cold launch). winefex's sole
//! cold-launch prefetcher (RESEARCH §19).
//!
//! For every regular file under the given PATHs it issues `posix_fadvise(WILLNEED)` in ≤`chunk`-byte
//! windows. On ZFS that maps to `dmu_prefetch(…, ZIO_PRIORITY_ASYNC_READ)` — real reads that populate the
//! ARC at a priority the vdev scheduler runs *behind* synchronous demand reads, so wine keeps I/O
//! priority; on generic_fadvise filesystems it degrades to ordinary readahead. Chunking to
//! ≤`dmu_prefetch_max` (default 128 MiB) keeps every window on the L0-data path so whole files are
//! covered. The calls are quick + non-blocking; issuing them across many files is parallelised over a
//! tokio blocking pool.
//!
//! Usage: propnix-prefetch [-v|--verbose] PATH...
//! Env:   PROPNIX_PREFETCH_JOBS  (default 16)         concurrent fadvise workers
//!        PROPNIX_PREFETCH_CHUNK (default 134217728)  bytes per WILLNEED window (≤ dmu_prefetch_max)

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

fn main() {
    let mut verbose = false;
    let mut roots: Vec<PathBuf> = Vec::new();
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "-v" | "--verbose" => verbose = true,
            _ => roots.push(PathBuf::from(arg)),
        }
    }
    if roots.is_empty() {
        eprintln!("usage: propnix-prefetch [-v|--verbose] PATH...");
        std::process::exit(2);
    }

    // Directory walk is cheap → do it synchronously up front and collect the file list.
    let mut files: Vec<PathBuf> = Vec::new();
    for r in &roots {
        prefetch::collect(r, &mut files);
    }

    let jobs = env_u64("PROPNIX_PREFETCH_JOBS", 16).max(1) as usize;
    let chunk = env_u64("PROPNIX_PREFETCH_CHUNK", 128 * 1024 * 1024).max(1);

    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2) // just orchestration; the blocking pool (bounded by the Semaphore) does the work
        .build()
        .expect("build tokio runtime");

    let advised = Arc::new(AtomicU64::new(0));
    rt.block_on(async {
        let sem = Arc::new(Semaphore::new(jobs));
        let mut handles = Vec::with_capacity(files.len());
        for f in files {
            let permit = sem.clone().acquire_owned().await.expect("semaphore");
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

    if verbose {
        eprintln!(
            "propnix-prefetch: advised {} files (jobs={jobs}, chunk={chunk}B)",
            advised.load(Ordering::Relaxed)
        );
    }
}
