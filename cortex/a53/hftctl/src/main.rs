//! `hftctl`: send one typed control command to the local daemon.

use std::{path::PathBuf, time::Duration};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use hft_protocol::control::{ControlCommand, ControlResponse};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    time::timeout,
};

#[derive(Debug, Parser)]
#[command(about = "Control and inspect the local MYD-CZU5EV-V2 HFT daemon")]
struct Cli {
    /// Control socket of the daemon.
    #[arg(long, default_value = "/run/hftd/control.sock")]
    socket: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Print the risk/trading snapshot and counters.
    Status,
    /// Permit trading and clear latched faults on the R5.
    Arm,
    /// Stop trading immediately.
    Kill,
    /// Print daemon counters.
    Counters,
    /// Replace the risk limits.
    SetRisk {
        /// Maximum shares per order.
        #[arg(long)]
        max_quantity: u32,
        /// Lowest accepted price.
        #[arg(long)]
        price_floor: u64,
        /// Highest accepted price.
        #[arg(long)]
        price_ceiling: u64,
    },
    /// Select the R5 strategy (0 = mirror, 1 = imbalance).
    SelectStrategy {
        /// Strategy index.
        strategy_id: u8,
    },
}

impl From<Command> for ControlCommand {
    fn from(command: Command) -> Self {
        match command {
            Command::Status => Self::Status,
            Command::Arm => Self::Arm,
            Command::Kill => Self::Kill,
            Command::Counters => Self::Counters,
            Command::SetRisk {
                max_quantity,
                price_floor,
                price_ceiling,
            } => Self::SetRisk {
                max_quantity,
                price_floor,
                price_ceiling,
            },
            Command::SelectStrategy { strategy_id } => Self::SelectStrategy { strategy_id },
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let request = ControlCommand::from(cli.command);
    let mut body = serde_json::to_vec(&request).context("encode request")?;
    body.push(b'\n');

    let stream = UnixStream::connect(&cli.socket)
        .await
        .with_context(|| format!("connect {}", cli.socket.display()))?;
    let (reader, mut writer) = stream.into_split();
    writer.write_all(&body).await?;
    writer.shutdown().await?;

    let mut line = String::new();
    timeout(
        Duration::from_secs(5),
        BufReader::new(reader).read_line(&mut line),
    )
    .await
    .context("daemon did not answer within 5 s")??;
    let response: ControlResponse = serde_json::from_str(&line).context("decode response")?;
    println!("{}", serde_json::to_string_pretty(&response)?);
    if response.ok {
        Ok(())
    } else {
        anyhow::bail!(
            response
                .error
                .unwrap_or_else(|| "command refused".to_owned())
        )
    }
}
