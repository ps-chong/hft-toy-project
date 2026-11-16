//! systemd readiness and watchdog notifications, using only `std`.
//!
//! The service is `Type=notify` with a `WatchdogSec`. The manager gives the
//! process a datagram socket in `NOTIFY_SOCKET` (a path, or `@name` for an
//! abstract address). The daemon sends `READY=1` once its tasks run,
//! `WATCHDOG=1` at half the configured period, and `STOPPING=1` when it
//! starts to shut down. Without `NOTIFY_SOCKET` (the host demo, tests) every
//! call is a no-op.
//!
//! The watchdog proves that the Tokio runtime still schedules tasks. It does
//! not prove that every task is healthy: a single stuck task is the
//! supervisor's business (a failure or a panic), not the watchdog's.

use std::{
    env, io,
    os::{
        linux::net::SocketAddrExt,
        unix::net::{SocketAddr, UnixDatagram},
    },
    time::Duration,
};

use tokio::time::{MissedTickBehavior, interval};
use tokio_util::sync::CancellationToken;
use tracing::warn;

use crate::DaemonError;

/// Sends one datagram to a `NOTIFY_SOCKET` address.
fn notify_to(address: &str, message: &str) -> io::Result<()> {
    let socket = UnixDatagram::unbound()?;
    if let Some(name) = address.strip_prefix('@') {
        let target = SocketAddr::from_abstract_name(name)?;
        socket.send_to_addr(message.as_bytes(), &target)?;
    } else {
        socket.send_to(message.as_bytes(), address)?;
    }
    Ok(())
}

/// How often to send `WATCHDOG=1`: half of `WATCHDOG_USEC`, as `sd_watchdog_enabled(3)`
/// advises. `None` when no watchdog is configured, the value is not a positive
/// number, or `WATCHDOG_PID` names another process.
#[must_use]
pub fn watchdog_period(usec: Option<&str>, pid: Option<&str>, own_pid: u32) -> Option<Duration> {
    let usec: u64 = usec?.trim().parse().ok().filter(|usec| *usec > 0)?;
    if let Some(pid) = pid
        && pid.trim().parse::<u32>().ok()? != own_pid
    {
        return None;
    }
    Some(Duration::from_micros(usec / 2))
}

/// The manager's notify socket and watchdog period, if the service has them.
#[derive(Clone, Debug, Default)]
pub struct Notifier {
    address: Option<String>,
    watchdog: Option<Duration>,
}

impl Notifier {
    /// Reads `NOTIFY_SOCKET`, `WATCHDOG_USEC` and `WATCHDOG_PID`.
    #[must_use]
    pub fn from_env() -> Self {
        let address = env::var("NOTIFY_SOCKET")
            .ok()
            .filter(|address| !address.is_empty());
        let watchdog = watchdog_period(
            env::var("WATCHDOG_USEC").ok().as_deref(),
            env::var("WATCHDOG_PID").ok().as_deref(),
            std::process::id(),
        );
        Self::new(address, watchdog)
    }

    /// A notifier with explicit settings.
    #[must_use]
    pub const fn new(address: Option<String>, watchdog: Option<Duration>) -> Self {
        Self { address, watchdog }
    }

    /// The watchdog ping period, if the manager asked for a watchdog.
    #[must_use]
    pub const fn watchdog(&self) -> Option<Duration> {
        self.watchdog
    }

    fn send(&self, message: &str) {
        let Some(address) = &self.address else {
            return;
        };
        if let Err(error) = notify_to(address, message) {
            warn!(%error, message, "systemd notification failed");
        }
    }

    /// The daemon is up: the exchange, journal and R5 are connected.
    pub fn ready(&self) {
        self.send("READY=1");
    }

    /// Shutdown has begun.
    pub fn stopping(&self) {
        self.send("STOPPING=1");
    }

    fn ping(&self) {
        self.send("WATCHDOG=1");
    }
}

/// Pings the watchdog every `period` until cancelled. Runs on the same
/// runtime as the trading tasks, so a wedged runtime stops the pings and
/// systemd restarts the service.
pub async fn run_watchdog(
    notifier: Notifier,
    period: Duration,
    cancellation: CancellationToken,
) -> Result<(), DaemonError> {
    let mut ticker = interval(period);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            () = cancellation.cancelled() => return Ok(()),
            _ = ticker.tick() => notifier.ping(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn received(socket: &UnixDatagram) -> Vec<String> {
        socket.set_nonblocking(true).unwrap();
        let mut messages = Vec::new();
        let mut buffer = [0_u8; 64];
        while let Ok(length) = socket.recv(&mut buffer) {
            messages.push(String::from_utf8_lossy(&buffer[..length]).into_owned());
        }
        messages
    }

    #[test]
    fn sends_to_a_path_address() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("notify.sock");
        let server = UnixDatagram::bind(&path).unwrap();
        let notifier = Notifier::new(Some(path.to_str().unwrap().to_owned()), None);
        notifier.ready();
        notifier.stopping();
        assert_eq!(received(&server), ["READY=1", "STOPPING=1"]);
    }

    #[test]
    fn sends_to_an_abstract_address() {
        let name = format!("hftd-test-notify-{}", std::process::id());
        let server =
            UnixDatagram::bind_addr(&SocketAddr::from_abstract_name(&name).unwrap()).unwrap();
        let notifier = Notifier::new(Some(format!("@{name}")), None);
        notifier.ready();
        assert_eq!(received(&server), ["READY=1"]);
    }

    #[test]
    fn does_nothing_without_a_notify_socket() {
        let notifier = Notifier::default();
        notifier.ready();
        notifier.ping();
        notifier.stopping();
        // A dead address is reported, not fatal.
        Notifier::new(Some("/nonexistent/notify.sock".to_owned()), None).ready();
    }

    #[test]
    fn watchdog_period_is_half_the_configured_timeout() {
        let own = 4242;
        assert_eq!(
            watchdog_period(Some("10000000"), None, own),
            Some(Duration::from_secs(5))
        );
        assert_eq!(
            watchdog_period(Some("10000000"), Some("4242"), own),
            Some(Duration::from_secs(5))
        );
        // Another process owns the watchdog, or the settings are unusable.
        assert_eq!(watchdog_period(Some("10000000"), Some("1"), own), None);
        assert_eq!(watchdog_period(Some("10000000"), Some("x"), own), None);
        assert_eq!(watchdog_period(Some("0"), None, own), None);
        assert_eq!(watchdog_period(Some("soon"), None, own), None);
        assert_eq!(watchdog_period(None, None, own), None);
    }

    #[tokio::test(start_paused = true)]
    async fn pings_every_period_until_cancelled() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("notify.sock");
        let server = UnixDatagram::bind(&path).unwrap();
        let period = Duration::from_secs(5);
        let notifier = Notifier::new(Some(path.to_str().unwrap().to_owned()), Some(period));
        let cancellation = CancellationToken::new();
        let task = tokio::spawn(run_watchdog(notifier, period, cancellation.clone()));

        // Ticks at 0 s, 5 s and 10 s.
        tokio::time::sleep(Duration::from_secs(11)).await;
        assert_eq!(received(&server), ["WATCHDOG=1"; 3]);

        cancellation.cancel();
        task.await.unwrap().unwrap();
        tokio::time::sleep(period * 2).await;
        assert!(received(&server).is_empty(), "no pings after cancellation");
    }
}
