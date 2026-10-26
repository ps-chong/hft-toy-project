//! The RPMsg owner: the Disruptor producer and the only writer to the R5.
//!
//! This task owns the RPMsg endpoint outright. It reads approved intents
//! from the R5 into the ring and forwards every control change to the R5 as
//! a `risk_config` record. Every `select!` branch is cancel-safe. A full
//! ring parks one pending intent and pauses RPMsg reads, but never pauses
//! control updates, so `kill` reaches the R5 even while the gateway stalls.

use std::sync::Arc;

use hft_disruptor::{Producer, WaitStrategy};
use hft_protocol::control::ControlSnapshot;
use hft_rpmsg::RpmsgTransport;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use tracing::debug;

use crate::{
    DaemonError,
    counters::{Counter, Counters},
    record::{RingIntent, monotonic_ns},
};

/// Runs until cancelled or the channel fails.
pub async fn run_rpmsg_owner<T: RpmsgTransport>(
    mut endpoint: T,
    mut producer: Producer<RingIntent>,
    mut control: watch::Receiver<ControlSnapshot>,
    counters: Arc<Counters>,
    strategy: WaitStrategy,
    cancellation: CancellationToken,
) -> Result<(), DaemonError> {
    // The R5 boots fail-closed; tell it the operator's current state at once.
    let initial = *control.borrow_and_update();
    endpoint.send_config(&initial.to_record()).await?;
    counters.bump(Counter::ConfigsSent);

    let mut pending: Option<RingIntent> = None;
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => return Ok(()),
            changed = control.changed() => {
                if changed.is_err() {
                    return Ok(());
                }
                let snapshot = *control.borrow_and_update();
                endpoint.send_config(&snapshot.to_record()).await?;
                counters.bump(Counter::ConfigsSent);
                debug!(revision = snapshot.revision, "risk_config sent to R5");
            }
            () = producer.wait_for_space(strategy), if pending.is_some() => {
                if let Some(record) = pending.take() {
                    pending = producer.try_publish(&record).err().map(|_| record);
                }
            }
            intent = endpoint.receive_intent(), if pending.is_none() => {
                let record = RingIntent { intent: intent?, received_ns: monotonic_ns() };
                counters.bump(Counter::IntentsReceived);
                if producer.try_publish(&record).is_err() {
                    pending = Some(record);
                }
            }
        }
    }
}
