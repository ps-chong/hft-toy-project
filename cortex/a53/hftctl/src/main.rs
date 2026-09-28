use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde_json::json;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
};

#[derive(Debug, Parser)]
#[command(about = "Control and inspect the local ZCU102 HFT daemon")]
struct Cli {
    #[arg(long, default_value = "/run/hftd/control.sock")]
    socket: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Status,
    Arm,
    Kill,
    Counters,
    SetRisk {
        #[arg(long)]
        max_quantity: u32,
        #[arg(long)]
        price_floor: u64,
        #[arg(long)]
        price_ceiling: u64,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let request = match cli.command {
        Command::Status => json!({"command": "status"}),
        Command::Arm => json!({"command": "arm"}),
        Command::Kill => json!({"command": "kill"}),
        Command::Counters => json!({"command": "counters"}),
        Command::SetRisk {
            max_quantity,
            price_floor,
            price_ceiling,
        } => json!({
            "command": "set-risk",
            "max_quantity": max_quantity,
            "price_floor": price_floor,
            "price_ceiling": price_ceiling
        }),
    };

    let stream = UnixStream::connect(&cli.socket)
        .await
        .with_context(|| format!("connect {}", cli.socket.display()))?;
    let (reader, mut writer) = stream.into_split();
    writer.write_all(request.to_string().as_bytes()).await?;
    writer.write_all(b"\n").await?;
    writer.shutdown().await?;

    let mut response = String::new();
    BufReader::new(reader).read_line(&mut response).await?;
    println!("{}", response.trim_end());
    Ok(())
}
