use std::{io, path::Path};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    fs,
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::watch,
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ControlSnapshot {
    pub armed: bool,
    pub killed: bool,
    pub max_quantity: u32,
    pub price_floor: u64,
    pub price_ceiling: u64,
    pub revision: u32,
}

impl Default for ControlSnapshot {
    fn default() -> Self {
        Self {
            armed: false,
            killed: true,
            max_quantity: 1_000,
            price_floor: 1,
            price_ceiling: 1_000_000_000,
            revision: 1,
        }
    }
}

pub async fn run_control_server(
    path: &Path,
    updates: watch::Sender<ControlSnapshot>,
    cancellation: CancellationToken,
) -> io::Result<()> {
    if fs::try_exists(path).await? {
        fs::remove_file(path).await?;
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).await?;
    }
    let listener = UnixListener::bind(path)?;
    let mut state = updates.borrow().clone();

    loop {
        tokio::select! {
            () = cancellation.cancelled() => {
                let _result = fs::remove_file(path).await;
                return Ok(());
            }
            accepted = listener.accept() => {
                let (stream, _) = accepted?;
                handle_connection(stream, &mut state, &updates).await?;
            }
        }
    }
}

async fn handle_connection(
    stream: UnixStream,
    state: &mut ControlSnapshot,
    updates: &watch::Sender<ControlSnapshot>,
) -> io::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut request = String::new();
    BufReader::new(reader).read_line(&mut request).await?;
    let response = match serde_json::from_str::<Value>(&request) {
        Ok(command) => apply_command(state, &command).map_or_else(
            |message| json!({"ok": false, "error": message}),
            |_| {
                updates.send_replace(state.clone());
                json!({"ok": true, "state": state})
            },
        ),
        Err(error) => json!({"ok": false, "error": error.to_string()}),
    };
    writer.write_all(response.to_string().as_bytes()).await?;
    writer.write_all(b"\n").await?;
    writer.shutdown().await
}

fn apply_command(state: &mut ControlSnapshot, request: &Value) -> Result<(), &'static str> {
    let command = request
        .get("command")
        .and_then(Value::as_str)
        .ok_or("missing command")?;
    match command {
        "status" | "counters" => return Ok(()),
        "arm" => {
            state.armed = true;
            state.killed = false;
        }
        "kill" => state.killed = true,
        "set-risk" => {
            state.max_quantity = u32::try_from(
                request
                    .get("max_quantity")
                    .and_then(Value::as_u64)
                    .ok_or("invalid max_quantity")?,
            )
            .map_err(|_| "max_quantity out of range")?;
            state.price_floor = request
                .get("price_floor")
                .and_then(Value::as_u64)
                .ok_or("invalid price_floor")?;
            state.price_ceiling = request
                .get("price_ceiling")
                .and_then(Value::as_u64)
                .ok_or("invalid price_ceiling")?;
            if state.price_floor > state.price_ceiling {
                return Err("price floor exceeds ceiling");
            }
        }
        _ => return Err("unknown command"),
    }
    state.revision = state.revision.saturating_add(1);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_fail_closed_control_transitions() {
        let mut state = ControlSnapshot::default();
        assert!(apply_command(&mut state, &json!({"command": "arm"})).is_ok());
        assert!(state.armed);
        assert!(!state.killed);
        assert!(apply_command(&mut state, &json!({"command": "kill"})).is_ok());
        assert!(state.killed);
        assert_eq!(state.revision, 3);
    }

    #[test]
    fn rejects_invalid_price_collar() {
        let mut state = ControlSnapshot::default();
        let result = apply_command(
            &mut state,
            &json!({
                "command": "set-risk",
                "max_quantity": 10,
                "price_floor": 100,
                "price_ceiling": 90
            }),
        );
        assert!(result.is_err());
    }
}
