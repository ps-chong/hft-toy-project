//! Control plane: one active object owns the [`ControlSnapshot`].
//!
//! Socket connections never touch the snapshot. Each one parses a typed
//! [`ControlCommand`] and sends it, with a `oneshot` reply channel, to the
//! actor, which applies commands one at a time and publishes every change on
//! a `watch` channel. A slow or idle client therefore cannot block anyone
//! else, including a `kill`: each connection runs in its own task with a
//! deadline and a size limit.

use std::{
    io,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use hft_protocol::control::{ControlCommand, ControlResponse, ControlSnapshot};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{mpsc, oneshot, watch},
    task::JoinSet,
    time::timeout,
};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crate::counters::Counters;

/// Largest request line accepted from a client.
pub const MAX_REQUEST_BYTES: u64 = 4 * 1024;
/// Deadline for a client to send its request.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

/// One queued command and where to send its reply.
#[derive(Debug)]
pub struct ControlRequest {
    /// The parsed command.
    pub command: ControlCommand,
    /// Reply channel (the promise half of a future/promise pair).
    pub reply: oneshot::Sender<ControlResponse>,
}

/// The active object. Exits when every request sender is gone or on cancel.
pub async fn run_control_actor(
    mut requests: mpsc::Receiver<ControlRequest>,
    updates: watch::Sender<ControlSnapshot>,
    counters: Arc<Counters>,
    cancellation: CancellationToken,
) {
    loop {
        let request = tokio::select! {
            biased;
            () = cancellation.cancelled() => return,
            request = requests.recv() => match request {
                Some(request) => request,
                None => return,
            },
        };
        let mut outcome = Ok(false);
        // send_if_modified notifies subscribers only for real changes, and
        // apply() leaves the snapshot untouched when it refuses a command.
        updates.send_if_modified(|state| {
            outcome = request.command.apply(state);
            matches!(outcome, Ok(true))
        });
        let snapshot = *updates.borrow();
        let response = match outcome {
            Ok(changed) => {
                if changed {
                    info!(revision = snapshot.revision, command = ?request.command, "control state changed");
                }
                ControlResponse::ok(snapshot, counters.snapshot())
            }
            Err(error) => ControlResponse::error(error.to_string()),
        };
        // The client may have gone away; that is its business.
        let _ = request.reply.send(response);
    }
}

/// Removes the socket file when the server stops, however it stops.
struct SocketCleanup(PathBuf);

impl Drop for SocketCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Binds the control socket without a check-then-delete race.
///
/// The bind is attempted first. Only if the path is already in use do we
/// probe it: a live daemon accepts the connection, and we refuse to steal its
/// socket; a stale file from a crash refuses it and is replaced.
pub fn bind_control_socket(path: &Path) -> io::Result<UnixListener> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    match UnixListener::bind(path) {
        Err(error) if error.kind() == io::ErrorKind::AddrInUse => {
            if std::os::unix::net::UnixStream::connect(path).is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "another hftd instance owns the control socket",
                ));
            }
            std::fs::remove_file(path)?;
            UnixListener::bind(path)
        }
        other => other,
    }
}

/// Accepts clients until cancelled; each connection gets its own task.
pub async fn run_control_server(
    listener: UnixListener,
    path: PathBuf,
    requests: mpsc::Sender<ControlRequest>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    let _cleanup = SocketCleanup(path);
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => break,
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                connections.spawn(handle_connection(stream, requests.clone()));
            }
            Some(finished) = connections.join_next(), if !connections.is_empty() => {
                if let Ok(Err(error)) = finished {
                    warn!(%error, "control connection failed");
                }
            }
        }
    }
    connections.shutdown().await;
    Ok(())
}

async fn handle_connection(
    stream: UnixStream,
    requests: mpsc::Sender<ControlRequest>,
) -> io::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut line = String::new();
    let mut bounded = BufReader::new(reader.take(MAX_REQUEST_BYTES));
    let response = match timeout(REQUEST_TIMEOUT, bounded.read_line(&mut line)).await {
        Err(_) => ControlResponse::error("request timed out"),
        Ok(Err(error)) => return Err(error),
        Ok(Ok(_)) => match serde_json::from_str::<ControlCommand>(line.trim_end()) {
            Ok(command) => dispatch(command, &requests).await,
            Err(error) => ControlResponse::error(error.to_string()),
        },
    };
    let mut encoded = serde_json::to_vec(&response).map_err(io::Error::other)?;
    encoded.push(b'\n');
    writer.write_all(&encoded).await?;
    writer.shutdown().await
}

async fn dispatch(
    command: ControlCommand,
    requests: &mpsc::Sender<ControlRequest>,
) -> ControlResponse {
    let (reply, response) = oneshot::channel();
    if requests
        .send(ControlRequest { command, reply })
        .await
        .is_err()
    {
        return ControlResponse::error("control actor stopped");
    }
    response
        .await
        .unwrap_or_else(|_| ControlResponse::error("control actor dropped the request"))
}

#[cfg(test)]
mod tests {
    use tokio::io::AsyncWriteExt;

    use super::*;

    async fn request(path: &Path, body: &str) -> ControlResponse {
        let mut stream = UnixStream::connect(path).await.unwrap();
        stream.write_all(body.as_bytes()).await.unwrap();
        stream.write_all(b"\n").await.unwrap();
        let mut response = String::new();
        BufReader::new(stream)
            .read_line(&mut response)
            .await
            .unwrap();
        serde_json::from_str(&response).unwrap()
    }

    #[tokio::test]
    async fn serves_typed_commands_and_keeps_kill_reachable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sock");
        let cancellation = CancellationToken::new();
        let (updates, mut snapshots) = watch::channel(ControlSnapshot::default());
        let (requests, inbox) = mpsc::channel(16);
        let counters = Arc::new(Counters::default());
        let actor = tokio::spawn(run_control_actor(
            inbox,
            updates,
            counters,
            cancellation.clone(),
        ));
        let listener = bind_control_socket(&path).unwrap();
        let server = tokio::spawn(run_control_server(
            listener,
            path.clone(),
            requests,
            cancellation.clone(),
        ));

        // An idle client that never sends a request must not block others.
        let _idle = UnixStream::connect(&path).await.unwrap();

        let armed = request(&path, r#"{"command":"arm"}"#).await;
        assert!(armed.ok);
        assert!(snapshots.borrow_and_update().trading_permitted());

        let killed = request(&path, r#"{"command":"kill"}"#).await;
        assert!(killed.ok);
        assert!(!snapshots.borrow_and_update().trading_permitted());

        let refused = request(
            &path,
            r#"{"command":"set-risk","max_quantity":1,"price_floor":9,"price_ceiling":1}"#,
        )
        .await;
        assert!(!refused.ok);
        let garbage = request(&path, "not json").await;
        assert!(!garbage.ok);

        cancellation.cancel();
        server.await.unwrap().unwrap();
        actor.await.unwrap();
        assert!(!path.exists(), "socket file is removed on shutdown");
    }

    #[tokio::test]
    async fn refuses_to_steal_a_live_socket_but_replaces_a_stale_one() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sock");
        let live = bind_control_socket(&path).unwrap();
        assert_eq!(
            bind_control_socket(&path).err().map(|error| error.kind()),
            Some(io::ErrorKind::AddrInUse)
        );
        drop(live);
        // The file is left behind, as after a crash.
        assert!(path.exists());
        assert!(bind_control_socket(&path).is_ok());
    }
}
