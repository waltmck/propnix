//! Which CDN host to ask next — multiplicative weights over observed throughput.
//!
//! Steam hands back ~20-30 content servers for a cell, and they are NOT interchangeable: their load
//! differs, some are far away, and one can be degraded or down while the rest are fine. The directory's
//! own `weighted_load` is a hint at list-build time and nothing more — it does not know what THIS client
//! is actually getting, and it never updates during the hours a depot hash runs.
//!
//! Round-robin (what this replaced) treats every host as equally good forever. That has two costs. The
//! obvious one is throughput: a pool where a third of the hosts are half as fast drags the whole run down,
//! because every host still gets an equal share of requests. The sharper one is failure behaviour — a host
//! that is DOWN keeps getting its 1/N share of every sweep, so a fixed fraction of all chunk requests
//! fails and has to be re-fetched before it can succeed elsewhere.
//!
//! So: score hosts by the throughput they actually deliver and sample proportionally, with the classic
//! multiplicative-weights update. Each observation turns into a loss in [0,1] — 0 for "as fast as the best
//! host we have seen", 1 for a failure — and the host's weight is scaled by `exp(-ETA * loss)`. Good hosts
//! keep their weight, mediocre ones decay smoothly, and a dead one collapses within a few observations.
//!
//! Two properties matter more than the exact constants:
//!
//!   * **A collapsed host must keep a small share.** Weights are renormalized so the best is 1.0 and then
//!     clamped up to `W_MIN`, so every host keeps at least a few percent of the sampling mass. A host that
//!     went down is avoided within a few observations but is still probed occasionally, and once it starts
//!     answering again its weight climbs back over some tens of observations — which at ~3% of the draws
//!     is seconds of a real run, not minutes. Without the floor a transient blip would exile a good host
//!     for the rest of the run — a worse failure than the one this fixes.
//!   * **The normalizer decays.** `best_rate` is the yardstick losses are measured against; it decays
//!     slightly on every update so a single lucky burst cannot permanently make every host look bad.
//!
//! Sampling is randomized rather than deterministic-argmax on purpose: with 32+ workers picking
//! concurrently, argmax would stampede the single best host and immediately overload it.

use std::sync::Mutex;
use std::time::Duration;

/// Learning rate. Large enough that a dead host is effectively out after ~3 observations, small enough
/// that normal rate jitter between healthy hosts does not thrash the distribution.
const ETA: f64 = 0.7;
/// Weight floor, relative to the best host — the exploration/recovery share described above.
const W_MIN: f64 = 0.03;
/// Per-update decay of the throughput yardstick, so `best_rate` tracks reality instead of a lucky peak.
const BEST_DECAY: f64 = 0.999;
/// EWMA rate for the mean loss the update is measured against.
const AVG_ALPHA: f64 = 0.1;
/// Fixed-share mixing rate: each update pulls every weight this far toward the pool mean.
///
/// This is the Herbster-Warmuth "tracking the best expert" term, and it is what makes the pool handle a
/// CHANGING world rather than a fixed one. Plain multiplicative weights integrate the whole history, so a
/// host that was bad for a while stays discounted long after it recovers — it asymptotes short of parity
/// because, once every host performs alike, there is no signal left to close the gap. Mixing toward the
/// mean bounds how long stale evidence can dominate: a recovered host converges back to parity
/// geometrically, while a host that keeps failing is held down because its loss term outruns the mixing.
const SHARE: f64 = 0.02;

/// Scores a fixed set of candidates by INDEX. Deliberately does not own the candidates themselves: Steam
/// picks between host names, while GOG picks between signed `secure_link` endpoint templates, and the
/// scoring is identical either way.
pub struct HostPool {
    state: Mutex<State>,
}

struct State {
    weight: Vec<f64>,
    /// Bytes/sec of the best transfer seen lately; the denominator that turns a rate into a loss.
    best_rate: f64,
    /// Running mean loss across all hosts — the baseline each observation is judged against. Without it
    /// the update is one-directional (a success has loss 0, so it multiplies by `exp(0)` = 1) and a host
    /// that once fell to the floor could never climb back, however healthy it became.
    avg_loss: f64,
    rng: u64,
}

impl HostPool {
    /// `n` = how many candidates there are. Must match what the caller indexes.
    pub fn new(n: usize) -> Self {
        let n = n.max(1);
        Self {
            state: Mutex::new(State {
                weight: vec![1.0; n],
                best_rate: 0.0,
                avg_loss: 0.0,
                // Any fixed seed is fine: host choice cannot affect the output hash, and a fixed seed
                // makes a bad run reproducible.
                rng: 0x9E3779B97F4A7C15,
            }),
        }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.state.lock().unwrap().weight.len()
    }

    /// Sample a host index proportional to its weight.
    pub fn pick(&self) -> usize {
        let mut st = self.state.lock().unwrap();
        let total: f64 = st.weight.iter().sum();
        if !(total > 0.0) {
            // Degenerate (shouldn't happen: the floor keeps weights positive) — fall back to uniform.
            let n = st.weight.len();
            return (next_u64(&mut st.rng) % n as u64) as usize;
        }
        let mut r = unit_f64(next_u64(&mut st.rng)) * total;
        for (i, w) in st.weight.iter().enumerate() {
            r -= w;
            if r <= 0.0 {
                return i;
            }
        }
        st.weight.len() - 1 // float drift on the last bucket
    }

    /// A completed transfer: `bytes` moved in `elapsed`. Loss is how far short of the best rate we fell.
    pub fn record_success(&self, idx: usize, bytes: u64, elapsed: Duration) {
        let secs = elapsed.as_secs_f64();
        // A transfer too small or too fast to time says nothing about the host; don't let it move the
        // yardstick (it would make every honest observation look like a loss).
        if bytes == 0 || secs <= 0.0005 {
            return;
        }
        let rate = bytes as f64 / secs;
        let mut st = self.state.lock().unwrap();
        st.best_rate = (st.best_rate * BEST_DECAY).max(rate);
        let loss = if st.best_rate > 0.0 {
            (1.0 - rate / st.best_rate).clamp(0.0, 1.0)
        } else {
            0.0
        };
        st.apply(idx, loss);
    }

    /// A failed transfer — maximum loss. Repeated failures compound, so a genuinely dead host falls to the
    /// floor fast while a one-off blip costs a single update.
    pub fn record_failure(&self, idx: usize) {
        let mut st = self.state.lock().unwrap();
        st.apply(idx, 1.0);
    }

    #[cfg(test)]
    fn weights(&self) -> Vec<f64> {
        self.state.lock().unwrap().weight.clone()
    }
}

impl State {
    /// The multiplicative update, then renormalize-and-floor.
    ///
    /// The exponent is the loss RELATIVE to the running mean, not the raw loss: a host doing better than
    /// the pool average gains weight, one doing worse loses it. The raw-loss form is one-directional
    /// (`exp(-ETA * 0)` = 1, so a success is a no-op) and a host that once hit the floor could never come
    /// back — which the recovery test pins down.
    fn apply(&mut self, idx: usize, loss: f64) {
        if idx >= self.weight.len() {
            return;
        }
        self.weight[idx] *= (-ETA * (loss - self.avg_loss)).exp();
        self.avg_loss += AVG_ALPHA * (loss - self.avg_loss);
        // Rescale so the best host sits at 1.0. This keeps the weights in a fixed range whatever the run
        // length (every update multiplies by <= 1, so without this they would all drift to zero), and it
        // makes the floor below mean "relative to the best", which is the property we actually want.
        let max = self.weight.iter().cloned().fold(0.0f64, f64::max);
        if max > 0.0 {
            for w in self.weight.iter_mut() {
                *w /= max;
            }
        } else {
            for w in self.weight.iter_mut() {
                *w = 1.0;
            }
        }
        // Fixed share: drift every weight toward the pool mean, then re-floor.
        let n = self.weight.len() as f64;
        let mean = self.weight.iter().sum::<f64>() / n;
        for w in self.weight.iter_mut() {
            *w = ((1.0 - SHARE) * *w + SHARE * mean).max(W_MIN);
        }
    }
}

/// SplitMix64 — a few lines, no dependency, and plenty of quality for choosing a server.
fn next_u64(s: &mut u64) -> u64 {
    *s = s.wrapping_add(0x9E3779B97F4A7C15);
    let mut z = *s;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

fn unit_f64(x: u64) -> f64 {
    // 53 significant bits → [0,1).
    (x >> 11) as f64 / (1u64 << 53) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn share(pool: &HostPool, draws: usize) -> Vec<f64> {
        let mut counts = vec![0usize; pool.len()];
        for _ in 0..draws {
            counts[pool.pick()] += 1;
        }
        counts.iter().map(|c| *c as f64 / draws as f64).collect()
    }

    #[test]
    fn starts_uniform() {
        let pool = HostPool::new(4);
        for s in share(&pool, 20_000) {
            assert!((s - 0.25).abs() < 0.03, "expected ~uniform, got {s}");
        }
    }

    #[test]
    fn a_dead_host_collapses_but_keeps_a_recovery_share() {
        // The failure mode this avoids: an even split keeps sending 1/N of all chunks at a host that is
        // down, and every one of them has to fail and be re-fetched before it can succeed elsewhere.
        let pool = HostPool::new(2);
        for _ in 0..8 {
            pool.record_success(0, 8 << 20, Duration::from_secs(1));
            pool.record_failure(1);
        }
        // Not exactly W_MIN: the fixed-share term keeps pulling a little mass back toward the pool mean,
        // so a persistently-failing host settles just above the floor rather than on it. That equilibrium
        // IS the design — it is what keeps the host discoverable when it recovers.
        let w = pool.weights();
        assert!(w[1] < 0.05, "dead host should collapse to near the floor, got {:?}", w);

        let s = share(&pool, 20_000);
        assert!(s[1] < 0.06, "dead host should get a small share, got {}", s[1]);
        assert!(s[1] > 0.0, "…but never zero, or it could never be found healthy again");
    }

    #[test]
    fn a_recovered_host_climbs_back() {
        // The floor is what makes this possible: the host keeps being probed, so good observations land.
        let pool = HostPool::new(2);
        for _ in 0..8 {
            pool.record_success(0, 8 << 20, Duration::from_secs(1));
            pool.record_failure(1);
        }
        assert!(pool.weights()[1] < 0.05, "precondition: the host must have collapsed first");

        // Recovery is GRADUAL by construction: the exponent is driven by the running mean loss, which
        // itself decays as the failures stop, so each success buys less than the last. Tens of
        // observations, not one — and a floored host still draws ~3% of requests, which on a real depot
        // (tens of thousands of chunks) is seconds.
        for _ in 0..10 {
            pool.record_success(1, 8 << 20, Duration::from_secs(1));
        }
        let partial = pool.weights()[1];
        assert!(partial > W_MIN * 2.0, "should be climbing after 10 successes, got {partial}");

        for _ in 0..40 {
            pool.record_success(1, 8 << 20, Duration::from_secs(1));
        }
        let w = pool.weights();
        assert!(w[1] > 0.9, "a healthy host must return to full weight, got {:?}", w);
    }

    #[test]
    fn a_faster_host_wins_more_traffic() {
        let pool = HostPool::new(2);
        for _ in 0..30 {
            pool.record_success(0, 16 << 20, Duration::from_secs(1)); // 16 MB/s
            pool.record_success(1, 2 << 20, Duration::from_secs(1)); //  2 MB/s
        }
        let s = share(&pool, 20_000);
        assert!(s[0] > s[1] * 3.0, "fast host should dominate: {s:?}");
    }

    #[test]
    fn equally_fast_hosts_stay_balanced() {
        // Guards against the update collapsing onto one host through drift alone.
        let pool = HostPool::new(3);
        for _ in 0..50 {
            for i in 0..3 {
                pool.record_success(i, 8 << 20, Duration::from_secs(1));
            }
        }
        for s in share(&pool, 20_000) {
            assert!((s - 1.0 / 3.0).abs() < 0.05, "expected balance, got {s}");
        }
    }

    #[test]
    fn untimeable_transfers_do_not_move_the_yardstick() {
        // A 700-byte chunk served from a warm connection can time as ~0s; treating that as the best rate
        // ever seen would make every real transfer look like a total loss.
        let pool = HostPool::new(2);
        pool.record_success(0, 700, Duration::from_micros(10));
        for _ in 0..5 {
            pool.record_success(0, 8 << 20, Duration::from_secs(1));
            pool.record_success(1, 8 << 20, Duration::from_secs(1));
        }
        for w in pool.weights() {
            assert!(w > 0.9, "healthy hosts must not be punished by an untimeable sample");
        }
    }

    #[test]
    fn a_single_host_pool_always_picks_it() {
        let pool = HostPool::new(1);
        pool.record_failure(0);
        pool.record_failure(0);
        for _ in 0..100 {
            assert_eq!(pool.pick(), 0);
        }
    }
}
