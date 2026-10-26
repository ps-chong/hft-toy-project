//! Daemon counters shared by every task.
//!
//! Each counter has exactly one writing task; the control actor reads them
//! all to answer `status`. Relaxed atomics suffice: the values are
//! independent statistics, and no decision is ordered against them.

use std::sync::atomic::{AtomicU64, Ordering};

use hft_protocol::control::DaemonCounters;

/// Live counters. Shared through `Arc`, the one legitimate cross-task
/// ownership in the daemon.
#[derive(Debug, Default)]
pub struct Counters {
    intents_received: AtomicU64,
    intents_sent: AtomicU64,
    intents_blocked: AtomicU64,
    accepted: AtomicU64,
    rejected: AtomicU64,
    heartbeats_sent: AtomicU64,
    journal_dropped: AtomicU64,
    configs_sent: AtomicU64,
    intent_to_ack_p50_ns: AtomicU64,
    intent_to_ack_p99_ns: AtomicU64,
}

/// Which counter to bump.
#[derive(Clone, Copy, Debug)]
pub enum Counter {
    /// Read from the R5 (RPMsg owner).
    IntentsReceived,
    /// Sent to the exchange (gateway).
    IntentsSent,
    /// Withheld while trading is not permitted (gateway).
    IntentsBlocked,
    /// Exchange acceptance (gateway).
    Accepted,
    /// Exchange rejection (gateway).
    Rejected,
    /// Client heartbeat (gateway).
    HeartbeatsSent,
    /// Journal records lost (journal and gateway).
    JournalDropped,
    /// Configurations sent to the R5 (RPMsg owner).
    ConfigsSent,
}

impl Counters {
    fn cell(&self, counter: Counter) -> &AtomicU64 {
        match counter {
            Counter::IntentsReceived => &self.intents_received,
            Counter::IntentsSent => &self.intents_sent,
            Counter::IntentsBlocked => &self.intents_blocked,
            Counter::Accepted => &self.accepted,
            Counter::Rejected => &self.rejected,
            Counter::HeartbeatsSent => &self.heartbeats_sent,
            Counter::JournalDropped => &self.journal_dropped,
            Counter::ConfigsSent => &self.configs_sent,
        }
    }

    /// Adds `amount` to `counter`.
    pub fn add(&self, counter: Counter, amount: u64) {
        self.cell(counter).fetch_add(amount, Ordering::Relaxed);
    }

    /// Adds one to `counter`.
    pub fn bump(&self, counter: Counter) {
        self.add(counter, 1);
    }

    /// Publishes the gateway's latest round-trip percentiles.
    pub fn set_intent_to_ack(&self, p50_ns: u64, p99_ns: u64) {
        self.intent_to_ack_p50_ns.store(p50_ns, Ordering::Relaxed);
        self.intent_to_ack_p99_ns.store(p99_ns, Ordering::Relaxed);
    }

    /// Point-in-time copy for the control plane.
    #[must_use]
    pub fn snapshot(&self) -> DaemonCounters {
        let read = |cell: &AtomicU64| cell.load(Ordering::Relaxed);
        DaemonCounters {
            intents_received: read(&self.intents_received),
            intents_sent: read(&self.intents_sent),
            intents_blocked: read(&self.intents_blocked),
            accepted: read(&self.accepted),
            rejected: read(&self.rejected),
            heartbeats_sent: read(&self.heartbeats_sent),
            journal_dropped: read(&self.journal_dropped),
            configs_sent: read(&self.configs_sent),
            intent_to_ack_p50_ns: read(&self.intent_to_ack_p50_ns),
            intent_to_ack_p99_ns: read(&self.intent_to_ack_p99_ns),
        }
    }
}
