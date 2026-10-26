//! `hftd` entry point: environment configuration, transports, signals.

use std::{env, future::Future, net::SocketAddr, path::PathBuf, time::Duration};

use anyhow::{Context, Result};
use hft_ouch::SessionConfig;
use hft_rpmsg::RpmsgEndpoint;
use hft_storage::{AnyRepository, NullRepository, PgRepository, Repository, SessionInfo};
use hftd::DaemonConfig;
use tokio::signal::unix::{SignalKind, signal};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use uuid::Uuid;

fn init_tracing() -> Result<()> {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("hftd=info"));
    if env::var_os("HFT_LOG_STDOUT").is_none()
        && let Ok(journal) = tracing_journald::layer()
    {
        return tracing_subscriber::registry()
            .with(filter)
            .with(journal)
            .try_init()
            .map_err(|error| anyhow::anyhow!("install journald subscriber: {error}"));
    }
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .try_init()
        .map_err(|error| anyhow::anyhow!("install stdout subscriber: {error}"))
}

/// Retries `connect` once a second, so start-up ordering between containers
/// (or between remoteproc and hftd) does not matter.
async fn retry<T, F, Fut, E>(
    what: &str,
    attempts: u32,
    cancellation: &CancellationToken,
    mut connect: F,
) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = std::result::Result<T, E>>,
    E: std::error::Error + Send + Sync + 'static,
{
    let mut attempt = 1;
    loop {
        match connect().await {
            Ok(value) => return Ok(value),
            Err(error) if attempt < attempts => {
                warn!(%error, attempt, "{what} not ready; retrying");
                tokio::select! {
                    () = cancellation.cancelled() => anyhow::bail!("cancelled while connecting {what}"),
                    () = tokio::time::sleep(Duration::from_secs(1)) => {}
                }
                attempt += 1;
            }
            Err(error) => return Err(error).with_context(|| format!("connect {what}")),
        }
    }
}

async fn resolve(spec: &str) -> Result<SocketAddr> {
    tokio::net::lookup_host(spec)
        .await
        .with_context(|| format!("resolve {spec}"))?
        .next()
        .with_context(|| format!("{spec} resolved to no address"))
}

/// SIGINT (interactive) and SIGTERM (systemd stop) both drain gracefully.
fn spawn_signal_handler(cancellation: CancellationToken) -> Result<()> {
    let mut terminate = signal(SignalKind::terminate()).context("install SIGTERM handler")?;
    let mut interrupt = signal(SignalKind::interrupt()).context("install SIGINT handler")?;
    tokio::spawn(async move {
        tokio::select! {
            _ = terminate.recv() => info!("SIGTERM received"),
            _ = interrupt.recv() => info!("SIGINT received"),
        }
        cancellation.cancel();
    });
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing()?;
    let cancellation = CancellationToken::new();
    // Cancels every task if main returns early through `?`.
    let _shutdown = cancellation.clone().drop_guard();
    spawn_signal_handler(cancellation.clone())?;

    let rpmsg_spec = env::var("HFT_RPMSG_DEVICE").unwrap_or_else(|_| "/dev/rpmsg0".to_owned());
    // HOST:PORT; host names are resolved once (e.g. a Compose service name).
    let ouch_spec = env::var("HFT_OUCH_ADDR").unwrap_or_else(|_| "127.0.0.1:9001".to_owned());
    let ouch_address = resolve(&ouch_spec).await?;
    let attempts = env::var("HFT_CONNECT_ATTEMPTS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(30);
    let session = SessionConfig::default();

    let rpmsg = retry("RPMsg", attempts, &cancellation, || {
        RpmsgEndpoint::open(&rpmsg_spec)
    })
    .await?;
    let exchange = retry("OUCH", attempts, &cancellation, || {
        hft_ouch::connect(ouch_address, &session)
    })
    .await?;
    info!(%ouch_address, "SoupBinTCP session active");

    let repository = if let Some(url) = env::var("DATABASE_URL").ok().filter(|url| !url.is_empty())
    {
        AnyRepository::Pg(
            retry("PostgreSQL", attempts, &cancellation, || {
                PgRepository::connect(&url, 2)
            })
            .await?,
        )
    } else {
        warn!("DATABASE_URL is unset; journal persistence is disabled");
        AnyRepository::Null(NullRepository)
    };
    let session_id = Uuid::new_v4();
    repository
        .open_session(&SessionInfo {
            session_id,
            feed_session: String::from_utf8_lossy(&session.session).into_owned(),
            build_id: env!("CARGO_PKG_VERSION").to_owned(),
            schema_version: i32::from(hft_protocol::generated::ABI_VERSION),
        })
        .await
        .context("open journal session")?;

    let config = DaemonConfig {
        session_id,
        control_socket: PathBuf::from(
            env::var_os("HFT_CONTROL_SOCKET").unwrap_or_else(|| "/run/hftd/control.sock".into()),
        ),
        ..DaemonConfig::default()
    };
    info!(%session_id, rpmsg = %rpmsg_spec, "starting HFT daemon");
    let report = hftd::run(config, rpmsg, exchange, repository, cancellation.clone())
        .await
        .context("run HFT tasks")?;
    info!(?report, "HFT daemon stopped");
    Ok(())
}
