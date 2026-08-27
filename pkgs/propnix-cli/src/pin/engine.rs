//! The async chunk engine — one fetch pipeline, two sinks.
//!
//! Both stores' bulk transfers run through here: resolve a chunk's URL, GET it, decode it (decrypt,
//! decompress, verify), hand it to a sink. `propnix pin` sinks into a NAR hasher, `propnix download` sinks
//! into files. The store supplies only the three things that differ, via `ChunkIo`.
//!
//! ## Why async
//!
//! These CDNs rate-limit PER CONNECTION, so throughput is bought with concurrency (measured on Steam's:
//! 9.2 Mbit/s over one connection, 91 over sixteen, 169 over thirty-two spread across hosts). A blocking
//! transport needs one OS thread per in-flight request to get there, which caps how far the governor can
//! explore and makes every completion wake a crowd of parked threads. Tasks cost neither. The CPU-bound
//! half (decode), the disk half (writes) and `target()` — which may BLOCK on store metadata, see the trait
//! — go to `spawn_blocking`, so they can never stall the reactor.
//!
//! ## A QUEUE, not a per-request retry ladder
//!
//! A failed chunk goes BACK ON THE QUEUE rather than being retried inside its own task behind a sleep.
//! That matters for three reasons:
//!
//!   * A retrying task holds a concurrency slot while doing nothing, so a flaky host quietly shrinks the
//!     working set. A requeued block frees its slot immediately.
//!   * Requeueing re-runs `target()`, so the retry lands on whatever endpoint the host scorer now prefers
//!     — the previous design retried against the same URL, or rotated blindly.
//!   * Priority does the right thing for free: the queue is ordered by block index, so a failure of the
//!     block the emitter is waiting on is retried FIRST, ahead of speculative read-ahead.
//!
//! ## Liveness, not attempt counts
//!
//! A run fails when NOTHING has succeeded for `STALL_TIMEOUT`, not when some individual block has failed N
//! times. A multi-hour hash should survive an outage of any length as long as it is still making progress,
//! and should give up promptly when it is not — an attempt count answers neither question (it kills a
//! healthy run through one cursed block, and it lets a totally dead link limp along for its full ladder
//! times every block in flight).
//!
//! ## The window IS the queue
//!
//! A NAR is one byte stream, so the ordered hasher consumes strictly in order and read-ahead has to be
//! bounded or memory grows with the title. Rather than parking workers on a byte budget, the engine simply
//! does not ADMIT a block until it is within `budget` bytes of the earliest block the consumer still owes.
//! Admission is by bytes (every store knows each chunk's decompressed size up front), so the bound is
//! exact. Unordered mode keeps the same window with the SINK as the consumer: a chunk is still written the
//! moment it lands, so the window imposes no ordering there — it is purely the MEMORY bound. Without it,
//! in-flight bytes would be limited only by the governor's block count, and on a store with large chunks
//! (GOG's tail reaches ~17 MiB) a fast link could hold gigabytes of decoded blocks at the 128-worker
//! ceiling.

use std::collections::BinaryHeap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::pin::concurrency::{Governor, Pressure};

/// Per-request deadline covering DNS, connect, TLS and the whole body.
///
/// The point is that it covers ALL of them. A per-read timeout only bounds the wait for the next byte, so
/// a connection that trickles — or one left half-open when the machine changes network or resumes from
/// suspend — can hold a slot forever and never trip it. That stranded a 95%-complete depot twice.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// Give up only when NOTHING has succeeded for this long. See the module header.
const STALL_TIMEOUT: Duration = Duration::from_secs(600);
/// How often the governor re-reads throughput, and the watchdog checks for a stall.
const EPOCH: Duration = Duration::from_secs(2);
/// Where the concurrency climb starts.
const START_INFLIGHT: usize = 6;
/// Backoff before a requeued block becomes eligible again, so a dead endpoint is not hammered.
const REQUEUE_DELAY: Duration = Duration::from_millis(400);

/// The engine's timings, injectable so the tests can exercise minute-scale behaviour in milliseconds.
///
/// Production always uses `Default`; only tests set anything else. Timings and not policy: the queue
/// discipline, the governor and the failure rules are the same either way, so a test that passes here is
/// a test of the real engine.
#[derive(Clone, Copy)]
pub struct Tuning {
    pub request_timeout: Duration,
    pub stall_timeout: Duration,
    pub epoch: Duration,
    pub requeue_delay: Duration,
}

impl Default for Tuning {
    fn default() -> Self {
        Self {
            request_timeout: REQUEST_TIMEOUT,
            stall_timeout: STALL_TIMEOUT,
            epoch: EPOCH,
            requeue_delay: REQUEUE_DELAY,
        }
    }
}

/// Which endpoint to ask, and its index in the store's pool (so the outcome can be scored).
pub struct Target {
    pub url: String,
    pub endpoint: usize,
}

/// How a fetch went, for the store's host scorer.
pub enum Outcome {
    Ok { bytes: u64, elapsed: Duration },
    Failed,
}

/// Everything the engine needs from a store.
pub trait ChunkIo: Send + Sync + 'static {
    type Item: Send + Sync + Clone + 'static;

    /// Choose an endpoint and build the URL for this chunk. Called afresh on every attempt, which is what
    /// lets a requeued block move to a better-scoring endpoint.
    ///
    /// MAY BLOCK: GOG re-resolves an expired `secure_link` here, a full metadata round trip with its own
    /// retry policy. The engine therefore runs this on the blocking pool, like `decode` — never on the
    /// reactor.
    fn target(&self, item: &Self::Item) -> Result<Target, String>;

    /// Turn a response body into content bytes: decrypt, decompress, verify. CPU-bound, so the engine runs
    /// it on the blocking pool. An error here counts against the endpoint — a body that arrived and will
    /// not decode is a truncated or wrong object.
    fn decode(&self, item: &Self::Item, body: Vec<u8>) -> Result<Vec<u8>, String>;

    /// Score an endpoint by what it delivered.
    ///
    /// Takes the item because a store's endpoint indices need not be global: GOG resolves `secure_link`
    /// PER PRODUCT, so an index only means something alongside the chunk it was chosen for.
    fn observe(&self, item: &Self::Item, endpoint: usize, outcome: Outcome);

    /// Let the store react to a non-success status before the block is requeued (GOG drops a product's
    /// expired `secure_link` endpoints here so the retry re-resolves them).
    ///
    /// There is deliberately no way to say "fatal": EVERY failed status requeues, and a run ends only
    /// through the liveness rule. A status that cannot improve — a withdrawn manifest, say — therefore
    /// ends the run via the stall timeout with "no chunk has succeeded", which is both true and
    /// actionable; letting one bad cache node's 404 kill a multi-hour hash is the worse trade.
    fn on_http_status(&self, _item: &Self::Item, _status: u16) {}

    /// Human label for diagnostics. MUST NOT be a URL — chunk URLs carry signed parameters.
    ///
    /// (The engine also strips the URL out of transport errors before printing them: reqwest's `Display`
    /// embeds the URL it failed on, and a GOG `secure_link` puts its signature in PATH segments, so
    /// dropping the query string would not be enough.)
    fn label(&self, item: &Self::Item) -> String;
}

/// The work list: one entry per chunk, with the decompressed size admission accounting needs.
pub struct Work<T> {
    pub items: Vec<T>,
    pub sizes: Vec<u64>,
}

// ─────────────────────────────────────────── shared state ─────────────────────────────────────────
struct Shared<IO: ChunkIo> {
    io: Arc<IO>,
    items: Vec<IO::Item>,
    sizes: Vec<u64>,
    client: reqwest::Client,
    state: Mutex<State>,
    /// Wakes the ordered emitter (a BLOCKING consumer, hence a condvar rather than a Notify).
    emit_cv: Condvar,
    /// Wakes worker tasks when the queue or the concurrency limit changes.
    work_notify: tokio::sync::Notify,
    /// Admit no block until it is within this many bytes of the consumer — the ordered emitter's next
    /// need, or the unordered sink. The read-ahead bound for hashing; the memory bound for download.
    budget: u64,
    tuning: Tuning,
    epoch_bytes: AtomicU64,
    /// Requests that DELIVERED in this epoch. The governor needs it as the denominator: what a far end is
    /// telling us by failing is a RATE, and a public CDN's steady ~1% failure rate is not pushback.
    epoch_ok: AtomicU64,
    epoch_errors: AtomicU64,
    /// Content bytes handed to the sink, for the caller's progress line.
    delivered_bytes: AtomicU64,
    stop: AtomicBool,
}

struct State {
    /// Blocks ready to fetch, lowest index first: the emitter's next need outranks read-ahead.
    queue: BinaryHeap<std::cmp::Reverse<usize>>,
    /// Highest index admitted so far (ordered mode's sliding window edge).
    admitted: usize,
    /// How many are being fetched right now, and the ceiling the governor sets.
    in_flight: usize,
    limit: usize,
    /// Completed-but-not-yet-emitted results, by index (ordered mode).
    done: std::collections::BTreeMap<usize, Vec<u8>>,
    /// Bytes of `done` plus in-flight admitted blocks — what the budget bounds.
    outstanding: u64,
    /// Next index the ordered emitter wants.
    emitted: usize,
    /// How many blocks have been delivered to the sink (unordered mode's completion test).
    delivered: usize,
    failure: Option<String>,
    last_success: Instant,
}

impl<IO: ChunkIo> Shared<IO> {
    fn fail(&self, msg: String) {
        let mut st = self.state.lock().unwrap();
        st.failure.get_or_insert(msg);
        self.stop.store(true, Ordering::Relaxed);
        self.emit_cv.notify_all();
        self.work_notify.notify_waiters();
    }

    /// Admit blocks up to the window edge.
    fn admit(&self, st: &mut State) {
        while st.admitted < self.items.len() {
            // Always admit at least one, so a single block larger than the whole budget cannot deadlock.
            if st.outstanding > 0 && st.outstanding + self.sizes[st.admitted] > self.budget {
                break;
            }
            st.outstanding += self.sizes[st.admitted];
            st.queue.push(std::cmp::Reverse(st.admitted));
            st.admitted += 1;
        }
    }
}

/// A handle the BLOCKING NAR hasher pulls from, in strict order.
pub struct Ordered<IO: ChunkIo> {
    shared: Arc<Shared<IO>>,
    _rt: tokio::runtime::Runtime,
}

impl<IO: ChunkIo> Ordered<IO> {
    /// Take the next chunk's bytes, blocking until they arrive.
    pub fn next_chunk(&self) -> Result<Vec<u8>, String> {
        let mut st = self.shared.state.lock().unwrap();
        loop {
            if let Some(f) = &st.failure {
                return Err(f.clone());
            }
            let i = st.emitted;
            if let Some(v) = st.done.remove(&i) {
                st.emitted += 1;
                st.outstanding = st.outstanding.saturating_sub(v.len() as u64);
                // Emitting freed window space: slide it forward.
                self.shared.admit(&mut st);
                self.shared.work_notify.notify_waiters();
                return Ok(v);
            }
            st = self.shared.emit_cv.wait(st).unwrap();
        }
    }
}

impl<IO: ChunkIo> Drop for Ordered<IO> {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.shared.work_notify.notify_waiters();
    }
}

/// Where completed chunks go in unordered mode. Called from the blocking pool, possibly concurrently.
pub trait Sink: Send + Sync + 'static {
    fn accept(&self, index: usize, data: Vec<u8>) -> Result<(), String>;
}

fn client(tuning: &Tuning) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        // The deadline that matters — see REQUEST_TIMEOUT.
        .timeout(tuning.request_timeout)
        .connect_timeout(Duration::from_secs(20))
        // Chunk requests hammer a handful of hosts; keep their connections rather than reopening.
        .pool_max_idle_per_host(256)
        .build()
        .map_err(|e| format!("http client: {e}"))
}

fn runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("propnix-chunk")
        .build()
        .map_err(|e| format!("tokio runtime: {e}"))
}

fn new_shared<IO: ChunkIo>(
    io: Arc<IO>,
    work: Work<IO::Item>,
    max: usize,
    budget: u64,
    tuning: Tuning,
) -> Result<Arc<Shared<IO>>, String> {
    if work.items.len() != work.sizes.len() {
        return Err("engine: work items and sizes disagree".into());
    }
    let shared = Arc::new(Shared {
        io,
        items: work.items,
        sizes: work.sizes,
        client: client(&tuning)?,
        state: Mutex::new(State {
            queue: BinaryHeap::new(),
            admitted: 0,
            in_flight: 0,
            limit: START_INFLIGHT.min(max.max(1)),
            done: std::collections::BTreeMap::new(),
            outstanding: 0,
            emitted: 0,
            delivered: 0,
            failure: None,
            last_success: Instant::now(),
        }),
        emit_cv: Condvar::new(),
        work_notify: tokio::sync::Notify::new(),
        budget: budget.max(1),
        tuning,
        epoch_bytes: AtomicU64::new(0),
        epoch_ok: AtomicU64::new(0),
        epoch_errors: AtomicU64::new(0),
        delivered_bytes: AtomicU64::new(0),
        stop: AtomicBool::new(false),
    });
    {
        let mut st = shared.state.lock().unwrap();
        shared.admit(&mut st);
    }
    Ok(shared)
}

/// Fetch one block. Returns `Ok(None)` when the block was requeued and should be forgotten by the caller.
async fn fetch_one<IO: ChunkIo>(shared: &Arc<Shared<IO>>, idx: usize) -> Option<Vec<u8>> {
    let item = shared.items[idx].clone();
    // Resolution may BLOCK (see the trait), so it runs on the blocking pool: a store stuck re-resolving
    // metadata must never occupy the reactor threads that drive every other in-flight chunk — and the
    // timers (request deadlines, requeue delays, governor epochs) that only fire when the reactor runs.
    let target = {
        let io = Arc::clone(&shared.io);
        let it = item.clone();
        match tokio::task::spawn_blocking(move || io.target(&it)).await {
            Ok(Ok(t)) => t,
            Ok(Err(e)) => {
                // Cannot even name a URL — that is a resolution problem, not a flaky socket. Requeue: for
                // GOG this is exactly the expired-signature path, which recovers once the link is
                // re-resolved.
                requeue(shared, idx, &format!("{}: {e}", shared.io.label(&item)));
                return None;
            }
            Err(join) => {
                // A panic in target() is a BUG, like a panic in decode: end the run with the reason.
                shared.fail(format!("{}: target task died: {join}", shared.io.label(&item)));
                return None;
            }
        }
    };
    let started = Instant::now();
    let resp = shared.client.get(&target.url).send().await;
    let body = match resp {
        Ok(r) => {
            let status = r.status().as_u16();
            if !r.status().is_success() {
                shared.io.observe(&item, target.endpoint, Outcome::Failed);
                shared.io.on_http_status(&item, status);
                requeue(shared, idx, &format!("{}: HTTP {status}", shared.io.label(&item)));
                return None;
            }
            match r.bytes().await {
                Ok(b) => b.to_vec(),
                Err(e) => {
                    shared.io.observe(&item, target.endpoint, Outcome::Failed);
                    let e = e.without_url();
                    requeue(shared, idx, &format!("{}: {e}", shared.io.label(&item)));
                    return None;
                }
            }
        }
        Err(e) => {
            shared.io.observe(&item, target.endpoint, Outcome::Failed);
            let e = e.without_url();
            requeue(shared, idx, &format!("{}: {e}", shared.io.label(&item)));
            return None;
        }
    };
    // Time the TRANSFER only: decode costs the same whoever served the bytes, so folding it in would
    // score endpoints by this machine's CPU.
    shared.io.observe(
        &item,
        target.endpoint,
        Outcome::Ok {
            bytes: body.len() as u64,
            elapsed: started.elapsed(),
        },
    );

    // CPU-bound: off the reactor.
    let io = Arc::clone(&shared.io);
    let it = item.clone();
    let decoded = tokio::task::spawn_blocking(move || io.decode(&it, body)).await;
    match decoded {
        Ok(Ok(data)) => {
            // Counted HERE, not at transfer time, so a request is ok XOR error. Decode IS the integrity
            // check (hash mismatch, decrypt/inflate failure), so a chunk that arrives and then fails to
            // decode is a FAILURE — counting it as both dilutes the governor's error rate to f/(1+f) and a
            // link throwing away a third of its transfers would read as 0.23 and keep climbing. It also
            // kept the two halves of one request in different epochs, since the decode lands after
            // `spawn_blocking`.
            shared.epoch_ok.fetch_add(1, Ordering::Relaxed);
            Some(data)
        }
        Ok(Err(e)) => {
            // A body that will not decode is this endpoint's fault too.
            shared.io.observe(&item, target.endpoint, Outcome::Failed);
            requeue(shared, idx, &format!("{}: {e}", shared.io.label(&item)));
            None
        }
        Err(join) => {
            // A panic in decode is a BUG. Do not requeue it forever — end the run with the reason.
            shared.fail(format!("{}: decode task died: {join}", shared.io.label(&item)));
            None
        }
    }
}

/// Requeue a failed block. Returns immediately — the worker frees its concurrency slot as soon as its
/// `fetch_one` unwinds, so a failing block never idles a slot. The block becomes ELIGIBLE again only after
/// a short pause (a detached timer re-queues it), so a flapping endpoint is not hammered; it keeps its
/// index priority, so if the emitter is waiting on it, it is still the next thing tried once the pause
/// ends.
fn requeue<IO: ChunkIo>(shared: &Arc<Shared<IO>>, idx: usize, why: &str) {
    shared.epoch_errors.fetch_add(1, Ordering::Relaxed);
    eprintln!("\n  {why} — requeued");
    let shared = Arc::clone(shared);
    tokio::spawn(async move {
        tokio::time::sleep(shared.tuning.requeue_delay).await;
        let mut st = shared.state.lock().unwrap();
        st.queue.push(std::cmp::Reverse(idx));
        drop(st);
        shared.work_notify.notify_waiters();
    });
}

/// One worker task: take the highest-priority admissible block, fetch it, deliver it, repeat.
async fn worker<IO: ChunkIo>(shared: Arc<Shared<IO>>, sink: Option<Arc<dyn Sink>>) {
    loop {
        if shared.stop.load(Ordering::Relaxed) {
            return;
        }
        // Register interest in a wakeup BEFORE looking at the state. `notify_waiters()` does not wake a
        // `Notified` that has never been polled, so the obvious check-then-await loses any notification
        // that lands in between — and a worker that misses one parks until the next unrelated wakeup, or
        // forever if it was the last. `enable()` is tokio's hook for exactly this.
        let wakeup = shared.work_notify.notified();
        let mut wakeup = std::pin::pin!(wakeup);
        wakeup.as_mut().enable();

        let idx = {
            let mut st = shared.state.lock().unwrap();
            if st.failure.is_some() {
                return;
            }
            // Every block fetched and handed on — buffered for the ordered emitter, or written by the
            // sink. Nothing is left for a worker to do; the ordered emitter drains its buffer alone.
            if st.delivered >= shared.items.len() {
                return;
            }
            // Respect the governor. `in_flight == 0` is the anti-deadlock escape: the limit can never
            // stop the pipeline entirely.
            if st.in_flight > 0 && st.in_flight >= st.limit {
                None
            } else {
                st.queue.pop().map(|std::cmp::Reverse(i)| {
                    st.in_flight += 1;
                    i
                })
            }
        };
        let Some(idx) = idx else {
            // Nothing admissible right now: either the window is closed or every block is in flight.
            wakeup.await;
            continue;
        };

        let got = fetch_one(&shared, idx).await;

        match got {
            Some(data) => {
                let n = data.len() as u64;
                shared.epoch_bytes.fetch_add(n, Ordering::Relaxed);
                match &sink {
                    // Unordered: hand it straight to the sink, on the blocking pool (it writes to disk).
                    Some(s) => {
                        let s = Arc::clone(s);
                        let res = tokio::task::spawn_blocking(move || s.accept(idx, data)).await;
                        let mut st = shared.state.lock().unwrap();
                        st.in_flight -= 1;
                        match res {
                            Ok(Ok(())) => {
                                st.delivered += 1;
                                st.last_success = Instant::now();
                                // Writing freed window space: slide it forward.
                                st.outstanding = st.outstanding.saturating_sub(n);
                                shared.admit(&mut st);
                                shared.delivered_bytes.fetch_add(n, Ordering::Relaxed);
                            }
                            Ok(Err(e)) => {
                                // A write failure is not the network's fault and will not fix itself.
                                st.failure.get_or_insert(e);
                                shared.stop.store(true, Ordering::Relaxed);
                            }
                            Err(join) => {
                                st.failure.get_or_insert(format!("write task died: {join}"));
                                shared.stop.store(true, Ordering::Relaxed);
                            }
                        }
                        drop(st);
                        shared.work_notify.notify_waiters();
                    }
                    // Ordered: buffer for the emitter.
                    None => {
                        let mut st = shared.state.lock().unwrap();
                        st.in_flight -= 1;
                        st.done.insert(idx, data);
                        st.delivered += 1;
                        st.last_success = Instant::now();
                        drop(st);
                        shared.emit_cv.notify_all();
                        shared.work_notify.notify_waiters();
                    }
                }
            }
            None => {
                let mut st = shared.state.lock().unwrap();
                st.in_flight -= 1;
                drop(st);
                shared.work_notify.notify_waiters();
            }
        }
    }
}

/// Adjust concurrency from measured throughput, and fail the run if nothing succeeds for STALL_TIMEOUT.
async fn govern<IO: ChunkIo>(shared: Arc<Shared<IO>>, max: usize) {
    // FLOOR of 4, not 1. Backoff is multiplicative, so whatever drives it — a genuine struggling link, a
    // burst of failures, or a bug in the error signal — the limit heads for the floor, and a floor of 1
    // means the whole remaining transfer runs over a single socket at the CDN's per-connection cap. Four
    // is not an abusive number of connections to hold against a CDN even when it is genuinely unhappy,
    // and it keeps the pipeline able to measure that more concurrency helps.
    let mut gov = Governor::new(START_INFLIGHT.min(max), 4.min(max), max);
    let mut last = Instant::now();
    loop {
        tokio::time::sleep(shared.tuning.epoch).await;
        if shared.stop.load(Ordering::Relaxed) {
            return;
        }
        let elapsed = last.elapsed().as_secs_f64();
        last = Instant::now();
        let bytes = shared.epoch_bytes.swap(0, Ordering::Relaxed);
        let ok = shared.epoch_ok.swap(0, Ordering::Relaxed);
        let errors = shared.epoch_errors.swap(0, Ordering::Relaxed);

        let (limit_now, stalled_for, complete) = {
            let st = shared.state.lock().unwrap();
            let complete = st.delivered >= shared.items.len();
            (st.limit, st.last_success.elapsed(), complete || st.failure.is_some())
        };
        if complete {
            return;
        }
        if stalled_for > shared.tuning.stall_timeout {
            shared.fail(format!(
                "no chunk has succeeded in {}s — giving up (the link looks down, not slow)",
                stalled_for.as_secs()
            ));
            return;
        }

        // A full window means the CONSUMER is the pace-setter — the NAR hasher in ordered mode, the byte
        // window itself in unordered mode — so the epoch's throughput is not a network reading and the
        // limit must hold rather than climb into (or flee from) its own tail.
        let pressure = {
            let st = shared.state.lock().unwrap();
            if st.outstanding >= shared.budget && st.queue.is_empty() {
                Pressure::ConsumerBound
            } else {
                Pressure::Network
            }
        };
        let throughput = if elapsed > 0.0 { bytes as f64 / elapsed } else { 0.0 };
        let limit = gov.observe(throughput, pressure, ok, errors);
        if std::env::var_os("PROPNIX_PIN_DEBUG").is_some() {
            eprintln!(
                "\n  [pin] inflight {limit_now} -> {limit}  {:.1} MB/s  {}{}",
                throughput / 1e6,
                if pressure == Pressure::ConsumerBound { "consumer-bound" } else { "network" },
                if errors > 0 { format!("  errors={errors}/{}", ok + errors) } else { String::new() },
            );
        }
        if limit != limit_now {
            shared.state.lock().unwrap().limit = limit;
            shared.work_notify.notify_waiters();
        }
    }
}

fn spawn_all<IO: ChunkIo>(
    rt: &tokio::runtime::Runtime,
    shared: &Arc<Shared<IO>>,
    max: usize,
    sink: Option<Arc<dyn Sink>>,
) {
    // Tasks, not threads: `max` of them costs nothing even when the governor settles far below it.
    for _ in 0..max {
        let s = Arc::clone(shared);
        let k = sink.clone();
        rt.spawn(async move { worker(s, k).await });
    }
    let s = Arc::clone(shared);
    rt.spawn(async move { govern(s, max).await });
}

/// Ordered delivery, for the NAR hasher: `budget` bytes of read-ahead, strict emission order.
pub fn ordered<IO: ChunkIo>(
    io: Arc<IO>,
    work: Work<IO::Item>,
    max: usize,
    budget: u64,
    tuning: Tuning,
) -> Result<Ordered<IO>, String> {
    let max = max.max(1);
    let shared = new_shared(io, work, max, budget, tuning)?;
    let rt = runtime()?;
    spawn_all(&rt, &shared, max, None);
    Ok(Ordered { shared, _rt: rt })
}

/// Unordered delivery, for download: a block is written the moment it lands, in whatever order the CDN
/// answers; `budget` bounds the bytes admitted ahead of the sink — the run's memory, not its ordering.
pub fn unordered<IO: ChunkIo>(
    io: Arc<IO>,
    work: Work<IO::Item>,
    max: usize,
    budget: u64,
    sink: Arc<dyn Sink>,
    tuning: Tuning,
    mut on_progress: impl FnMut(u64),
) -> Result<(), String> {
    let max = max.max(1);
    let total = work.items.len();
    let shared = new_shared(io, work, max, budget, tuning)?;
    let rt = runtime()?;
    spawn_all(&rt, &shared, max, Some(sink));

    // Block the caller until every chunk has landed, reporting bytes as they go.
    let mut reported_bytes = 0u64;
    loop {
        let (delivered, failure) = {
            let st = shared.state.lock().unwrap();
            (st.delivered, st.failure.clone())
        };
        let bytes = shared.delivered_bytes.load(Ordering::Relaxed);
        if bytes > reported_bytes {
            on_progress(bytes - reported_bytes);
            reported_bytes = bytes;
        }
        if let Some(f) = failure {
            shared.stop.store(true, Ordering::Relaxed);
            return Err(f);
        }
        if delivered >= total {
            shared.stop.store(true, Ordering::Relaxed);
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::AtomicUsize;

    /// What the fake CDN should do with a request.
    enum Reply {
        Body(Vec<u8>),
        Status(u16),
        /// Close without answering — what a dropped connection looks like.
        Hangup,
    }

    /// A minimal loopback HTTP/1.1 server, so the tests drive the ENGINE'S REAL PATH — reqwest, the
    /// timeout, the requeue — rather than a mock of it. Deterministic and a few milliseconds per case.
    fn serve(handler: impl Fn(&str) -> Reply + Send + Sync + 'static) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let handler = Arc::new(handler);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let handler = Arc::clone(&handler);
                std::thread::spawn(move || {
                    let path = {
                        let mut r = BufReader::new(&mut stream);
                        let mut line = String::new();
                        if r.read_line(&mut line).is_err() {
                            return;
                        }
                        // Drain headers.
                        loop {
                            let mut h = String::new();
                            match r.read_line(&mut h) {
                                Ok(0) => break,
                                Ok(_) if h == "\r\n" => break,
                                Ok(_) => {}
                                Err(_) => return,
                            }
                        }
                        line.split_whitespace().nth(1).unwrap_or("/").to_string()
                    };
                    match handler(&path) {
                        Reply::Hangup => {
                            let _ = stream.shutdown(std::net::Shutdown::Both);
                        }
                        Reply::Status(code) => {
                            let _ = write!(
                                stream,
                                "HTTP/1.1 {code} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            );
                        }
                        Reply::Body(b) => {
                            let _ = write!(
                                stream,
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                b.len()
                            );
                            let _ = stream.write_all(&b);
                        }
                    }
                    let _ = stream.flush();
                });
            }
        });
        // Wait for the port to accept before handing it out.
        for _ in 0..100 {
            if TcpStream::connect(base.trim_start_matches("http://")).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        base
    }

    /// Block `i` is `i` repeated `LEN` times, so a mis-ordered or mis-decoded result is obvious.
    const LEN: usize = 64;
    fn body(i: usize) -> Vec<u8> {
        vec![i as u8; LEN]
    }

    struct TestIo {
        base: String,
        /// Every endpoint index the engine scored, so the host-scoring wiring is observable.
        scored: Mutex<Vec<(usize, bool)>>,
        /// Highest block index the server was ever asked for.
        peak_requested: Arc<AtomicUsize>,
    }

    impl ChunkIo for TestIo {
        type Item = usize;
        fn target(&self, item: &usize) -> Result<Target, String> {
            self.peak_requested.fetch_max(*item, Ordering::Relaxed);
            Ok(Target {
                url: format!("{}/block/{item}", self.base),
                endpoint: item % 3,
            })
        }
        fn decode(&self, item: &usize, b: Vec<u8>) -> Result<Vec<u8>, String> {
            if b != body(*item) {
                return Err(format!("block {item}: body mismatch"));
            }
            Ok(b)
        }
        fn observe(&self, _item: &usize, endpoint: usize, outcome: Outcome) {
            self.scored
                .lock()
                .unwrap()
                .push((endpoint, matches!(outcome, Outcome::Ok { .. })));
        }
        fn label(&self, item: &usize) -> String {
            format!("block {item}")
        }
    }

    fn io_for(base: String) -> (Arc<TestIo>, Arc<AtomicUsize>) {
        let peak = Arc::new(AtomicUsize::new(0));
        (
            Arc::new(TestIo {
                base,
                scored: Mutex::new(Vec::new()),
                peak_requested: Arc::clone(&peak),
            }),
            peak,
        )
    }

    fn work(n: usize) -> Work<usize> {
        Work {
            items: (0..n).collect(),
            sizes: vec![LEN as u64; n],
        }
    }

    fn fast() -> Tuning {
        Tuning {
            request_timeout: Duration::from_secs(5),
            stall_timeout: Duration::from_millis(600),
            epoch: Duration::from_millis(40),
            requeue_delay: Duration::from_millis(5),
        }
    }

    fn idx_of(path: &str) -> usize {
        path.rsplit('/').next().unwrap().parse().unwrap()
    }

    #[test]
    fn ordered_mode_emits_every_block_in_order() {
        // Answer late blocks FASTER than early ones, so anything that leaked completion order would
        // emit out of order and fail here.
        let base = serve(|p| {
            let i = idx_of(p);
            std::thread::sleep(Duration::from_millis((40 - (i as u64).min(40)) * 2));
            Reply::Body(body(i))
        });
        let (io, _) = io_for(base);
        let o = ordered(io, work(40), 8, (LEN * 4) as u64, fast()).unwrap();
        for i in 0..40 {
            assert_eq!(o.next_chunk().unwrap(), body(i), "block {i} out of order");
        }
    }

    #[test]
    fn a_failing_block_is_requeued_until_it_succeeds() {
        // The point of the queue: block 7 fails twice — with a 500 and then a dropped connection — and
        // the run still completes, because a failure returns the block to the queue instead of killing
        // the task or the run.
        let tries = Arc::new(AtomicUsize::new(0));
        let t = Arc::clone(&tries);
        let base = serve(move |p| {
            let i = idx_of(p);
            if i == 7 {
                return match t.fetch_add(1, Ordering::Relaxed) {
                    0 => Reply::Status(500),
                    1 => Reply::Hangup,
                    _ => Reply::Body(body(i)),
                };
            }
            Reply::Body(body(i))
        });
        let (io, _) = io_for(base);
        let o = ordered(io, work(12), 4, (LEN * 4) as u64, fast()).unwrap();
        for i in 0..12 {
            assert_eq!(o.next_chunk().unwrap(), body(i), "block {i}");
        }
        assert!(tries.load(Ordering::Relaxed) >= 3, "block 7 should have been retried");
    }

    #[test]
    fn ordered_read_ahead_stays_inside_the_window() {
        // The window IS the queue: with room for 4 blocks, the engine must not fetch the 100th while
        // the emitter is still on the first. Nothing is consumed here, so the edge cannot advance.
        let base = serve(|p| Reply::Body(body(idx_of(p))));
        let (io, peak) = io_for(base);
        let o = ordered(io, work(200), 32, (LEN * 4) as u64, fast()).unwrap();
        // Take one block, then let read-ahead run.
        assert_eq!(o.next_chunk().unwrap(), body(0));
        std::thread::sleep(Duration::from_millis(300));
        let p = peak.load(Ordering::Relaxed);
        assert!(p < 40, "read-ahead escaped the window: reached block {p} of 200");
    }

    #[test]
    fn unordered_mode_delivers_every_block_exactly_once() {
        let base = serve(|p| Reply::Body(body(idx_of(p))));
        let (io, _) = io_for(base);
        struct Collect(Mutex<Vec<(usize, Vec<u8>)>>);
        impl Sink for Collect {
            fn accept(&self, index: usize, data: Vec<u8>) -> Result<(), String> {
                self.0.lock().unwrap().push((index, data));
                Ok(())
            }
        }
        let sink = Arc::new(Collect(Mutex::new(Vec::new())));
        let mut bytes = 0u64;
        unordered(io, work(50), 16, (LEN * 64) as u64, Arc::clone(&sink) as Arc<dyn Sink>, fast(), |n| {
            bytes += n
        })
        .unwrap();
        let got = sink.0.lock().unwrap();
        assert_eq!(got.len(), 50, "every block must arrive");
        assert_eq!(
            got.iter().map(|(i, _)| *i).collect::<BTreeSet<_>>().len(),
            50,
            "and exactly once"
        );
        for (i, d) in got.iter() {
            assert_eq!(d, &body(*i), "block {i} content");
        }
        assert_eq!(bytes, (50 * LEN) as u64, "progress must account for every byte");
    }

    #[test]
    fn unordered_mode_delivers_every_block_exactly_once_through_failures() {
        // THE case the other two tests miss between them: the requeue path tested in UNORDERED mode.
        // `a_failing_block_is_requeued_until_it_succeeds` drives ordered mode, and
        // `unordered_mode_delivers_every_block_exactly_once` drives a server that never fails — so the
        // combination that a lossy link actually produces was untested. It matters here more than in
        // ordered mode: the ordered emitter would notice a hole (it blocks forever waiting for the
        // block), whereas the unordered sink writes at offsets and a block that silently never arrives
        // just leaves the file's initial zeros behind. Same size, same file count, wrong bytes.
        //
        // Every third block fails its first two attempts, one of them by dropping the connection.
        let tries = Arc::new(Mutex::new(std::collections::HashMap::<usize, usize>::new()));
        let t = Arc::clone(&tries);
        let base = serve(move |p| {
            let i = idx_of(p);
            if i % 3 == 0 {
                let mut m = t.lock().unwrap();
                let n = m.entry(i).or_insert(0);
                *n += 1;
                return match *n {
                    1 => Reply::Status(502),
                    2 => Reply::Hangup,
                    _ => Reply::Body(body(i)),
                };
            }
            Reply::Body(body(i))
        });
        let (io, _) = io_for(base);
        struct Collect(Mutex<Vec<(usize, Vec<u8>)>>);
        impl Sink for Collect {
            fn accept(&self, index: usize, data: Vec<u8>) -> Result<(), String> {
                self.0.lock().unwrap().push((index, data));
                Ok(())
            }
        }
        let sink = Arc::new(Collect(Mutex::new(Vec::new())));
        let mut bytes = 0u64;
        let n = 60usize;
        unordered(
            io,
            work(n),
            8,
            (LEN * 4) as u64,
            Arc::clone(&sink) as Arc<dyn Sink>,
            fast(),
            |b| bytes += b,
        )
        .unwrap();
        let got = sink.0.lock().unwrap();
        let seen: BTreeSet<usize> = got.iter().map(|(i, _)| *i).collect();
        let missing: Vec<usize> = (0..n).filter(|i| !seen.contains(i)).collect();
        assert!(
            missing.is_empty(),
            "blocks never written (their bytes would be silent zeros on disk): {missing:?}"
        );
        assert_eq!(got.len(), n, "and none written twice");
        for (i, d) in got.iter() {
            assert_eq!(d, &body(*i), "block {i} content");
        }
        assert_eq!(bytes, (n * LEN) as u64, "progress must account for every byte");
    }

    #[test]
    fn a_dead_link_fails_on_stall_rather_than_hanging() {
        // Liveness, not attempt counts: nothing ever succeeds, so the run must end by itself — and say
        // why — rather than requeueing forever.
        let base = serve(|_| Reply::Status(503));
        let (io, _) = io_for(base);
        let o = ordered(io, work(8), 4, (LEN * 4) as u64, fast()).unwrap();
        let err = o.next_chunk().expect_err("a dead link must surface an error");
        assert!(err.contains("no chunk has succeeded"), "got: {err}");
    }

    #[test]
    fn a_write_failure_ends_the_run_rather_than_retrying_forever() {
        // A failing sink is not the network's fault and will not fix itself, so it must not be requeued.
        let base = serve(|p| Reply::Body(body(idx_of(p))));
        let (io, _) = io_for(base);
        struct Boom;
        impl Sink for Boom {
            fn accept(&self, _i: usize, _d: Vec<u8>) -> Result<(), String> {
                Err("disk is full".into())
            }
        }
        let err = unordered(io, work(8), 4, (LEN * 8) as u64, Arc::new(Boom) as Arc<dyn Sink>, fast(), |_| {})
            .expect_err("a write failure must end the run");
        assert!(err.contains("disk is full"), "got: {err}");
    }

    #[test]
    fn unordered_admission_respects_the_byte_window() {
        // The window is unordered mode's MEMORY bound. With room for two blocks and a slow sink, the
        // engine must never be holding more than a couple of blocks beyond what has been written —
        // however many workers the governor would allow.
        let base = serve(|p| Reply::Body(body(idx_of(p))));
        let (io, _) = io_for(base);
        struct SlowSink {
            accepted: AtomicUsize,
            violations: AtomicUsize,
        }
        impl Sink for SlowSink {
            fn accept(&self, index: usize, _d: Vec<u8>) -> Result<(), String> {
                // Admission is sequential by index, so a block being written can run at most
                // (window blocks + the always-admit-one grace) ahead of the blocks already written.
                if index > self.accepted.load(Ordering::Relaxed) + 4 {
                    self.violations.fetch_add(1, Ordering::Relaxed);
                }
                std::thread::sleep(Duration::from_millis(5)); // back-pressure keeps the window full
                self.accepted.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
        }
        let sink = Arc::new(SlowSink {
            accepted: AtomicUsize::new(0),
            violations: AtomicUsize::new(0),
        });
        unordered(io, work(30), 16, (LEN * 2) as u64, Arc::clone(&sink) as Arc<dyn Sink>, fast(), |_| {})
            .unwrap();
        assert_eq!(sink.accepted.load(Ordering::Relaxed), 30, "every block must still arrive");
        assert_eq!(
            sink.violations.load(Ordering::Relaxed),
            0,
            "admission escaped the byte window"
        );
    }

    #[test]
    fn endpoint_outcomes_are_reported_for_scoring() {
        // The engine must feed the host scorer both successes and failures, or the weights never move.
        let base = serve(|p| {
            let i = idx_of(p);
            if i == 2 {
                Reply::Status(500)
            } else {
                Reply::Body(body(i))
            }
        });
        let (io, _) = io_for(base);
        let o = ordered(Arc::clone(&io), work(6), 3, (LEN * 6) as u64, fast()).unwrap();
        // Block 2 keeps failing, so give up after the stall rather than looping.
        let _ = o.next_chunk();
        let _ = o.next_chunk();
        let _ = o.next_chunk();
        drop(o);
        let scored = io.scored.lock().unwrap();
        assert!(scored.iter().any(|(_, ok)| *ok), "successes must be scored");
        assert!(scored.iter().any(|(_, ok)| !*ok), "failures must be scored");
    }
}
