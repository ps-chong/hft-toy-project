//! `hft-plsim`: UDP MoldUDP64 in, 64-byte normalized events out.

use std::{net::SocketAddr, path::PathBuf, time::Duration};

use anyhow::{Context, Result};
use clap::Parser;
use futures_util::SinkExt;
use hft_plsim::FeedModel;
use hft_protocol::codec::RecordCodec;
use tokio::{
    fs::File,
    io::{AsyncWriteExt, BufWriter},
    net::{UdpSocket, UnixStream},
    signal::unix::{SignalKind, signal},
};
use tokio_util::codec::FramedWrite;

#[derive(Debug, Parser)]
#[command(about = "Software model of the PL MoldUDP64/ITCH ingress")]
struct Args {
    /// UDP address the exchange simulator publishes to.
    #[arg(long, default_value = "0.0.0.0:9000")]
    listen: SocketAddr,
    /// R5 model events socket.
    #[arg(long, default_value = "/run/hft/events.sock")]
    events: PathBuf,
    /// Raw datagram capture (u16 big-endian length + bytes) for the RTL replay.
    #[arg(long)]
    capture: Option<PathBuf>,
    /// Normalized events produced by this model (64-byte records).
    #[arg(long)]
    model_out: Option<PathBuf>,
    /// Stop after this many datagrams (0 = run until signalled).
    #[arg(long, default_value_t = 0)]
    max_datagrams: u64,
}

async fn connect_events(path: &PathBuf) -> Result<UnixStream> {
    for _ in 0..60 {
        if let Ok(stream) = UnixStream::connect(path).await {
            return Ok(stream);
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    anyhow::bail!("R5 model never opened {}", path.display())
}

async fn open(path: Option<&PathBuf>) -> Result<Option<BufWriter<File>>> {
    match path {
        Some(path) => Ok(Some(BufWriter::new(
            File::create(path)
                .await
                .with_context(|| format!("create {}", path.display()))?,
        ))),
        None => Ok(None),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let socket = UdpSocket::bind(args.listen)
        .await
        .context("bind feed socket")?;
    let mut events = FramedWrite::new(connect_events(&args.events).await?, RecordCodec);
    let mut capture = open(args.capture.as_ref()).await?;
    let mut model_out = open(args.model_out.as_ref()).await?;
    let mut terminate = signal(SignalKind::terminate())?;
    let mut model = FeedModel::default();
    let mut buffer = vec![0_u8; 65_536];
    let mut datagrams = 0_u64;
    let mut forwarded = 0_u64;
    println!(r#"{{"type":"plsim_ready","listen":"{}"}}"#, args.listen);

    loop {
        let length = tokio::select! {
            _ = terminate.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
            received = socket.recv_from(&mut buffer) => received?.0,
        };
        let datagram = buffer.get(..length).unwrap_or_default();
        datagrams += 1;
        if let Some(capture) = capture.as_mut() {
            capture
                .write_all(&u16::try_from(length).unwrap_or(u16::MAX).to_be_bytes())
                .await?;
            capture.write_all(datagram).await?;
        }
        match model.ingest(datagram) {
            Ok(outcome) => {
                if outcome.gap {
                    println!(r#"{{"type":"plsim_gap","gaps":{}}}"#, model.gaps());
                }
                for event in outcome.events {
                    let record = event.encode_ipc();
                    if let Some(out) = model_out.as_mut() {
                        out.write_all(&record).await?;
                    }
                    events
                        .send(record)
                        .await
                        .context("send event to R5 model")?;
                    forwarded += 1;
                }
            }
            Err(error) => println!(r#"{{"type":"plsim_malformed","error":"{error}"}}"#),
        }
        if args.max_datagrams != 0 && datagrams >= args.max_datagrams {
            break;
        }
    }
    for writer in [capture.as_mut(), model_out.as_mut()].into_iter().flatten() {
        writer.flush().await?;
    }
    println!(
        "{}",
        serde_json::json!({
            "type": "plsim_stats",
            "datagrams": datagrams,
            "events": forwarded,
            "gaps": model.gaps(),
            "duplicates": model.duplicates(),
        })
    );
    Ok(())
}
