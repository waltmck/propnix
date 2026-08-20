//! How many chunk requests to keep in flight — hill-climbing on measured throughput.
//!
//! The right number is not knowable up front. These CDNs rate-limit PER CONNECTION (measured on Steam's:
//! 9.2 Mbit/s over one connection, 90.9 over sixteen, 114.4 over thirty-two), so throughput climbs with
//! concurrency until something else becomes the limit — the local link, the far end's willingness, or the
//! NAR hasher downstream. Where that knee sits depends on the machine, the link, the cell's servers and
//! the time of day, which is exactly the kind of thing a hard-coded `--workers 32` gets wrong in both
//! directions: it leaves a fast link idle and it hammers a slow one into timeouts.
//!
//! So probe, but probe properly: HOLD the limit still for a few epochs, take the MEDIAN of what those
//! epochs measured as this rung's reading, then move one multiplicative step — continuing in the same
//! direction if the reading improved, reversing if it got worse or stopped changing. That settles into a
//! small oscillation around the knee and follows it when it moves. Holding and taking a median are both
//! load-bearing: real CDN throughput is noisy enough that comparing single samples makes the climb chase
//! its own variance (see `PROBE_EPOCHS`).
//!
//! Two overrides sit on top of the hill climb, because throughput alone would read both situations wrong:
//!
//!   * **Errors mean back off, immediately.** Timeouts and resets under load are the far end pushing
//!     back. Climbing further would turn a slow run into a failing one, and every failure costs a requeue
//!     and a second transfer of the same block. This is multiplicative-decrease, faster than the climb.
//!   * **Being blocked by the consumer is not a throughput ceiling.** When the emit window is full the
//!     workers are idle because the NAR hasher has not caught up, so measured throughput reflects the
//!     hasher, not the network. Raising the limit then would be reading its own tail: more connections
//!     cannot help, and the extra sockets are pure cost. Hold instead.

/// Fractional throughput change treated as noise rather than signal.
const NOISE: f64 = 0.03;
/// Epochs to HOLD the limit still while measuring it, before deciding where to move next.
///
/// Hill climbing only means something if each rung is measured while the limit sits still, and if the
/// statistic is robust. Raw per-epoch throughput on a real CDN is neither stable nor well-behaved:
/// consecutive epochs at a FIXED limit measured 1.0, 11.1 and 79.0 MB/s. Comparing single samples, most
/// steps looked like a large win in whatever direction the climb was already going, so the limit marched
/// to its ceiling and stayed there while average throughput collapsed to a fifth of its peak — congestion,
/// not progress.
///
/// So: hold, collect this many samples, and compare their MEDIAN. The median is the point — an average
/// (even exponentially weighted) still swings with an 8x outlier, whereas the median of five ignores it.
const PROBE_EPOCHS: usize = 5;
/// Multiplicative probe step.
const STEP_UP: f64 = 1.3;
/// Backoff on errors — faster than the climb, so a struggling link sheds load quickly.
const BACKOFF: f64 = 0.7;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Pressure {
    /// Workers were free to fetch; measured throughput is a real network reading.
    Network,
    /// Workers spent the epoch parked on the byte window — the consumer (the NAR hasher, or the window
    /// itself acting as download's memory bound) is behind, not the network.
    ConsumerBound,
}

pub struct Governor {
    limit: f64,
    min: f64,
    max: f64,
    /// +1 climbing, -1 backing off.
    dir: f64,
    /// Throughput samples collected at the CURRENT limit; the median becomes this rung's reading.
    samples: Vec<f64>,
    /// The previous rung's reading — what the next decision is judged against.
    prev: Option<f64>,
}

impl Governor {
    pub fn new(start: usize, min: usize, max: usize) -> Self {
        let min = min.max(1) as f64;
        let max = (max as f64).max(min);
        Self {
            limit: (start as f64).clamp(min, max),
            min,
            max,
            dir: 1.0,
            samples: Vec::with_capacity(PROBE_EPOCHS),
            prev: None,
        }
    }

    pub fn limit(&self) -> usize {
        self.limit.round().max(1.0) as usize
    }

    /// Fold in one epoch's observations and return the new limit.
    pub fn observe(&mut self, throughput: f64, pressure: Pressure, errors: u64) -> usize {
        if errors > 0 {
            // Shed load and remember which way we are going, so the next epoch does not immediately
            // climb back into the same wall.
            self.limit = (self.limit * BACKOFF).clamp(self.min, self.max);
            self.dir = -1.0;
            // Measured under failure: neither a baseline worth keeping nor a sample worth counting.
            self.prev = None;
            self.samples.clear();
            return self.limit();
        }
        if pressure == Pressure::ConsumerBound {
            // Hold. Also drop the baseline and the part-collected rung: a consumer-bound reading must
            // never be compared against, or averaged with, a network-bound one — the difference would be
            // attributed to the limit.
            self.prev = None;
            self.samples.clear();
            return self.limit();
        }

        // Still measuring this rung — hold the limit exactly where it is.
        self.samples.push(throughput);
        if self.samples.len() < PROBE_EPOCHS {
            return self.limit();
        }
        let reading = median(&mut self.samples);
        self.samples.clear();

        if let Some(prev) = self.prev {
            let change = if prev > 0.0 { (reading - prev) / prev } else { 1.0 };
            if change < -NOISE {
                self.dir = -self.dir; // that step made things worse — turn round
            } else if change.abs() <= NOISE {
                // At the knee: keep nudging so a moving optimum is still tracked, but turn round so we
                // oscillate around it instead of drifting away.
                self.dir = -self.dir;
            }
            // change > NOISE: the step helped, keep the same direction.
        }
        self.prev = Some(reading);

        let factor = if self.dir > 0.0 { STEP_UP } else { 1.0 / STEP_UP };
        self.limit = (self.limit * factor).clamp(self.min, self.max);
        self.limit()
    }
}

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    v[v.len() / 2]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A link whose throughput rises with concurrency until `knee`, then flattens.
    fn simulate(knee: usize, limit: usize) -> f64 {
        let per_conn = 9.0; // Mbit/s, the measured per-connection cap
        per_conn * limit.min(knee) as f64
    }

    #[test]
    fn climbs_toward_the_knee_and_settles_near_it() {
        let knee = 40;
        let mut g = Governor::new(4, 1, 256);
        for _ in 0..60 {
            let t = simulate(knee, g.limit());
            g.observe(t, Pressure::Network, 0);
        }
        let settled = g.limit();
        assert!(
            settled >= knee / 2 && settled <= knee * 3,
            "should settle around the knee ({knee}), got {settled}"
        );
    }

    #[test]
    fn does_not_run_away_when_more_connections_stop_helping() {
        // The failure this guards: a controller that only ever increases would end at `max`, opening
        // hundreds of useless sockets to a link that saturated long before.
        let mut g = Governor::new(4, 1, 512);
        for _ in 0..80 {
            let t = simulate(16, g.limit());
            g.observe(t, Pressure::Network, 0);
        }
        assert!(g.limit() < 128, "ran away to {}", g.limit());
    }

    #[test]
    fn survives_a_noisy_link_without_running_away() {
        // THE production failure this guards. On a real CDN, consecutive epochs at a FIXED limit measured
        // 1.0, 11.1 and 79.0 MB/s. Comparing raw samples, most steps look like a big win in whatever
        // direction the climb was already heading, so the limit marched to its ceiling and sat there
        // while average throughput collapsed to a fifth of its peak.
        let knee = 16;
        let mut g = Governor::new(4, 1, 256);
        // Deterministic, brutal multiplicative noise: x8 down to x0.05 of the true rate.
        let noise = [1.0, 0.05, 0.15, 1.0, 8.0, 0.2, 1.0, 3.0, 0.1, 1.0, 0.5, 6.0];
        for i in 0..200 {
            let truth = simulate(knee, g.limit());
            g.observe(truth * noise[i % noise.len()], Pressure::Network, 0);
        }
        assert!(
            g.limit() < 64,
            "noise must not push the limit to the ceiling: got {}",
            g.limit()
        );
    }

    #[test]
    fn errors_back_off_faster_than_the_climb() {
        let mut g = Governor::new(64, 1, 256);
        let before = g.limit();
        g.observe(50.0, Pressure::Network, 3);
        let after = g.limit();
        assert!(after < before, "an error epoch must reduce the limit");
        // …and faster than a single climb step would have raised it.
        assert!((before as f64 / after as f64) > STEP_UP * 0.9);
    }

    #[test]
    fn a_consumer_bound_epoch_holds_the_limit() {
        // Throughput is low, but because the hasher is behind — not the network. Climbing would add
        // sockets that cannot help; backing off would throttle the network for no reason.
        let mut g = Governor::new(32, 1, 256);
        let before = g.limit();
        for _ in 0..5 {
            g.observe(1.0, Pressure::ConsumerBound, 0);
        }
        assert_eq!(g.limit(), before, "a consumer-bound epoch must not move the limit");
    }

    #[test]
    fn a_consumer_bound_epoch_is_not_used_as_a_baseline() {
        // Regression guard for the subtle version of the bug: hold the limit but keep the low reading,
        // and the NEXT (network-bound) epoch looks like a huge improvement, so the climb sets off in
        // whatever direction it happened to be going.
        let mut g = Governor::new(32, 1, 256);
        g.observe(100.0, Pressure::Network, 0);
        g.observe(1.0, Pressure::ConsumerBound, 0);
        // Now a normal epoch: it must be treated as a fresh baseline, not compared against the 1.0.
        let l1 = g.limit();
        g.observe(100.0, Pressure::Network, 0);
        let moved = (g.limit() as f64 / l1 as f64).max(l1 as f64 / g.limit() as f64);
        assert!(moved <= STEP_UP + 0.01, "should move at most one probe step, went {l1} -> {}", g.limit());
    }

    #[test]
    fn respects_its_bounds() {
        let mut g = Governor::new(1, 1, 4);
        for _ in 0..50 {
            g.observe(simulate(1000, g.limit()), Pressure::Network, 0);
        }
        assert!(g.limit() <= 4, "must not exceed max");

        let mut g = Governor::new(4, 2, 8);
        for _ in 0..50 {
            g.observe(1.0, Pressure::Network, 9);
        }
        assert!(g.limit() >= 2, "must not fall below min");
    }
}
