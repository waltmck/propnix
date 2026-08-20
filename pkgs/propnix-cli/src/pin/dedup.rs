//! Fetch each distinct chunk ONCE — manifests deduplicate content, so the transport should too.
//!
//! Both stores address chunks by content, so the same bytes can appear at many places in one tree: an
//! asset shipped twice, a file duplicated per locale, Steam chunks shared across files. A work list with
//! one request per OCCURRENCE re-downloads all of them. The two sinks need different machinery to avoid
//! that:
//!
//!   * **Download (unordered)** needs no state here at all, only a wider placement table: a distinct
//!     chunk is fetched once and written to EVERY (file, offset) that references it — `pwrite` has no
//!     ordering to respect. The store download loops build that table themselves; this module is not
//!     involved.
//!   * **Hashing (ordered)** must emit the bytes at every occurrence IN NAR ORDER, and the engine delivers
//!     each fetched block exactly once — so a duplicate's bytes have to be RETAINED from the occurrence
//!     that fetched them until the last occurrence that reads them. Unbounded retention is a memory hole:
//!     a chunk repeated at the start and the end of a 100 GB tree would pin its bytes for the whole run.
//!     So retention is BUDGETED, and the split is decided STATICALLY, here, before the engine starts:
//!     duplicates whose bytes fit in the budget are served from memory; the rest are simply fetched again
//!     (costing exactly what they cost before this module existed). Static planning is what keeps both
//!     the engine's work list and the cache's peak size exact — nothing adapts mid-run, so nothing can
//!     drift.
//!
//! Retention is all-or-nothing per distinct chunk, decided at its FIRST occurrence: either every later
//! occurrence reads the cache, or every one refetches. Splitting per-occurrence (cache the near ones,
//! refetch the far ones) would buy a little budget headroom at the cost of a plan whose residency
//! intervals no longer nest, which is more machinery than the tail case justifies.
//!
//! The cache key is chosen by the CALLER, because identity is a store fact: Steam's chunk id IS the sha1
//! of the plaintext (plus the declared size, for paranoia); GOG chunks are keyed by (product,
//! compressedMd5, md5, size) — product included because chunks are fetched through a per-product
//! `secure_link`, and nothing guarantees another product's link serves the same object path.

use std::collections::HashMap;
use std::hash::Hash;

/// What to do at one NAR-order occurrence.
enum Step {
    /// Pull the next block from the engine; `retain_for` later occurrences will read it from memory.
    Fetch { unique: usize, retain_for: usize },
    /// Serve the retained copy of `unique`, freeing it on the last read.
    Cached { unique: usize },
}

/// The static plan plus its runtime cache. Drive it with `next()` once per occurrence, in order.
pub struct Dedup {
    steps: Vec<Step>,
    held: HashMap<usize, (Vec<u8>, usize)>,
    pos: usize,
    /// (occurrences served from memory, bytes of refetch avoided) — for the caller's log line.
    stats: (usize, u64),
}

/// Plan retention for `keys[i]`/`sizes[i]` (one entry per occurrence, in NAR emission order), holding at
/// most `cache_budget` bytes at any moment. Returns the plan and the occurrence indices the engine must
/// actually fetch, in order — the caller builds the engine's work list from exactly those.
pub fn plan<K: Eq + Hash>(keys: &[K], sizes: &[u64], cache_budget: u64) -> (Dedup, Vec<usize>) {
    // Pass 1: identity. Distinct chunks get dense ids; count each one's occurrences and find its last.
    let mut id_of: HashMap<&K, usize> = HashMap::new();
    let mut unique_at: Vec<usize> = Vec::with_capacity(keys.len());
    let mut occurrences: Vec<usize> = Vec::new();
    let mut last_pos: Vec<usize> = Vec::new();
    let mut size_of: Vec<u64> = Vec::new();
    for (p, k) in keys.iter().enumerate() {
        let next_id = occurrences.len();
        let id = *id_of.entry(k).or_insert(next_id);
        if id == next_id {
            occurrences.push(0);
            last_pos.push(0);
            size_of.push(sizes[p]);
        }
        occurrences[id] += 1;
        last_pos[id] = p;
        unique_at.push(id);
    }

    // Pass 2: residency. Walk in emission order with a running byte total; a distinct chunk with later
    // occurrences is retained iff it fits the budget ALONGSIDE everything already resident at that
    // moment — the greedy is first-come, which favors short residencies just by arrival order.
    let mut resident: Vec<bool> = vec![false; occurrences.len()];
    let mut seen: Vec<bool> = vec![false; occurrences.len()];
    let mut resident_bytes = 0u64;
    let mut steps = Vec::with_capacity(keys.len());
    let mut fetch = Vec::new();
    let mut stats = (0usize, 0u64);
    for (p, &u) in unique_at.iter().enumerate() {
        if !seen[u] {
            seen[u] = true;
            let later = occurrences[u] - 1;
            let retain_for = if later > 0 && resident_bytes + size_of[u] <= cache_budget {
                resident[u] = true;
                resident_bytes += size_of[u];
                stats.0 += later;
                stats.1 += size_of[u] * later as u64;
                later
            } else {
                0
            };
            steps.push(Step::Fetch { unique: u, retain_for });
            fetch.push(p);
        } else if resident[u] {
            steps.push(Step::Cached { unique: u });
            if p == last_pos[u] {
                resident[u] = false;
                resident_bytes -= size_of[u];
            }
        } else {
            // A duplicate the budget could not hold: fetched again, exactly as before dedup existed.
            steps.push(Step::Fetch { unique: u, retain_for: 0 });
            fetch.push(p);
        }
    }
    (
        Dedup {
            steps,
            held: HashMap::new(),
            pos: 0,
            stats,
        },
        fetch,
    )
}

impl Dedup {
    /// The bytes for the next occurrence, calling `pull` (the engine) only when the plan fetches.
    pub fn next(&mut self, pull: impl FnOnce() -> Result<Vec<u8>, String>) -> Result<Vec<u8>, String> {
        let step = self
            .steps
            .get(self.pos)
            .ok_or_else(|| "dedup: consumed past the end of the plan".to_string())?;
        self.pos += 1;
        match *step {
            Step::Fetch { unique, retain_for } => {
                let v = pull()?;
                if retain_for > 0 {
                    self.held.insert(unique, (v.clone(), retain_for));
                }
                Ok(v)
            }
            Step::Cached { unique } => {
                let remaining = {
                    let e = self
                        .held
                        .get_mut(&unique)
                        .ok_or_else(|| "dedup: cache miss (plan bug)".to_string())?;
                    e.1 -= 1;
                    e.1
                };
                if remaining == 0 {
                    // Last reader takes the buffer itself; nothing is cloned on the way out.
                    Ok(self.held.remove(&unique).expect("entry just read").0)
                } else {
                    Ok(self.held.get(&unique).expect("entry just read").0.clone())
                }
            }
        }
    }

    /// (occurrences that will be served from memory, bytes of refetch that avoids).
    pub fn stats(&self) -> (usize, u64) {
        self.stats
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    /// Drive a plan to completion, with `pull` returning `base + unique key` so content is checkable.
    fn run(keys: &[u8], sizes: &[u64], budget: u64) -> (Vec<Vec<u8>>, usize) {
        let (mut dd, fetch) = plan(keys, sizes, budget);
        let pulls = Cell::new(0usize);
        let mut out = Vec::new();
        let mut fetch_iter = fetch.iter();
        for _ in 0..keys.len() {
            let v = dd
                .next(|| {
                    pulls.set(pulls.get() + 1);
                    // The engine would deliver the block for the NEXT planned fetch position.
                    let p = *fetch_iter.next().expect("plan pulled more than it planned");
                    Ok(vec![keys[p]; sizes[p] as usize])
                })
                .unwrap();
            out.push(v);
        }
        assert!(fetch_iter.next().is_none(), "every planned fetch must be consumed");
        (out, pulls.get())
    }

    #[test]
    fn duplicates_are_served_from_memory_exactly_once_fetched() {
        // Chunk 7 appears three times; it must be pulled once and emitted three times, byte-identical.
        let keys = [7u8, 1, 7, 2, 7];
        let sizes = [4u64; 5];
        let (out, pulls) = run(&keys, &sizes, 1 << 20);
        assert_eq!(pulls, 3, "three distinct chunks, three pulls");
        for (i, k) in keys.iter().enumerate() {
            assert_eq!(out[i], vec![*k; 4], "occurrence {i} content");
        }
    }

    #[test]
    fn unique_chunks_pass_straight_through() {
        let keys = [1u8, 2, 3, 4];
        let sizes = [8u64; 4];
        let (out, pulls) = run(&keys, &sizes, 1 << 20);
        assert_eq!(pulls, 4);
        assert_eq!(out.len(), 4);
        let (dd, fetch) = plan(&keys, &sizes, 1 << 20);
        assert_eq!(fetch, vec![0, 1, 2, 3]);
        assert_eq!(dd.stats(), (0, 0));
    }

    #[test]
    fn a_duplicate_past_the_budget_is_refetched_not_pinned() {
        // Two duplicated chunks of 100 bytes each, but only 100 bytes of budget: the first is retained,
        // the second must be planned as a refetch — the budget is a ceiling, never exceeded.
        let keys = [1u8, 2, 1, 2];
        let sizes = [100u64; 4];
        let (dd, fetch) = plan(&keys, &sizes, 100);
        assert_eq!(fetch, vec![0, 1, 3], "chunk 2's duplicate must be refetched");
        assert_eq!(dd.stats().0, 1, "only chunk 1's duplicate is served from memory");
        let (out, pulls) = run(&keys, &sizes, 100);
        assert_eq!(pulls, 3);
        assert_eq!(out[2], vec![1u8; 100]);
        assert_eq!(out[3], vec![2u8; 100]);
    }

    #[test]
    fn budget_frees_when_a_chunks_last_occurrence_passes() {
        // Chunk 1's residency ends at its last occurrence, releasing budget for chunk 2's duplicate.
        let keys = [1u8, 1, 2, 2];
        let sizes = [100u64; 4];
        let (dd, fetch) = plan(&keys, &sizes, 100);
        assert_eq!(fetch, vec![0, 2], "both duplicates fit sequentially in one 100-byte budget");
        assert_eq!(dd.stats(), (2, 200));
        let (_, pulls) = run(&keys, &sizes, 100);
        assert_eq!(pulls, 2);
    }

    #[test]
    fn a_zero_budget_disables_caching_but_stays_correct() {
        let keys = [5u8, 5, 5];
        let sizes = [10u64; 3];
        let (out, pulls) = run(&keys, &sizes, 0);
        assert_eq!(pulls, 3, "no budget, no retention — every occurrence fetches");
        for v in out {
            assert_eq!(v, vec![5u8; 10]);
        }
    }
}
