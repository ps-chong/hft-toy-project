//! End-to-end daemon test: a Unix-socket R5, an in-memory exchange, and the
//! real task topology. Verifies fail-closed start-up, arm/kill gating at the
//! gateway, `risk_config` propagation to the R5, and clean shutdown.
#![allow(clippy::unwrap_used, reason = "test helpers panic on setup failure")]

use std::{path::Path, sync::Arc, time::Duration};

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use hft_ouch::SessionConfig;
use hft_protocol::{
    OrderAction, OrderIntent, RiskConfigRecord, Side, SoupPacket,
    codec::{RecordCodec, SoupCodec},
    control::{ControlCommand, ControlResponse, ControlSnapshot},
    generated::ipc::risk_config_flags,
};
use hft_rpmsg::{RpmsgEndpoint, UnixRpmsg};
use hft_storage::{AnyRepository, NullRepository};
use hftd::{
    DaemonConfig,
    counters::Counters,
    gateway::{GatewayConfig, run_gateway},
    record::RingIntent,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, DuplexStream},
    net::UnixStream,
    sync::{mpsc, watch},
    time::timeout,
};
use tokio_util::{codec::Framed, sync::CancellationToken};

async fn control(path: &Path, command: &ControlCommand) -> ControlResponse {
    for _ in 0..50 {
        if let Ok(mut stream) = UnixStream::connect(path).await {
            let mut body = serde_json::to_vec(command).unwrap();
            body.push(b'\n');
            stream.write_all(&body).await.unwrap();
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line).await.unwrap();
            return serde_json::from_str(&line).unwrap();
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("control socket never appeared");
}

async fn next_config(r5: &mut Framed<UnixStream, RecordCodec>) -> RiskConfigRecord {
    let frame = timeout(Duration::from_secs(5), r5.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    RiskConfigRecord::decode_ipc(&frame).unwrap()
}

async fn next_order(exchange: &mut Framed<DuplexStream, SoupCodec>) -> Option<SoupPacket> {
    loop {
        match timeout(Duration::from_millis(300), exchange.next()).await {
            Ok(Some(Ok(packet))) if packet.packet_type == b'U' => return Some(packet),
            Ok(Some(Ok(_heartbeat))) => {}
            _ => return None,
        }
    }
}

fn intent(user_ref: u32) -> [u8; 64] {
    OrderIntent {
        action: OrderAction::Enter,
        side: Side::Buy,
        user_ref,
        source_sequence: u64::from(user_ref),
        symbol: *b"ACME    ",
        price: 100,
        quantity: 1,
        ..OrderIntent::default()
    }
    .encode_ipc()
}

async fn wait_until(condition: impl Fn() -> bool) {
    for _ in 0..200 {
        if condition() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("condition never held");
}

async fn wait_for_counter(path: &Path, predicate: impl Fn(&ControlResponse) -> bool) {
    for _ in 0..100 {
        if predicate(&control(path, &ControlCommand::Counters).await) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("counter condition never held");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn forwards_only_while_armed_and_shuts_down_cleanly() {
    let directory = tempfile::tempdir().unwrap();
    let control_socket = directory.path().join("control.sock");

    let (daemon_side, r5_side) = UnixStream::pair().unwrap();
    let mut r5 = Framed::new(r5_side, RecordCodec);

    let (client, server) = tokio::io::duplex(1 << 16);
    let mut exchange = Framed::new(server, SoupCodec);
    let (reader, writer) = tokio::io::split(client);
    let login =
        tokio::spawn(
            async move { hft_ouch::login(reader, writer, &SessionConfig::default()).await },
        );
    let _login_request = exchange.next().await;
    exchange
        .send(SoupPacket {
            packet_type: b'A',
            payload: Bytes::from_static(b"SIM000000100000000000000000001"),
        })
        .await
        .unwrap();
    let session = login.await.unwrap().unwrap();

    let cancellation = CancellationToken::new();
    let config = DaemonConfig {
        control_socket: control_socket.clone(),
        ..DaemonConfig::default()
    };
    let daemon = tokio::spawn(hftd::run(
        config,
        RpmsgEndpoint::Unix(UnixRpmsg::new(daemon_side)),
        session,
        AnyRepository::Null(NullRepository),
        cancellation.clone(),
    ));

    // Fail-closed start: the R5 is told "killed" before anything else.
    let initial = next_config(&mut r5).await;
    assert_ne!(initial.flags & risk_config_flags::KILL, 0);

    // An intent arriving while killed is withheld by the gateway.
    r5.send(intent(1)).await.unwrap();
    wait_for_counter(&control_socket, |response| {
        response
            .counters
            .is_some_and(|counters| counters.intents_blocked == 1)
    })
    .await;

    assert!(control(&control_socket, &ControlCommand::Arm).await.ok);
    let armed = next_config(&mut r5).await;
    assert_eq!(armed.flags & risk_config_flags::KILL, 0);
    assert_ne!(armed.flags & risk_config_flags::CLEAR_KILL, 0);

    r5.send(intent(2)).await.unwrap();
    let order = next_order(&mut exchange)
        .await
        .expect("armed intent reaches the exchange");
    assert_eq!(order.payload[0], b'O');

    assert!(control(&control_socket, &ControlCommand::Kill).await.ok);
    let killed = next_config(&mut r5).await;
    assert_ne!(killed.flags & risk_config_flags::KILL, 0);
    r5.send(intent(3)).await.unwrap();
    assert!(
        next_order(&mut exchange).await.is_none(),
        "killed intent must not be sent"
    );

    cancellation.cancel();
    let report = daemon.await.unwrap().unwrap();
    assert_eq!(report.intents_received, 3);
    assert_eq!(report.intents_sent, 1);
    assert_eq!(report.intents_blocked, 2);
    assert!(!control_socket.exists());
}

/// A kill must hold back the very next intent, even one waiting in the same
/// batch. The exchange pipe is only 40 bytes (one framed Enter Order is 30),
/// so the gateway blocks inside the batch while the kill arrives.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_kill_applies_to_the_next_intent_inside_a_batch() {
    let (client, server) = tokio::io::duplex(40);
    let mut exchange = Framed::new(server, SoupCodec);
    let (reader, writer) = tokio::io::split(client);
    let login =
        tokio::spawn(
            async move { hft_ouch::login(reader, writer, &SessionConfig::default()).await },
        );
    let _login_request = exchange.next().await;
    exchange
        .send(SoupPacket {
            packet_type: b'A',
            payload: Bytes::from_static(b"SIM000000100000000000000000001"),
        })
        .await
        .unwrap();
    let (reader, writer) = login.await.unwrap().unwrap();

    // Eight intents are in the ring before the gateway starts, so it reads
    // them as one batch.
    let (mut producer, mut gating) = hft_disruptor::build::<RingIntent>(16, 1).unwrap();
    for user_ref in 1..=8_u32 {
        let record = RingIntent {
            intent: OrderIntent {
                action: OrderAction::Enter,
                side: Side::Buy,
                user_ref,
                symbol: *b"ACME    ",
                price: 100,
                quantity: 1,
                ..OrderIntent::default()
            },
            received_ns: 0,
        };
        producer.try_publish(&record).unwrap();
    }

    let mut armed = ControlSnapshot::default();
    ControlCommand::Arm.apply(&mut armed).unwrap();
    assert!(armed.trading_permitted());
    let (control_tx, control_rx) = watch::channel(armed);
    let (journal_tx, _journal_rx) = mpsc::channel(64);
    let counters = Arc::new(Counters::default());
    let cancellation = CancellationToken::new();
    let gateway = tokio::spawn(run_gateway(
        gating.pop().unwrap(),
        reader,
        writer,
        control_rx,
        journal_tx,
        Arc::clone(&counters),
        GatewayConfig::default(),
        cancellation.clone(),
    ));

    // The first intent fits in the pipe; the second send blocks on it.
    wait_until(|| counters.snapshot().intents_sent >= 1).await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut killed = armed;
    ControlCommand::Kill.apply(&mut killed).unwrap();
    control_tx.send(killed).unwrap();

    // Reading the exchange side unblocks the gateway. The task hands the
    // exchange back, so the session stays open until the gateway is stopped.
    let drain = tokio::spawn(async move {
        let mut orders = 0_u64;
        while let Ok(Some(Ok(packet))) = timeout(Duration::from_millis(300), exchange.next()).await
        {
            orders += u64::from(packet.packet_type == b'U');
        }
        (orders, exchange)
    });
    wait_until(|| {
        let report = counters.snapshot();
        report.intents_sent + report.intents_blocked == 8
    })
    .await;

    // At most the intent already being sent when the kill landed gets out.
    let report = counters.snapshot();
    assert!(report.intents_sent <= 2, "sent {}", report.intents_sent);
    assert!(
        report.intents_blocked >= 6,
        "blocked {}",
        report.intents_blocked
    );
    let (orders, _exchange) = drain.await.unwrap();
    assert_eq!(orders, report.intents_sent);

    cancellation.cancel();
    gateway.await.unwrap().unwrap();
}
