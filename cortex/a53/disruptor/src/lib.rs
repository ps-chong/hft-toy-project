//! LMAX Disruptor ring for the A53 order-intent fan-out, in safe Rust.
//!
//! One [`Producer`] (the task that owns the RPMsg endpoint) publishes
//! 64-byte records. [`GatingConsumer`]s (the OUCH gateway) hold the producer
//! back until they have read a slot. [`LossyConsumer`]s (journal, analytics)
//! never slow the producer: they validate each copy against a per-slot stamp,
//! seqlock-style, and count what they lose.
//!
//! Slots are arrays of `AtomicU64`, so a producer rewriting a slot while a
//! lossy consumer copies it is a set of atomic word accesses rather than a
//! data race, and the crate needs no `unsafe`. Under `--cfg loom`, the
//! synchronous core is model-checked (see `tests/loom.rs`).

mod sync;
#[cfg(not(loom))]
mod wait;

use std::marker::PhantomData;

use thiserror::Error;

use crate::sync::{Arc, AtomicU64, Ordering, fence};
#[cfg(not(loom))]
pub use crate::wait::WaitStrategy;

/// Words per slot: one 64-byte IPC record.
pub const SLOT_WORDS: usize = 8;

/// Stamp value meaning "the producer is rewriting this slot".
const WRITING: u64 = u64::MAX;

/// A record that can travel through the ring as eight 64-bit words.
pub trait Slotted: Copy + Send + 'static {
    /// Packs the record into slot words.
    fn pack(&self) -> [u64; SLOT_WORDS];
    /// Rebuilds the record; `None` if the words are not a valid record.
    fn unpack(words: [u64; SLOT_WORDS]) -> Option<Self>;
}

impl Slotted for [u64; SLOT_WORDS] {
    fn pack(&self) -> [u64; SLOT_WORDS] {
        *self
    }

    fn unpack(words: [u64; SLOT_WORDS]) -> Option<Self> {
        Some(words)
    }
}

/// Invalid ring geometry.
#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum BuildError {
    /// Capacity must be a power of two of at least 2.
    #[error("capacity must be a power of two >= 2")]
    Capacity,
}

/// The producer would overwrite a slot a gating consumer has not read.
#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
#[error("ring is full")]
pub struct Full;

/// Keeps each hot atomic on its own cache line (no false sharing between
/// the producer cursor and consumer sequences).
#[repr(align(64))]
struct Padded<T>(T);

#[repr(align(64))]
struct Slot {
    words: [AtomicU64; SLOT_WORDS],
}

impl Slot {
    fn new() -> Self {
        Self {
            words: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }

    fn load(&self) -> [u64; SLOT_WORDS] {
        std::array::from_fn(|index| self.words[index].load(Ordering::Relaxed))
    }
}

struct Shared {
    slots: Box<[Slot]>,
    stamps: Box<[AtomicU64]>,
    mask: u64,
    capacity: u64,
    cursor: Padded<AtomicU64>,
    gating: Box<[Padded<AtomicU64>]>,
    #[cfg(not(loom))]
    signals: wait::Signals,
}

impl Shared {
    fn index(&self, sequence: u64) -> usize {
        usize::try_from(sequence & self.mask).unwrap_or_default()
    }

    /// Acquire: a consumer's slot reads happen before it advanced.
    fn slowest_gating(&self, fallback: u64) -> u64 {
        self.gating
            .iter()
            .map(|sequence| sequence.0.load(Ordering::Acquire))
            .min()
            .unwrap_or(fallback)
    }

    /// Acquire pairs with the producer's release store of the cursor.
    fn published(&self) -> u64 {
        self.cursor.0.load(Ordering::Acquire)
    }

    fn wake_consumers(&self) {
        #[cfg(not(loom))]
        self.signals.wake_data();
    }

    fn wake_producer(&self) {
        #[cfg(not(loom))]
        self.signals.wake_space();
    }
}

/// Creates a ring with `gating_consumers` gating consumers.
pub fn build<T: Slotted>(
    capacity: usize,
    gating_consumers: usize,
) -> Result<(Producer<T>, Vec<GatingConsumer<T>>), BuildError> {
    if capacity < 2 || !capacity.is_power_of_two() {
        return Err(BuildError::Capacity);
    }
    let capacity_u64 = u64::try_from(capacity).map_err(|_| BuildError::Capacity)?;
    let shared = Arc::new(Shared {
        slots: (0..capacity).map(|_| Slot::new()).collect(),
        // No sequence has been written yet, so every stamp says "writing".
        stamps: (0..capacity).map(|_| AtomicU64::new(WRITING)).collect(),
        mask: capacity_u64 - 1,
        capacity: capacity_u64,
        cursor: Padded(AtomicU64::new(0)),
        gating: (0..gating_consumers)
            .map(|_| Padded(AtomicU64::new(0)))
            .collect(),
        #[cfg(not(loom))]
        signals: wait::Signals::default(),
    });
    let consumers = (0..gating_consumers)
        .map(|index| GatingConsumer {
            shared: Arc::clone(&shared),
            index,
            next: 0,
            undecodable: 0,
            _record: PhantomData,
        })
        .collect();
    Ok((
        Producer {
            shared,
            next: 0,
            cached_slowest: 0,
            _record: PhantomData,
        },
        consumers,
    ))
}

/// The single writer. Not `Clone`: one producer per ring.
pub struct Producer<T> {
    shared: Arc<Shared>,
    next: u64,
    cached_slowest: u64,
    _record: PhantomData<fn(T)>,
}

impl<T: Slotted> Producer<T> {
    /// Publishes `value` unless a gating consumer still owns the target slot.
    pub fn try_publish(&mut self, value: &T) -> Result<u64, Full> {
        let shared = &*self.shared;
        let next = self.next;
        if next - self.cached_slowest >= shared.capacity {
            // Re-read the consumer positions only when the cached view says full.
            self.cached_slowest = shared.slowest_gating(next);
            if next - self.cached_slowest >= shared.capacity {
                return Err(Full);
            }
        }
        let index = shared.index(next);
        let stamp = &shared.stamps[index];
        // Seqlock writer protocol for lossy readers: mark the slot in flux,
        // fence so the mark is ordered before the data, write, then stamp.
        stamp.store(WRITING, Ordering::Relaxed);
        fence(Ordering::Release);
        for (word, value) in shared.slots[index].words.iter().zip(value.pack()) {
            word.store(value, Ordering::Relaxed);
        }
        stamp.store(next, Ordering::Release);
        // Release: gating consumers that acquire the cursor see the slot.
        shared.cursor.0.store(next + 1, Ordering::Release);
        self.next = next + 1;
        shared.wake_consumers();
        Ok(next)
    }

    /// Sequence the next publish will use.
    #[must_use]
    pub fn next_sequence(&self) -> u64 {
        self.next
    }

    /// A non-gating reader starting at the current cursor.
    #[must_use]
    pub fn lossy_consumer(&self) -> LossyConsumer<T> {
        LossyConsumer {
            shared: Arc::clone(&self.shared),
            next: self.next,
            dropped: 0,
            _record: PhantomData,
        }
    }

    /// Publishes `value`, waiting for space while gating consumers catch up.
    #[cfg(not(loom))]
    pub async fn publish(&mut self, value: &T, strategy: WaitStrategy) -> u64 {
        loop {
            if let Ok(sequence) = self.try_publish(value) {
                return sequence;
            }
            self.wait_for_space(strategy).await;
        }
    }

    /// Completes once the next publish would not overwrite an unread slot.
    /// Cancel-safe, so an owner can `select!` on it alongside other work.
    #[cfg(not(loom))]
    pub async fn wait_for_space(&self, strategy: WaitStrategy) {
        let shared = &*self.shared;
        let next = self.next;
        shared
            .signals
            .wait_for_space(strategy, || {
                next - shared.slowest_gating(next) < shared.capacity
            })
            .await;
    }
}

/// A consumer the producer waits for.
pub struct GatingConsumer<T> {
    shared: Arc<Shared>,
    index: usize,
    next: u64,
    undecodable: u64,
    _record: PhantomData<fn() -> T>,
}

impl<T: Slotted> GatingConsumer<T> {
    /// Published records not yet read by this consumer.
    #[must_use]
    pub fn available(&self) -> u64 {
        self.shared.published() - self.next
    }

    /// Delivers up to `max` records in order, then releases their slots to
    /// the producer with one store: the Disruptor batching effect.
    pub fn read_batch(&mut self, max: usize, mut deliver: impl FnMut(u64, T)) -> usize {
        let shared = &*self.shared;
        let count = self.available().min(u64::try_from(max).unwrap_or(u64::MAX));
        for sequence in self.next..self.next + count {
            match T::unpack(shared.slots[shared.index(sequence)].load()) {
                Some(value) => deliver(sequence, value),
                None => self.undecodable += 1,
            }
        }
        if count > 0 {
            self.next += count;
            // Release: our slot reads happen before the producer reuses them.
            shared.gating[self.index]
                .0
                .store(self.next, Ordering::Release);
            shared.wake_producer();
        }
        usize::try_from(count).unwrap_or(usize::MAX)
    }

    /// Records whose words did not unpack (should stay zero).
    #[must_use]
    pub fn undecodable(&self) -> u64 {
        self.undecodable
    }

    /// Completes once at least one record is available. Cancel-safe.
    #[cfg(not(loom))]
    pub async fn wait(&self, strategy: WaitStrategy) {
        let shared = &*self.shared;
        let next = self.next;
        shared
            .signals
            .wait_for_data(strategy, || shared.published() > next)
            .await;
    }
}

/// A consumer the producer never waits for.
pub struct LossyConsumer<T> {
    shared: Arc<Shared>,
    next: u64,
    dropped: u64,
    _record: PhantomData<fn() -> T>,
}

impl<T: Slotted> LossyConsumer<T> {
    /// Delivers up to `max` intact records; overwritten ones are counted.
    pub fn read_batch(&mut self, max: usize, mut deliver: impl FnMut(u64, T)) -> usize {
        let shared = &*self.shared;
        let cursor = shared.published();
        // The slot of `cursor` may be mid-rewrite, so at most capacity - 1
        // records behind the cursor are still readable.
        let window = shared.capacity - 1;
        if cursor - self.next > window {
            self.dropped += cursor - self.next - window;
            self.next = cursor - window;
        }
        let mut delivered = 0;
        while self.next < cursor && delivered < max {
            let sequence = self.next;
            let index = shared.index(sequence);
            let stamp = &shared.stamps[index];
            // Seqlock reader: stamp (acquire), data, fence, stamp again.
            let before = stamp.load(Ordering::Acquire);
            let words = shared.slots[index].load();
            fence(Ordering::Acquire);
            let after = stamp.load(Ordering::Relaxed);
            match (before == sequence && after == sequence).then(|| T::unpack(words)) {
                Some(Some(value)) => {
                    deliver(sequence, value);
                    delivered += 1;
                }
                _ => self.dropped += 1,
            }
            self.next += 1;
        }
        delivered
    }

    /// Records skipped because the producer lapped this consumer.
    #[must_use]
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Completes once the cursor has moved past this consumer. Cancel-safe.
    #[cfg(not(loom))]
    pub async fn wait(&self, strategy: WaitStrategy) {
        let shared = &*self.shared;
        let next = self.next;
        shared
            .signals
            .wait_for_data(strategy, || shared.published() > next)
            .await;
    }
}

#[cfg(all(test, not(loom)))]
mod tests {
    use super::*;

    fn record(value: u64) -> [u64; SLOT_WORDS] {
        [value; SLOT_WORDS]
    }

    #[test]
    fn rejects_bad_geometry() {
        assert_eq!(build::<[u64; 8]>(3, 1).err(), Some(BuildError::Capacity));
        assert_eq!(build::<[u64; 8]>(1, 1).err(), Some(BuildError::Capacity));
    }

    #[test]
    fn gating_consumer_back_pressures_the_producer() {
        let (mut producer, mut consumers) = build::<[u64; 8]>(4, 1).unwrap();
        let mut consumer = consumers.pop().unwrap();
        for value in 1..=4 {
            assert!(producer.try_publish(&record(value)).is_ok());
        }
        assert_eq!(producer.try_publish(&record(5)), Err(Full));

        let mut seen = Vec::new();
        assert_eq!(consumer.read_batch(2, |_, value| seen.push(value[0])), 2);
        assert_eq!(seen, [1, 2]);
        assert!(producer.try_publish(&record(5)).is_ok());
        assert_eq!(consumer.read_batch(8, |_, value| seen.push(value[0])), 3);
        assert_eq!(seen, [1, 2, 3, 4, 5]);
    }

    #[test]
    fn lossy_consumer_counts_what_it_missed() {
        let (mut producer, _) = build::<[u64; 8]>(4, 0).unwrap();
        let mut lossy = producer.lossy_consumer();
        for value in 1..=10 {
            assert!(producer.try_publish(&record(value)).is_ok());
        }
        let mut seen = Vec::new();
        assert_eq!(lossy.read_batch(16, |_, value| seen.push(value[0])), 3);
        assert_eq!(seen, [8, 9, 10]);
        assert_eq!(lossy.dropped(), 7);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 3)]
    async fn async_producer_and_consumers_hand_off_everything() {
        const TOTAL: u64 = 20_000;
        let (mut producer, mut consumers) = build::<[u64; 8]>(64, 1).unwrap();
        let consumer = consumers.pop().unwrap();
        let mut lossy = producer.lossy_consumer();
        let strategy = WaitStrategy::default();

        let writer = tokio::spawn(async move {
            for value in 1..=TOTAL {
                producer.publish(&record(value), strategy).await;
            }
        });
        let journal = tokio::spawn(async move {
            let mut intact = true;
            let mut delivered = 0;
            while delivered + lossy.dropped() < TOTAL {
                lossy.wait(strategy).await;
                delivered += u64::try_from(lossy.read_batch(64, |_, value| {
                    intact &= value.iter().all(|word| *word == value[0]);
                }))
                .unwrap_or_default();
            }
            intact
        });

        let mut consumer = consumer;
        let mut expected = 1;
        while expected <= TOTAL {
            consumer.wait(strategy).await;
            consumer.read_batch(64, |_, value| {
                assert_eq!(value, record(expected));
                expected += 1;
            });
        }
        writer.await.unwrap();
        assert!(journal.await.unwrap());
    }
}
