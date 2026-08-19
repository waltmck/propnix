//! Ordered, byte-bounded read-ahead shared by both stores.
//!
//! A NAR is a single byte stream, so chunks must be EMITTED in tree order and the digest is inherently
//! sequential. But fetching them one at a time is latency-bound — a large title is tens of thousands of
//! requests — and these CDNs rate-limit PER CONNECTION (measured on Steam's: 9.2 Mbit/s over one
//! connection, 90.9 over sixteen, 114.4 over thirty-two). So workers race ahead and their results are
//! handed back strictly in order.
//!
//! The window caps only the bytes WAITING FOR THE EMITTER. An earlier version also counted bytes still
//! in flight, which let a backlog of completed chunks starve the workers down to one or two live
//! requests — and given per-connection limiting, that alone cost most of the achievable throughput.
//! Requests in flight are bounded by the thread count instead, so every worker stays busy until memory
//! genuinely fills. Peak resident content is therefore roughly `budget + workers * largest chunk`,
//! independent of the title's size.

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex};

pub struct Prefetcher<T: Send + Sync + 'static> {
    inner: Arc<Inner<T>>,
    _threads: Vec<std::thread::JoinHandle<()>>,
}

type Fetch<T> = Box<dyn Fn(&T) -> Result<Vec<u8>, String> + Send + Sync>;

struct Inner<T> {
    work: Vec<T>,
    fetch: Fetch<T>,
    state: Mutex<State>,
    cv: Condvar,
    budget: u64,
}

struct State {
    next: usize,
    emitted: usize,
    buffered_bytes: u64,
    done: BTreeMap<usize, Vec<u8>>,
    failure: Option<String>,
}

impl<T: Send + Sync + 'static> Prefetcher<T> {
    pub fn new(work: Vec<T>, workers: usize, budget: u64, fetch: Fetch<T>) -> Self {
        let inner = Arc::new(Inner {
            work,
            fetch,
            state: Mutex::new(State {
                next: 0,
                emitted: 0,
                buffered_bytes: 0,
                done: BTreeMap::new(),
                failure: None,
            }),
            cv: Condvar::new(),
            budget,
        });
        let threads = (0..workers.max(1))
            .map(|_| {
                let inner = Arc::clone(&inner);
                std::thread::spawn(move || inner.run())
            })
            .collect();
        Self {
            inner,
            _threads: threads,
        }
    }

    /// Take the next item's bytes, blocking until they arrive.
    pub fn next_chunk(&self) -> Result<Vec<u8>, String> {
        let mut st = self.inner.state.lock().unwrap();
        loop {
            if let Some(f) = &st.failure {
                return Err(f.clone());
            }
            let i = st.emitted;
            if let Some(v) = st.done.remove(&i) {
                st.emitted += 1;
                st.buffered_bytes = st.buffered_bytes.saturating_sub(v.len() as u64);
                self.inner.cv.notify_all();
                return Ok(v);
            }
            st = self.inner.cv.wait(st).unwrap();
        }
    }
}

impl<T: Send + Sync + 'static> Drop for Prefetcher<T> {
    fn drop(&mut self) {
        // Unblock any worker parked on the window so the threads can exit.
        let mut st = self.inner.state.lock().unwrap();
        st.failure.get_or_insert_with(|| "cancelled".to_string());
        self.inner.cv.notify_all();
    }
}

impl<T: Send + Sync + 'static> Inner<T> {
    fn run(self: Arc<Self>) {
        loop {
            let idx = {
                let mut st = self.state.lock().unwrap();
                loop {
                    if st.failure.is_some() || st.next >= self.work.len() {
                        return;
                    }
                    // Race ahead while the emit buffer has room. Always allow progress when the buffer
                    // is empty, so a single item larger than the whole budget cannot deadlock.
                    if st.buffered_bytes == 0 || st.buffered_bytes < self.budget {
                        let i = st.next;
                        st.next += 1;
                        break i;
                    }
                    st = self.cv.wait(st).unwrap();
                }
            };
            // A PANIC IN A WORKER IS A HANG, NOT A FAILURE, unless it is caught here: the thread dies
            // without ever setting `failure`, and `next_chunk` then waits on an index nobody will ever
            // produce — in CI that is silence until the 350-minute job cap. Convert it into the same
            // failure any other error takes.
            let fetched = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                (self.fetch)(&self.work[idx])
            }));
            match fetched {
                Ok(Ok(data)) => {
                    let mut st = self.state.lock().unwrap();
                    st.buffered_bytes += data.len() as u64;
                    st.done.insert(idx, data);
                    self.cv.notify_all();
                }
                Ok(Err(e)) => {
                    let mut st = self.state.lock().unwrap();
                    st.failure.get_or_insert(e);
                    self.cv.notify_all();
                    return;
                }
                Err(payload) => {
                    let mut st = self.state.lock().unwrap();
                    st.failure
                        .get_or_insert_with(|| format!("worker panicked: {}", panic_message(&payload)));
                    self.cv.notify_all();
                    return;
                }
            }
        }
    }
}

/// The best string we can recover from a panic payload — `panic!("…")` produces a `String`, the
/// `&'static str` form a `&str`, and anything else is opaque.
fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<String>() {
        return s.clone();
    }
    if let Some(s) = payload.downcast_ref::<&str>() {
        return (*s).to_string();
    }
    "<non-string panic payload>".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panicking_worker_surfaces_rather_than_hanging() {
        // The regression this guards: an unwinding fetch closure used to kill its thread WITHOUT
        // setting `failure`, so `next_chunk` blocked on an index that would never be produced.
        let pf = Prefetcher::new(
            vec![0u32, 1, 2],
            2,
            1 << 20,
            Box::new(|t: &u32| {
                if *t == 1 {
                    panic!("synthetic worker panic");
                }
                Ok(vec![0; 4])
            }),
        );
        let mut err = None;
        for _ in 0..3 {
            if let Err(e) = pf.next_chunk() {
                err = Some(e);
                break;
            }
        }
        let err = err.expect("a panicking worker must surface an error, not hang");
        assert!(err.contains("panicked"), "got: {err}");
        assert!(err.contains("synthetic worker panic"), "the payload should survive: {err}");
    }

    #[test]
    fn emits_strictly_in_order_despite_racing_workers() {
        // Reverse the natural completion order: item 0 is the slowest. If the prefetcher leaked
        // out-of-order results, this would fail.
        let work: Vec<u64> = (0..64).collect();
        let pf = Prefetcher::new(
            work,
            16,
            1 << 20,
            Box::new(|t: &u64| {
                std::thread::sleep(std::time::Duration::from_millis(64 - *t));
                Ok(t.to_le_bytes().to_vec())
            }),
        );
        for expect in 0u64..64 {
            let got = pf.next_chunk().unwrap();
            assert_eq!(u64::from_le_bytes(got.try_into().unwrap()), expect);
        }
    }

    #[test]
    fn a_failure_surfaces_rather_than_hanging() {
        let pf = Prefetcher::new(
            vec![0u32, 1, 2],
            4,
            1 << 20,
            Box::new(|t: &u32| {
                if *t == 1 {
                    Err("boom".into())
                } else {
                    Ok(vec![0; 4])
                }
            }),
        );
        // Item 0 may or may not arrive before the failure is observed; the point is that we get an
        // error rather than blocking forever.
        let mut saw_err = false;
        for _ in 0..3 {
            if pf.next_chunk().is_err() {
                saw_err = true;
                break;
            }
        }
        assert!(saw_err, "the failure must propagate to the emitter");
    }

    #[test]
    fn an_item_larger_than_the_budget_still_completes() {
        let pf = Prefetcher::new(
            vec![0u8, 1],
            2,
            8, // absurdly small budget
            Box::new(|_: &u8| Ok(vec![0u8; 4096])),
        );
        assert_eq!(pf.next_chunk().unwrap().len(), 4096);
        assert_eq!(pf.next_chunk().unwrap().len(), 4096);
    }
}
