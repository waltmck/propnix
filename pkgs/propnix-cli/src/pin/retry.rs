//! Surviving a transient network outage in the middle of a hash.
//!
//! A streaming re-pin is a LONG-RUNNING, STRICTLY ORDERED download: hundreds of GB for a big title, tens
//! of thousands of chunk requests, and an emitter that consumes them in NAR order and can never go back.
//! Over that many hours the network WILL blink — a laptop moving between access points, a CI runner's NAT
//! recycling, a CDN dropping a pooled connection. Every one of those surfaces the same way: an in-flight
//! read ends early (ureq reports `response body closed before all bytes were read`) or a fresh connection
//! is refused. None of that is a reason to throw away an hour of hashing.
//!
//! COUNT ATTEMPTS, NEVER A WALL-CLOCK DEADLINE. "Keep trying for ten minutes" is the obvious spelling and
//! the wrong one: a laptop that suspends mid-hash comes back to find the deadline already spent, so the
//! very first request after resume — the one that was always going to fail, because the link is still
//! coming up — is also the last. Counting attempts makes the policy mean what it says: N chances, spaced
//! out, however much time the machine spent not running. (`thread::sleep` is CLOCK_MONOTONIC on Linux,
//! which does not advance across suspend either, so a sleep resumes rather than expiring.)
//!
//! What is NOT retried: anything the server answered deliberately. A 401/403 is an ownership decision, a
//! 404 is a withdrawn manifest, a parse failure means the bytes arrived and made no sense — retrying
//! those would only turn a clear error into a slow one. Each call site says which of its errors are
//! transient.

use std::time::Duration;

pub struct Policy {
    /// Total attempts INCLUDING the first, so `1` means "do not retry".
    pub attempts: u32,
    /// Wait after the first failure; doubles each time, capped at `max_interval`.
    pub first_interval: Duration,
    pub max_interval: Duration,
}

impl Policy {
    /// The wait after failure number `n` (1-based).
    fn interval(&self, n: u32) -> Duration {
        let doublings = n.saturating_sub(1).min(32);
        let scaled = self
            .first_interval
            .saturating_mul(1u32.checked_shl(doublings).unwrap_or(u32::MAX));
        scaled.min(self.max_interval)
    }

    /// Roughly how long a full run of retries spends waiting — for the doc comments, and for a human
    /// deciding whether these numbers are the right ones.
    #[cfg(test)]
    fn total_wait(&self) -> Duration {
        (1..self.attempts).map(|n| self.interval(n)).sum()
    }
}

/// Bulk content (chunks). Worth outlasting a real outage: the alternative is discarding every byte
/// hashed so far and starting the whole title again. 13 retries, ~4.8 minutes of actual waiting.
pub const CONTENT: Policy = Policy {
    attempts: 14,
    first_interval: Duration::from_secs(1),
    max_interval: Duration::from_secs(32),
};

/// Metadata (build lists, manifests, appinfo, the content-server directory). Retried too — a blink
/// during the planning phase should not fail the run — but fewer chances, because nothing expensive has
/// happened yet and failing fast is cheap. 7 retries, ~1.6 minutes.
pub const METADATA: Policy = Policy {
    attempts: 8,
    first_interval: Duration::from_secs(1),
    max_interval: Duration::from_secs(32),
};

/// Run `op`, retrying while `retryable` says the failure was transport and attempts remain.
///
/// `what` is used only for the stderr notice; it should name the thing being fetched, not the URL — chunk
/// URLs carry signed parameters (see `gog::redact_chunk`).
pub fn with_retry<T, E: std::fmt::Display>(
    what: &str,
    policy: &Policy,
    retryable: impl Fn(&E) -> bool,
    mut op: impl FnMut() -> Result<T, E>,
) -> Result<T, E> {
    let mut failures = 0u32;
    loop {
        match op() {
            Ok(v) => {
                if failures > 0 {
                    eprintln!(
                        "  {what}: recovered after {failures} retr{}",
                        if failures == 1 { "y" } else { "ies" }
                    );
                }
                return Ok(v);
            }
            Err(e) => {
                failures += 1;
                if !retryable(&e) || failures >= policy.attempts {
                    return Err(e);
                }
                let wait = policy.interval(failures);
                eprintln!(
                    "  {what}: {e} — retrying in {}s ({failures}/{} attempts used)",
                    wait.as_secs(),
                    policy.attempts
                );
                std::thread::sleep(wait);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    /// Zero-wait, so the tests never sleep.
    const FAST: Policy = Policy {
        attempts: 4,
        first_interval: Duration::ZERO,
        max_interval: Duration::ZERO,
    };

    #[test]
    fn a_transient_failure_is_survived() {
        let n = Cell::new(0);
        let got: Result<u32, String> = with_retry("chunk", &FAST, |_| true, || {
            n.set(n.get() + 1);
            if n.get() < 3 {
                Err("response body closed before all bytes were read".to_string())
            } else {
                Ok(7)
            }
        });
        assert_eq!(got.unwrap(), 7);
        assert_eq!(n.get(), 3, "it must actually have retried, not succeeded first time");
    }

    #[test]
    fn a_deliberate_refusal_is_not_retried() {
        // Retrying a 403 would turn a clear ownership answer into a slow one.
        let n = Cell::new(0);
        let got: Result<u32, String> = with_retry("chunk", &FAST, |e: &String| !e.contains("403"), || {
            n.set(n.get() + 1);
            Err("HTTP 403".to_string())
        });
        assert!(got.is_err());
        assert_eq!(n.get(), 1, "a non-retryable error must be returned on the first try");
    }

    #[test]
    fn the_attempt_count_is_the_only_stopping_rule() {
        // No wall-clock deadline anywhere: a laptop asleep between attempts must not lose its chances.
        let n = Cell::new(0);
        let got: Result<u32, String> = with_retry("chunk", &FAST, |_| true, || {
            n.set(n.get() + 1);
            Err("connection reset".to_string())
        });
        assert!(got.is_err());
        assert_eq!(n.get(), FAST.attempts as usize);

        // attempts = 1 means "do not retry at all".
        let once = Policy { attempts: 1, ..FAST };
        let n = Cell::new(0);
        let _: Result<u32, String> = with_retry("chunk", &once, |_| true, || {
            n.set(n.get() + 1);
            Err("connection reset".to_string())
        });
        assert_eq!(n.get(), 1);
    }

    #[test]
    fn intervals_are_exponential_and_capped() {
        assert_eq!(CONTENT.interval(1), Duration::from_secs(1));
        assert_eq!(CONTENT.interval(2), Duration::from_secs(2));
        assert_eq!(CONTENT.interval(6), Duration::from_secs(32));
        assert_eq!(CONTENT.interval(13), Duration::from_secs(32), "capped, never unbounded");
        // …and no shift or multiply can overflow, however large the attempt number.
        assert_eq!(CONTENT.interval(u32::MAX), Duration::from_secs(32));

        // The numbers the doc comments quote, so they cannot drift apart from the constants.
        assert_eq!(CONTENT.total_wait(), Duration::from_secs(287)); // ~4.8 min
        assert_eq!(METADATA.total_wait(), Duration::from_secs(95)); // ~1.5 min
    }
}
