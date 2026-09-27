//! Single-owner Tokio actors coordinating `RPMsg`, OUCH, and persistence.

pub mod control;

use async_trait::async_trait;
use hft_ouch::{OuchError, OuchSession, OuchTransport};
use hft_protocol::OrderIntent;
use hft_rpmsg::{RpmsgError, RpmsgTransport};
use hft_storage::{PersistedOrder, Repository, StorageError};
use thiserror::Error;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum DaemonError {
    #[error(transparent)]
    Rpmsg(#[from] RpmsgError),
    #[error(transparent)]
    Ouch(#[from] OuchError),
}

#[async_trait]
pub trait OrderGateway: Send {
    async fn send(&mut self, intent: &OrderIntent) -> Result<(), OuchError>;
}

#[async_trait]
impl<T: OuchTransport> OrderGateway for OuchSession<T> {
    async fn send(&mut self, intent: &OrderIntent) -> Result<(), OuchError> {
        self.send_intent(intent).await
    }
}

#[derive(Clone, Debug)]
pub enum StorageCommand {
    Order(PersistedOrder),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct DaemonStats {
    pub intents_received: u64,
    pub intents_sent: u64,
    pub analytics_dropped: u64,
}

pub struct Daemon<R, G> {
    rpmsg: R,
    gateway: G,
    storage: mpsc::Sender<StorageCommand>,
    cancellation: CancellationToken,
    session_id: Uuid,
    stats: DaemonStats,
}

impl<R: RpmsgTransport, G: OrderGateway> Daemon<R, G> {
    #[must_use]
    pub fn new(
        rpmsg: R,
        gateway: G,
        storage: mpsc::Sender<StorageCommand>,
        cancellation: CancellationToken,
        session_id: Uuid,
    ) -> Self {
        Self {
            rpmsg,
            gateway,
            storage,
            cancellation,
            session_id,
            stats: DaemonStats::default(),
        }
    }

    pub async fn run(mut self) -> Result<DaemonStats, DaemonError> {
        info!(session_id = %self.session_id, "hftd actor started");
        loop {
            tokio::select! {
                biased;
                () = self.cancellation.cancelled() => {
                    info!("hftd cancellation requested");
                    return Ok(self.stats);
                }
                intent = self.rpmsg.receive_intent() => {
                    let intent = intent?;
                    self.stats.intents_received =
                        self.stats.intents_received.saturating_add(1);
                    self.gateway.send(&intent).await?;
                    self.stats.intents_sent = self.stats.intents_sent.saturating_add(1);

                    let command = StorageCommand::Order(PersistedOrder {
                        session_id: self.session_id,
                        intent,
                        event_type: "sent".to_owned(),
                    });
                    if self.storage.try_send(command).is_err() {
                        self.stats.analytics_dropped =
                            self.stats.analytics_dropped.saturating_add(1);
                        warn!("storage queue saturated; noncritical record dropped");
                    }
                }
            }
            tokio::task::yield_now().await;
        }
    }
}

pub async fn run_storage_actor(
    mut receiver: mpsc::Receiver<StorageCommand>,
    repository: Box<dyn Repository>,
    cancellation: CancellationToken,
) -> Result<(), StorageError> {
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => return Ok(()),
            command = receiver.recv() => {
                let Some(command) = command else {
                    return Ok(());
                };
                match command {
                    StorageCommand::Order(order) => {
                        if let Err(storage_error) = repository.store_order(&order).await {
                            error!(error = %storage_error, "order persistence failed");
                            return Err(storage_error);
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use hft_protocol::{OrderAction, Side};
    use mockall::mock;

    use super::*;

    mock! {
        pub Rpmsg {}

        #[async_trait]
        impl RpmsgTransport for Rpmsg {
            async fn receive_intent(&mut self) -> Result<OrderIntent, RpmsgError>;
            async fn send_event(
                &mut self,
                event: &hft_protocol::MarketEvent,
            ) -> Result<(), RpmsgError>;
        }
    }

    mock! {
        pub Gateway {}

        #[async_trait]
        impl OrderGateway for Gateway {
            async fn send(&mut self, intent: &OrderIntent) -> Result<(), OuchError>;
        }
    }

    #[tokio::test]
    async fn forwards_intent_and_never_waits_for_storage() {
        let cancellation = CancellationToken::new();
        let mut rpmsg = MockRpmsg::new();
        rpmsg.expect_receive_intent().once().returning(|| {
            Ok(OrderIntent {
                action: OrderAction::Enter,
                side: Side::Buy,
                user_ref: 7,
                ..OrderIntent::default()
            })
        });
        let mut gateway = MockGateway::new();
        gateway
            .expect_send()
            .withf(|intent| intent.user_ref == 7)
            .once()
            .returning({
                let cancellation = cancellation.clone();
                move |_| {
                    cancellation.cancel();
                    Ok(())
                }
            });

        let (storage_tx, mut storage_rx) = mpsc::channel(1);
        let daemon = Daemon::new(
            rpmsg,
            gateway,
            storage_tx,
            cancellation.clone(),
            Uuid::nil(),
        );
        let task = tokio::spawn(daemon.run());
        let stored = storage_rx.recv().await;
        assert!(matches!(stored, Some(StorageCommand::Order(_))));
        let result = task.await;
        assert!(result.is_ok());
        let result = result.unwrap_or_else(|error| panic!("{error}"));
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn drops_analytics_when_bounded_queue_is_full() {
        let cancellation = CancellationToken::new();
        let mut rpmsg = MockRpmsg::new();
        rpmsg.expect_receive_intent().once().returning(|| {
            Ok(OrderIntent {
                action: OrderAction::Enter,
                side: Side::Buy,
                user_ref: 8,
                ..OrderIntent::default()
            })
        });
        let mut gateway = MockGateway::new();
        gateway.expect_send().once().returning({
            let cancellation = cancellation.clone();
            move |_| {
                cancellation.cancel();
                Ok(())
            }
        });

        let (storage_tx, _storage_rx) = mpsc::channel(1);
        storage_tx
            .try_send(StorageCommand::Order(PersistedOrder {
                session_id: Uuid::nil(),
                intent: OrderIntent::default(),
                event_type: "seed".to_owned(),
            }))
            .unwrap_or_else(|error| panic!("{error}"));
        let daemon = Daemon::new(
            rpmsg,
            gateway,
            storage_tx,
            cancellation.clone(),
            Uuid::nil(),
        );
        let task = tokio::spawn(daemon.run());
        let stats = task
            .await
            .unwrap_or_else(|error| panic!("{error}"))
            .unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(stats.analytics_dropped, 1);
    }
}
