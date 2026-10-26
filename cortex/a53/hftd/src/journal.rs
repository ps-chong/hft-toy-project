//! Journal and analytics: the ring's lossy consumers.
//!
//! Neither task can slow trading. The journal reads every intent the ring
//! still holds, plus gateway lifecycle events from a bounded channel, and
//! writes batches to `PostgreSQL`. Analytics measures decision-to-receipt
//! latency. Losses are counted, never blocked on.

use std::{sync::Arc, time::Duration};

use hft_analytics::LatencyBook;
use hft_disruptor::{LossyConsumer, WaitStrategy};
use hft_storage::{OrderEventType, PersistedOrder, Repository, StorageError};
use tokio::{
    sync::mpsc,
    time::{MissedTickBehavior, interval, sleep},
};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use uuid::Uuid;

use crate::{
    counters::{Counter, Counters},
    record::RingIntent,
};

/// A lifecycle event reported by the gateway.
#[derive(Clone, Copy, Debug)]
pub struct JournalEvent {
    /// The intent concerned.
    pub record: RingIntent,
    /// What happened to it.
    pub event_type: OrderEventType,
}

/// Rows written per statement.
const BATCH: usize = 256;
/// Upper bound on how long a row waits for a batch to fill.
const FLUSH_INTERVAL: Duration = Duration::from_millis(100);
/// Attempts per batch before it is dropped and counted.
const ATTEMPTS: u32 = 3;

struct Journal<S> {
    repository: S,
    session_id: Uuid,
    counters: Arc<Counters>,
    pending: Vec<PersistedOrder>,
}

impl<S: Repository> Journal<S> {
    fn push(&mut self, record: RingIntent, event_type: OrderEventType) {
        self.pending.push(PersistedOrder {
            session_id: self.session_id,
            intent: record.intent,
            event_type,
        });
    }

    async fn flush(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let mut backoff = Duration::from_millis(50);
        for attempt in 1..=ATTEMPTS {
            match self.repository.store_orders(&self.pending).await {
                Ok(()) => {
                    self.pending.clear();
                    return;
                }
                Err(error) => {
                    warn!(%error, attempt, rows = self.pending.len(), "journal batch failed");
                    sleep(backoff).await;
                    backoff *= 2;
                }
            }
        }
        self.counters.add(
            Counter::JournalDropped,
            u64::try_from(self.pending.len()).unwrap_or(u64::MAX),
        );
        self.pending.clear();
    }
}

/// Runs until cancelled, then drains the event channel before returning.
pub async fn run_journal<S: Repository>(
    mut ring: LossyConsumer<RingIntent>,
    mut events: mpsc::Receiver<JournalEvent>,
    repository: S,
    session_id: Uuid,
    counters: Arc<Counters>,
    wait: WaitStrategy,
    cancellation: CancellationToken,
) -> Result<(), StorageError> {
    let mut journal = Journal {
        repository,
        session_id,
        counters: Arc::clone(&counters),
        pending: Vec::with_capacity(BATCH),
    };
    let mut flush = interval(FLUSH_INTERVAL);
    flush.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut received = Vec::with_capacity(BATCH);
    let mut ring_dropped = 0;

    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => break,
            () = ring.wait(wait) => {
                ring.read_batch(BATCH, |_, record| journal.push(record, OrderEventType::Received));
            }
            count = events.recv_many(&mut received, BATCH) => {
                if count == 0 {
                    break;
                }
                for event in received.drain(..) {
                    journal.push(event.record, event.event_type);
                }
            }
            _ = flush.tick() => journal.flush().await,
        }
        if journal.pending.len() >= BATCH {
            journal.flush().await;
        }
        let lapped = ring.dropped();
        counters.add(Counter::JournalDropped, lapped - ring_dropped);
        ring_dropped = lapped;
    }

    // Shutdown: keep what the gateway already reported instead of dropping
    // queued rows, then flush once.
    events.close();
    while let Some(event) = events.recv().await {
        journal.push(event.record, event.event_type);
    }
    journal.flush().await;
    Ok(())
}

/// Decision-to-receipt latency (R5 decision clock to A53 RPMsg receipt),
/// summarized and stored every `period`.
pub async fn run_analytics<S: Repository>(
    mut ring: LossyConsumer<RingIntent>,
    repository: S,
    session_id: Uuid,
    period: Duration,
    wait: WaitStrategy,
    cancellation: CancellationToken,
) -> Result<(), StorageError> {
    let Ok(mut book) = LatencyBook::new(60_000_000_000) else {
        return Ok(());
    };
    let mut report = interval(period);
    report.set_missed_tick_behavior(MissedTickBehavior::Delay);
    report.tick().await;
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => break,
            () = ring.wait(wait) => {
                ring.read_batch(BATCH, |_, record| {
                    book.record_tick_to_intent(record.received_ns.saturating_sub(record.intent.decision_timestamp_ns));
                });
            }
            _ = report.tick() => {
                let summary = book.tick_to_intent();
                if summary.samples > 0 {
                    info!(?summary, dropped = ring.dropped(), "decision-to-receipt latency");
                    repository.store_latency(session_id, "decision_to_receipt", summary).await?;
                }
            }
        }
    }
    Ok(())
}
