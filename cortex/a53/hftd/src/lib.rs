//! A53 trading daemon.
//!
//! Task topology (one owner per resource, Disruptor fan-out in the middle):
//!
//! ```text
//!   R5 --RPMsg--> rpmsg owner --publish--> [intent ring] --gating--> OUCH gateway --> exchange
//!                    ^                          |  lossy
//!                    | risk_config              +--> journal (PostgreSQL)
//!                    |                          +--> analytics
//!   hftctl --unix--> control server --> control actor --watch--> rpmsg owner, gateway
//! ```
//!
//! Tasks share only the ring, `watch` snapshots, bounded channels, and the
//! relaxed [`counters::Counters`]. A [`TaskTracker`] supervises them: the
//! first failure cancels the rest, and the daemon fails closed.

pub mod control;
pub mod counters;
pub mod gateway;
pub mod journal;
pub mod producer;
pub mod record;

use std::{path::PathBuf, sync::Arc, time::Duration};

use hft_disruptor::{BuildError, WaitStrategy};
use hft_ouch::{OuchError, OuchReader, OuchWriter};
use hft_protocol::control::{ControlSnapshot, DaemonCounters};
use hft_rpmsg::{RpmsgError, RpmsgTransport};
use hft_storage::{AnyRepository, StorageError};
use thiserror::Error;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    sync::{mpsc, watch},
};
use tokio_util::{sync::CancellationToken, task::TaskTracker};
use tracing::{error, info};
use uuid::Uuid;

use crate::{counters::Counters, gateway::GatewayConfig, record::RingIntent};

/// Errors that stop the daemon.
#[derive(Debug, Error)]
pub enum DaemonError {
    /// The R5 channel failed.
    #[error(transparent)]
    Rpmsg(#[from] RpmsgError),
    /// The exchange session failed.
    #[error(transparent)]
    Ouch(#[from] OuchError),
    /// The journal failed.
    #[error(transparent)]
    Storage(#[from] StorageError),
    /// The control socket failed.
    #[error("control plane failed: {0}")]
    Control(#[from] std::io::Error),
    /// The ring geometry is invalid.
    #[error(transparent)]
    Ring(#[from] BuildError),
}

/// Static daemon parameters.
#[derive(Clone, Debug)]
pub struct DaemonConfig {
    /// Identifies this run in the journal.
    pub session_id: Uuid,
    /// Intent ring slots (power of two).
    pub ring_capacity: usize,
    /// Spin-then-park policy for every ring wait.
    pub wait: WaitStrategy,
    /// Gateway timing.
    pub gateway: GatewayConfig,
    /// Control socket path.
    pub control_socket: PathBuf,
    /// Journal event queue depth.
    pub journal_queue: usize,
    /// Analytics reporting period.
    pub analytics_period: Duration,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            session_id: Uuid::nil(),
            ring_capacity: 1_024,
            wait: WaitStrategy::default(),
            gateway: GatewayConfig::default(),
            control_socket: PathBuf::from("/run/hftd/control.sock"),
            journal_queue: 1_024,
            analytics_period: Duration::from_secs(5),
        }
    }
}

/// Final statistics returned on a clean shutdown.
pub type DaemonReport = DaemonCounters;

/// Spawns tasks on a [`TaskTracker`]; the first failure is recorded and
/// cancels every other task, so the daemon fails closed as a unit.
struct Supervisor {
    tracker: TaskTracker,
    failures: mpsc::Sender<DaemonError>,
    cancellation: CancellationToken,
}

impl Supervisor {
    fn spawn<F, E>(&self, name: &'static str, task: F)
    where
        F: Future<Output = Result<(), E>> + Send + 'static,
        E: Into<DaemonError> + Send + 'static,
    {
        let failures = self.failures.clone();
        let cancellation = self.cancellation.clone();
        self.tracker.spawn(async move {
            if let Err(failure) = task.await {
                let failure = failure.into();
                error!(task = name, error = %failure, "task failed; shutting down");
                let _ = failures.try_send(failure);
                cancellation.cancel();
            }
        });
    }
}

/// Runs every daemon task until `cancellation` fires or one task fails.
pub async fn run<T, R, W>(
    config: DaemonConfig,
    rpmsg: T,
    exchange: (OuchReader<R>, OuchWriter<W>),
    repository: AnyRepository,
    cancellation: CancellationToken,
) -> Result<DaemonReport, DaemonError>
where
    T: RpmsgTransport + 'static,
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (producer, mut gating) = hft_disruptor::build::<RingIntent>(config.ring_capacity, 1)?;
    let gateway_consumer = gating.pop().ok_or(BuildError::Capacity)?;
    let journal_ring = producer.lossy_consumer();
    let analytics_ring = producer.lossy_consumer();

    let counters = Arc::new(Counters::default());
    let (control_tx, control_rx) = watch::channel(ControlSnapshot::default());
    let (request_tx, request_rx) = mpsc::channel(32);
    let (journal_tx, journal_rx) = mpsc::channel(config.journal_queue);
    let listener = control::bind_control_socket(&config.control_socket)?;

    let (failure_tx, mut failure_rx) = mpsc::channel::<DaemonError>(8);
    let supervisor = Supervisor {
        tracker: TaskTracker::new(),
        failures: failure_tx,
        cancellation: cancellation.clone(),
    };
    supervisor.tracker.spawn(control::run_control_actor(
        request_rx,
        control_tx,
        Arc::clone(&counters),
        cancellation.clone(),
    ));
    supervisor.spawn(
        "control-server",
        control::run_control_server(
            listener,
            config.control_socket.clone(),
            request_tx,
            cancellation.clone(),
        ),
    );
    supervisor.spawn(
        "rpmsg-owner",
        producer::run_rpmsg_owner(
            rpmsg,
            producer,
            control_rx.clone(),
            Arc::clone(&counters),
            config.wait,
            cancellation.clone(),
        ),
    );
    supervisor.spawn(
        "ouch-gateway",
        gateway::run_gateway(
            gateway_consumer,
            exchange.0,
            exchange.1,
            control_rx,
            journal_tx,
            Arc::clone(&counters),
            config.gateway,
            cancellation.clone(),
        ),
    );
    supervisor.spawn(
        "journal",
        journal::run_journal(
            journal_ring,
            journal_rx,
            repository.clone(),
            config.session_id,
            Arc::clone(&counters),
            config.wait,
            cancellation.clone(),
        ),
    );
    supervisor.spawn(
        "analytics",
        journal::run_analytics(
            analytics_ring,
            repository,
            config.session_id,
            config.analytics_period,
            config.wait,
            cancellation.clone(),
        ),
    );
    let Supervisor { tracker, .. } = supervisor;
    tracker.close();

    info!(session_id = %config.session_id, "hftd tasks running");
    cancellation.cancelled().await;
    tracker.wait().await;
    match failure_rx.try_recv() {
        Ok(failure) => Err(failure),
        Err(_) => Ok(counters.snapshot()),
    }
}
