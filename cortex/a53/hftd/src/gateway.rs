//! The OUCH gateway: the ring's gating consumer and the only exchange writer.
//!
//! Each intent is checked against the latest control snapshot at the moment
//! it is sent. That is defence in depth: the R5 applies the same kill, but an
//! intent already in flight when the operator kills must still be withheld.
//! The task also keeps the `SoupBinTCP` session alive: client heartbeats when
//! idle, and a deadline on server silence.

use std::{collections::HashMap, sync::Arc, time::Duration};

use hft_analytics::LatencyBook;
use hft_disruptor::{GatingConsumer, WaitStrategy};
use hft_ouch::{OuchError, OuchEvent, OuchReader, OuchWriter};
use hft_protocol::control::ControlSnapshot;
use hft_storage::OrderEventType;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{mpsc, watch},
    time::{Instant, MissedTickBehavior, interval, sleep_until},
};
use tokio_util::sync::CancellationToken;
use tracing::warn;

use crate::{
    DaemonError,
    counters::{Counter, Counters},
    journal::JournalEvent,
    record::RingIntent,
};

/// Timing for the session.
#[derive(Clone, Copy, Debug)]
pub struct GatewayConfig {
    /// Send a client heartbeat after this much idle time.
    pub heartbeat_interval: Duration,
    /// Fail if the server is silent for this long.
    pub server_timeout: Duration,
    /// Ring wait strategy.
    pub wait: WaitStrategy,
    /// Most intents forwarded per wake-up.
    pub batch: usize,
}

impl Default for GatewayConfig {
    fn default() -> Self {
        Self {
            heartbeat_interval: Duration::from_secs(1),
            server_timeout: Duration::from_secs(15),
            wait: WaitStrategy::default(),
            batch: 64,
        }
    }
}

/// Bound on remembered send times; acks for older orders are not timed.
const MAX_IN_FLIGHT: usize = 4_096;

struct Gateway<W> {
    writer: OuchWriter<W>,
    journal: mpsc::Sender<JournalEvent>,
    counters: Arc<Counters>,
    sent_at: HashMap<u32, Instant>,
    latency: Option<LatencyBook>,
    last_send: Instant,
}

impl<W: AsyncWrite + Unpin + Send> Gateway<W> {
    fn journal(&self, record: RingIntent, event_type: OrderEventType) {
        // Noncritical: a full journal queue costs a counted record, never latency.
        if self
            .journal
            .try_send(JournalEvent { record, event_type })
            .is_err()
        {
            self.counters.bump(Counter::JournalDropped);
        }
    }

    async fn forward(
        &mut self,
        record: RingIntent,
        snapshot: &ControlSnapshot,
    ) -> Result<(), OuchError> {
        if !snapshot.trading_permitted() {
            self.counters.bump(Counter::IntentsBlocked);
            self.journal(record, OrderEventType::Blocked);
            return Ok(());
        }
        self.writer.send_intent(&record.intent).await?;
        let now = Instant::now();
        self.last_send = now;
        if self.sent_at.len() >= MAX_IN_FLIGHT {
            self.sent_at.clear();
        }
        self.sent_at.insert(record.intent.user_ref, now);
        self.counters.bump(Counter::IntentsSent);
        self.journal(record, OrderEventType::Sent);
        Ok(())
    }

    fn on_event(&mut self, event: OuchEvent) {
        let (user_ref, event_type) = match event {
            OuchEvent::Accepted { user_ref } => {
                self.counters.bump(Counter::Accepted);
                if let (Some(sent), Some(book)) =
                    (self.sent_at.remove(&user_ref), self.latency.as_mut())
                {
                    let elapsed = u64::try_from(sent.elapsed().as_nanos()).unwrap_or(u64::MAX);
                    book.record_intent_to_ack(elapsed);
                    let summary = book.intent_to_ack();
                    self.counters
                        .set_intent_to_ack(summary.p50_ns, summary.p99_ns);
                }
                (user_ref, OrderEventType::Accepted)
            }
            OuchEvent::Rejected { user_ref } => {
                self.counters.bump(Counter::Rejected);
                (user_ref.unwrap_or_default(), OrderEventType::Rejected)
            }
            OuchEvent::Executed { user_ref } => (user_ref, OrderEventType::Executed),
            OuchEvent::Canceled { user_ref } => (user_ref, OrderEventType::Canceled),
            OuchEvent::Heartbeat | OuchEvent::Replaced { .. } | OuchEvent::Other { .. } => return,
        };
        let mut record = RingIntent {
            intent: hft_protocol::OrderIntent::default(),
            received_ns: 0,
        };
        record.intent.user_ref = user_ref;
        self.journal(record, event_type);
    }
}

/// Runs until cancelled or the session fails.
#[allow(
    clippy::too_many_arguments,
    reason = "each argument is one owned resource"
)]
pub async fn run_gateway<R, W>(
    mut consumer: GatingConsumer<RingIntent>,
    mut reader: OuchReader<R>,
    writer: OuchWriter<W>,
    control: watch::Receiver<ControlSnapshot>,
    journal: mpsc::Sender<JournalEvent>,
    counters: Arc<Counters>,
    config: GatewayConfig,
    cancellation: CancellationToken,
) -> Result<(), DaemonError>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let mut gateway = Gateway {
        writer,
        journal,
        counters,
        sent_at: HashMap::new(),
        latency: LatencyBook::new(10_000_000_000).ok(),
        last_send: Instant::now(),
    };
    let mut heartbeat = interval(config.heartbeat_interval);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let silence = sleep_until(Instant::now() + config.server_timeout);
    tokio::pin!(silence);
    let mut batch = Vec::with_capacity(config.batch);

    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => {
                if let Err(error) = gateway.writer.logout().await {
                    warn!(%error, "logout failed during shutdown");
                }
                return Ok(());
            }
            () = consumer.wait(config.wait) => {
                // One snapshot per batch: a kill arriving mid-batch applies
                // from the next batch, at most `batch` intents later.
                let snapshot = *control.borrow();
                consumer.read_batch(config.batch, |_, record| batch.push(record));
                for record in batch.drain(..) {
                    gateway.forward(record, &snapshot).await?;
                }
            }
            event = reader.next_event() => {
                silence.as_mut().reset(Instant::now() + config.server_timeout);
                gateway.on_event(event?);
            }
            _ = heartbeat.tick() => {
                if gateway.last_send.elapsed() >= config.heartbeat_interval {
                    gateway.writer.heartbeat().await?;
                    gateway.last_send = Instant::now();
                    gateway.counters.bump(Counter::HeartbeatsSent);
                }
            }
            () = &mut silence => return Err(OuchError::HeartbeatLost.into()),
        }
    }
}
