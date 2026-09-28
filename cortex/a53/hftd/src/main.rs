use std::{env, net::SocketAddr, path::PathBuf};

use anyhow::{Context, Result};
use hft_ouch::{OuchSession, SessionConfig, TcpOuchTransport};
use hft_rpmsg::FileRpmsg;
use hft_storage::{NullRepository, PgRepository, Repository};
use hftd::{
    Daemon,
    control::{ControlSnapshot, run_control_server},
    run_storage_actor,
};
use tokio::sync::{mpsc, watch};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use uuid::Uuid;

fn init_tracing() -> Result<()> {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("hftd=info"));
    if let Ok(journal) = tracing_journald::layer() {
        tracing_subscriber::registry()
            .with(filter)
            .with(journal)
            .try_init()
            .map_err(|error| anyhow::anyhow!("install journald subscriber: {error}"))?;
    } else {
        tracing_subscriber::fmt()
            .with_env_filter(filter)
            .try_init()
            .map_err(|error| anyhow::anyhow!("install fallback subscriber: {error}"))?;
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing()?;
    let rpmsg_path =
        PathBuf::from(env::var_os("HFT_RPMSG_DEVICE").unwrap_or_else(|| "/dev/rpmsg0".into()));
    let ouch_address: SocketAddr = env::var("HFT_OUCH_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:9001".to_owned())
        .parse()
        .context("parse HFT_OUCH_ADDR")?;

    let rpmsg = FileRpmsg::open(&rpmsg_path)
        .await
        .with_context(|| format!("open RPMsg endpoint {}", rpmsg_path.display()))?;
    let transport = TcpOuchTransport::connect(ouch_address)
        .await
        .with_context(|| format!("connect OUCH simulator {ouch_address}"))?;
    let mut gateway = OuchSession::new(transport, SessionConfig::default());
    gateway.login().await.context("authenticate SoupBinTCP")?;

    let repository: Box<dyn Repository> = if let Ok(url) = env::var("DATABASE_URL") {
        Box::new(
            PgRepository::connect(&url, 2)
                .await
                .context("connect PostgreSQL")?,
        )
    } else {
        warn!("DATABASE_URL is unset; analytics persistence is disabled");
        Box::new(NullRepository)
    };

    let cancellation = CancellationToken::new();
    let signal_cancellation = cancellation.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            signal_cancellation.cancel();
        }
    });

    let control_path = PathBuf::from(
        env::var_os("HFT_CONTROL_SOCKET").unwrap_or_else(|| "/run/hftd/control.sock".into()),
    );
    let (control_tx, _control_rx) = watch::channel(ControlSnapshot::default());
    let control_cancellation = cancellation.clone();
    let control_task = tokio::spawn(async move {
        run_control_server(&control_path, control_tx, control_cancellation).await
    });
    let (storage_tx, storage_rx) = mpsc::channel(256);
    let storage_task = tokio::spawn(run_storage_actor(
        storage_rx,
        repository,
        cancellation.clone(),
    ));
    let session_id = Uuid::new_v4();
    info!(%session_id, "starting HFT daemon");
    let daemon = Daemon::new(rpmsg, gateway, storage_tx, cancellation.clone(), session_id);
    let stats = daemon.run().await.context("run HFT actors")?;
    cancellation.cancel();
    storage_task
        .await
        .context("join storage actor")?
        .context("run storage actor")?;
    control_task
        .await
        .context("join control actor")?
        .context("run control actor")?;
    info!(
        received = stats.intents_received,
        sent = stats.intents_sent,
        dropped = stats.analytics_dropped,
        "HFT daemon stopped"
    );
    Ok(())
}
