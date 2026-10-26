//! `SoupBinTCP` session and OUCH order-entry gateway building blocks.
//!
//! A connection splits into an [`OuchWriter`] and an [`OuchReader`]. Both
//! stay owned by the daemon's gateway task, which `select!`s over the
//! reader; [`OuchReader::next_event`] is cancel-safe because the framed
//! reader keeps partial frames buffered. The halves are generic over the
//! byte stream, so tests run them over `tokio::io::duplex`.

use std::{fmt::Write as _, io, net::SocketAddr, time::Duration};

use bytes::{Bytes, BytesMut};
use futures_util::{SinkExt, StreamExt};
use hft_protocol::{
    OrderIntent, ProtocolError, SoupPacket,
    codec::{FrameError, SoupCodec},
    encode_enter_order,
};
use thiserror::Error;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::{
        TcpStream,
        tcp::{OwnedReadHalf, OwnedWriteHalf},
    },
    time::timeout,
};
use tokio_util::codec::{FramedRead, FramedWrite};

/// Login and timing parameters for one `SoupBinTCP` session.
#[derive(Clone, Debug)]
pub struct SessionConfig {
    /// Username, space padded on the right.
    pub username: [u8; 6],
    /// Password, space padded on the right.
    pub password: [u8; 10],
    /// Requested session (spaces request the current one).
    pub session: [u8; 10],
    /// Next sequenced message the client expects.
    pub sequence: u64,
    /// Bound on login and each send.
    pub io_timeout: Duration,
    /// Client heartbeat period (`SoupBinTCP` requires one per second).
    pub heartbeat_interval: Duration,
    /// Silence after which the server is considered gone.
    pub server_timeout: Duration,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            username: *b"SIMUSR",
            password: *b"SIMULATOR ",
            session: *b"SIM0000001",
            sequence: 1,
            io_timeout: Duration::from_secs(5),
            heartbeat_interval: Duration::from_secs(1),
            server_timeout: Duration::from_secs(15),
        }
    }
}

/// Gateway failures. All are fatal for the session.
#[derive(Debug, Error)]
pub enum OuchError {
    /// Transport failure.
    #[error("OUCH I/O failed: {0}")]
    Io(#[from] io::Error),
    /// Invalid frame or message.
    #[error("OUCH protocol failed validation: {0}")]
    Protocol(#[from] ProtocolError),
    /// An operation exceeded its deadline.
    #[error("operation timed out")]
    Timeout,
    /// The server refused the login.
    #[error("login rejected")]
    LoginRejected,
    /// The server closed the connection or ended the session.
    #[error("session closed by the server")]
    Closed,
    /// The server sent no data within the server timeout.
    #[error("server heartbeat lost")]
    HeartbeatLost,
    /// Unexpected packet during login.
    #[error("unexpected SoupBinTCP packet type {0:#04x}")]
    UnexpectedPacket(u8),
}

impl From<FrameError> for OuchError {
    fn from(error: FrameError) -> Self {
        match error {
            FrameError::Io(error) => Self::Io(error),
            FrameError::Protocol(error) => Self::Protocol(error),
        }
    }
}

/// Something the exchange told us.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OuchEvent {
    /// Server heartbeat (`H`).
    Heartbeat,
    /// Order accepted (`A`).
    Accepted {
        /// Client reference of the order.
        user_ref: u32,
    },
    /// Order rejected (`J`).
    Rejected {
        /// Client reference, when the payload carries one.
        user_ref: Option<u32>,
    },
    /// Order executed (`E`).
    Executed {
        /// Client reference.
        user_ref: u32,
    },
    /// Order cancelled (`C`).
    Canceled {
        /// Client reference.
        user_ref: u32,
    },
    /// Order replaced (`U`).
    Replaced {
        /// Client reference.
        user_ref: u32,
    },
    /// Any other sequenced message or debug packet.
    Other {
        /// SoupBinTCP packet type.
        packet_type: u8,
    },
}

impl OuchEvent {
    /// Interprets one inbound packet. `Z` (end of session) is an error.
    pub fn from_packet(packet: &SoupPacket) -> Result<Self, OuchError> {
        match packet.packet_type {
            b'H' => Ok(Self::Heartbeat),
            b'Z' => Err(OuchError::Closed),
            b'S' => Ok(Self::from_sequenced(&packet.payload)),
            other => Ok(Self::Other { packet_type: other }),
        }
    }

    fn from_sequenced(payload: &[u8]) -> Self {
        let Some((&message_type, body)) = payload.split_first() else {
            return Self::Other { packet_type: b'S' };
        };
        let user_ref = body
            .first_chunk::<4>()
            .map(|bytes| u32::from_be_bytes(*bytes));
        match (message_type, user_ref) {
            (b'A', Some(user_ref)) => Self::Accepted { user_ref },
            (b'E', Some(user_ref)) => Self::Executed { user_ref },
            (b'C', Some(user_ref)) => Self::Canceled { user_ref },
            (b'U', Some(user_ref)) => Self::Replaced { user_ref },
            (b'J', user_ref) => Self::Rejected { user_ref },
            _ => Self::Other { packet_type: b'S' },
        }
    }
}

/// Receiving half.
pub struct OuchReader<R> {
    frames: FramedRead<R, SoupCodec>,
}

impl<R: AsyncRead + Unpin + Send> OuchReader<R> {
    /// Next inbound event. Cancel-safe.
    pub async fn next_event(&mut self) -> Result<OuchEvent, OuchError> {
        let packet = self.frames.next().await.ok_or(OuchError::Closed)??;
        OuchEvent::from_packet(&packet)
    }

    async fn next_packet(&mut self) -> Result<SoupPacket, OuchError> {
        Ok(self.frames.next().await.ok_or(OuchError::Closed)??)
    }
}

/// Sending half.
pub struct OuchWriter<W> {
    frames: FramedWrite<W, SoupCodec>,
    io_timeout: Duration,
}

impl<W: AsyncWrite + Unpin + Send> OuchWriter<W> {
    async fn send(&mut self, packet: SoupPacket) -> Result<(), OuchError> {
        timeout(self.io_timeout, self.frames.send(packet))
            .await
            .map_err(|_| OuchError::Timeout)??;
        Ok(())
    }

    /// Sends one Enter Order for an approved intent.
    pub async fn send_intent(&mut self, intent: &OrderIntent) -> Result<(), OuchError> {
        self.send(SoupPacket {
            packet_type: b'U',
            payload: encode_enter_order(intent)?,
        })
        .await
    }

    /// Sends a client heartbeat (`R`).
    pub async fn heartbeat(&mut self) -> Result<(), OuchError> {
        self.send(SoupPacket {
            packet_type: b'R',
            payload: Bytes::new(),
        })
        .await
    }

    /// Sends a logout request (`O`).
    pub async fn logout(&mut self) -> Result<(), OuchError> {
        self.send(SoupPacket {
            packet_type: b'O',
            payload: Bytes::new(),
        })
        .await
    }
}

/// Encodes a Login Request. Numeric fields are right-justified and space
/// padded on the left, as `SoupBinTCP` specifies.
#[must_use]
pub fn encode_login(config: &SessionConfig) -> Bytes {
    let mut payload = BytesMut::with_capacity(46);
    payload.extend_from_slice(&config.username);
    payload.extend_from_slice(&config.password);
    payload.extend_from_slice(&config.session);
    // BytesMut implements fmt::Write, so no intermediate String is built.
    let _ = write!(payload, "{:>20}", config.sequence);
    payload.freeze()
}

/// Logs in over `reader`/`writer` and returns the ready session halves.
pub async fn login<R, W>(
    reader: R,
    writer: W,
    config: &SessionConfig,
) -> Result<(OuchReader<R>, OuchWriter<W>), OuchError>
where
    R: AsyncRead + Unpin + Send,
    W: AsyncWrite + Unpin + Send,
{
    let mut reader = OuchReader {
        frames: FramedRead::new(reader, SoupCodec),
    };
    let mut writer = OuchWriter {
        frames: FramedWrite::new(writer, SoupCodec),
        io_timeout: config.io_timeout,
    };
    writer
        .send(SoupPacket {
            packet_type: b'L',
            payload: encode_login(config),
        })
        .await?;
    let response = timeout(config.io_timeout, reader.next_packet())
        .await
        .map_err(|_| OuchError::Timeout)??;
    match response.packet_type {
        b'A' => Ok((reader, writer)),
        b'J' => Err(OuchError::LoginRejected),
        other => Err(OuchError::UnexpectedPacket(other)),
    }
}

/// Connects over TCP with Nagle disabled and logs in.
pub async fn connect(
    address: SocketAddr,
    config: &SessionConfig,
) -> Result<(OuchReader<OwnedReadHalf>, OuchWriter<OwnedWriteHalf>), OuchError> {
    let stream = timeout(config.io_timeout, TcpStream::connect(address))
        .await
        .map_err(|_| OuchError::Timeout)??;
    // Order entry sends small frames; Nagle plus delayed ACK would add up to
    // tens of milliseconds per order.
    stream.set_nodelay(true)?;
    let (reader, writer) = stream.into_split();
    login(reader, writer, config).await
}

#[cfg(test)]
mod tests {
    use hft_protocol::{OrderAction, Side};
    use tokio::io::{DuplexStream, duplex, split};
    use tokio_util::codec::Framed;

    use super::*;

    async fn exchange_pair() -> (
        (
            OuchReader<tokio::io::ReadHalf<DuplexStream>>,
            OuchWriter<tokio::io::WriteHalf<DuplexStream>>,
        ),
        Framed<DuplexStream, SoupCodec>,
    ) {
        let (client, server) = duplex(4096);
        let mut server = Framed::new(server, SoupCodec);
        let (reader, writer) = split(client);
        let login_task =
            tokio::spawn(async move { login(reader, writer, &SessionConfig::default()).await });
        let request = server.next().await.unwrap().unwrap();
        assert_eq!(request.packet_type, b'L');
        assert_eq!(&request.payload[26..], b"                   1");
        server
            .send(SoupPacket {
                packet_type: b'A',
                payload: Bytes::from_static(b"SIM000000100000000000000000001"),
            })
            .await
            .unwrap();
        (login_task.await.unwrap().unwrap(), server)
    }

    #[tokio::test]
    async fn logs_in_sends_order_and_reads_acknowledgement() {
        let ((mut reader, mut writer), mut server) = exchange_pair().await;
        let intent = OrderIntent {
            action: OrderAction::Enter,
            side: Side::Buy,
            user_ref: 7,
            symbol: *b"ACME    ",
            price: 100,
            quantity: 5,
            ..OrderIntent::default()
        };
        writer.send_intent(&intent).await.unwrap();
        let order = server.next().await.unwrap().unwrap();
        assert_eq!(order.packet_type, b'U');
        assert_eq!(order.payload[0], b'O');

        server
            .send(SoupPacket {
                packet_type: b'S',
                payload: Bytes::from_static(b"A\0\0\0\x07"),
            })
            .await
            .unwrap();
        assert_eq!(
            reader.next_event().await.unwrap(),
            OuchEvent::Accepted { user_ref: 7 }
        );
    }

    #[tokio::test]
    async fn rejected_login_is_an_error() {
        let (client, server) = duplex(1024);
        let mut server = Framed::new(server, SoupCodec);
        let (reader, writer) = split(client);
        let login_task =
            tokio::spawn(async move { login(reader, writer, &SessionConfig::default()).await });
        let _ = server.next().await;
        server
            .send(SoupPacket {
                packet_type: b'J',
                payload: Bytes::from_static(b"A"),
            })
            .await
            .unwrap();
        assert!(matches!(
            login_task.await.unwrap(),
            Err(OuchError::LoginRejected)
        ));
    }

    #[test]
    fn classifies_sequenced_responses() {
        let packet = |payload: &'static [u8]| SoupPacket {
            packet_type: b'S',
            payload: Bytes::from_static(payload),
        };
        assert_eq!(
            OuchEvent::from_packet(&packet(b"Jmalformed")).unwrap(),
            OuchEvent::Rejected {
                user_ref: Some(u32::from_be_bytes(*b"malf"))
            }
        );
        assert_eq!(
            OuchEvent::from_packet(&packet(b"C\0\0\0\x02")).unwrap(),
            OuchEvent::Canceled { user_ref: 2 }
        );
        assert!(matches!(
            OuchEvent::from_packet(&SoupPacket {
                packet_type: b'Z',
                payload: Bytes::new()
            }),
            Err(OuchError::Closed)
        ));
    }
}
