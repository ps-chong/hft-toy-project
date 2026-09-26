//! SoupBinTCP session and OUCH order gateway.

use std::{io, net::SocketAddr, time::Duration};

use async_trait::async_trait;
use bytes::{BufMut, Bytes, BytesMut};
use hft_protocol::{OrderIntent, ProtocolError, SoupPacket, encode_enter_order};
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::timeout,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionState {
    Disconnected,
    Authenticating,
    Active,
    Reconnecting,
}

#[derive(Clone, Debug)]
pub struct SessionConfig {
    pub username: [u8; 6],
    pub password: [u8; 10],
    pub session: [u8; 10],
    pub sequence: u64,
    pub io_timeout: Duration,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            username: *b"SIMUSR",
            password: *b"SIMULATOR ",
            session: *b"SIM0000001",
            sequence: 1,
            io_timeout: Duration::from_secs(15),
        }
    }
}

#[derive(Debug, Error)]
pub enum OuchError {
    #[error("OUCH I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("OUCH protocol failed validation: {0}")]
    Protocol(#[from] ProtocolError),
    #[error("operation timed out")]
    Timeout,
    #[error("login rejected")]
    LoginRejected,
    #[error("session is not active")]
    NotActive,
    #[error("unexpected SoupBinTCP packet type {0:#04x}")]
    UnexpectedPacket(u8),
}

#[async_trait]
pub trait OuchTransport: Send {
    async fn send_packet(&mut self, packet: &SoupPacket) -> Result<(), OuchError>;
    async fn receive_packet(&mut self) -> Result<SoupPacket, OuchError>;
}

pub struct TcpOuchTransport {
    stream: TcpStream,
}

impl TcpOuchTransport {
    pub async fn connect(address: SocketAddr) -> Result<Self, OuchError> {
        Ok(Self {
            stream: TcpStream::connect(address).await?,
        })
    }
}

#[async_trait]
impl OuchTransport for TcpOuchTransport {
    async fn send_packet(&mut self, packet: &SoupPacket) -> Result<(), OuchError> {
        self.stream.write_all(&packet.encode()?).await?;
        self.stream.flush().await?;
        Ok(())
    }

    async fn receive_packet(&mut self) -> Result<SoupPacket, OuchError> {
        let length = self.stream.read_u16().await?;
        if length == 0 {
            return Err(ProtocolError::InvalidLength.into());
        }
        let mut body = vec![0_u8; usize::from(length)];
        self.stream.read_exact(&mut body).await?;
        let mut frame = BytesMut::with_capacity(body.len() + 2);
        frame.put_u16(length);
        frame.extend_from_slice(&body);
        Ok(SoupPacket::decode(&frame)?)
    }
}

pub struct OuchSession<T> {
    transport: T,
    config: SessionConfig,
    state: SessionState,
}

impl<T: OuchTransport> OuchSession<T> {
    #[must_use]
    pub fn new(transport: T, config: SessionConfig) -> Self {
        Self {
            transport,
            config,
            state: SessionState::Disconnected,
        }
    }

    #[must_use]
    pub fn state(&self) -> SessionState {
        self.state
    }

    pub async fn login(&mut self) -> Result<(), OuchError> {
        self.state = SessionState::Authenticating;
        let login = SoupPacket {
            packet_type: b'L',
            payload: encode_login(&self.config),
        };
        timeout(self.config.io_timeout, self.transport.send_packet(&login))
            .await
            .map_err(|_| OuchError::Timeout)??;
        let response = timeout(self.config.io_timeout, self.transport.receive_packet())
            .await
            .map_err(|_| OuchError::Timeout)??;
        match response.packet_type {
            b'A' => {
                self.state = SessionState::Active;
                Ok(())
            }
            b'J' => {
                self.state = SessionState::Disconnected;
                Err(OuchError::LoginRejected)
            }
            packet_type => {
                self.state = SessionState::Disconnected;
                Err(OuchError::UnexpectedPacket(packet_type))
            }
        }
    }

    pub async fn send_intent(&mut self, intent: &OrderIntent) -> Result<(), OuchError> {
        if self.state != SessionState::Active {
            return Err(OuchError::NotActive);
        }
        let packet = SoupPacket {
            packet_type: b'U',
            payload: encode_enter_order(intent)?,
        };
        timeout(self.config.io_timeout, self.transport.send_packet(&packet))
            .await
            .map_err(|_| OuchError::Timeout)??;
        Ok(())
    }

    pub async fn heartbeat(&mut self) -> Result<(), OuchError> {
        if self.state != SessionState::Active {
            return Err(OuchError::NotActive);
        }
        timeout(
            self.config.io_timeout,
            self.transport.send_packet(&SoupPacket {
                packet_type: b'R',
                payload: Bytes::new(),
            }),
        )
        .await
        .map_err(|_| OuchError::Timeout)??;
        Ok(())
    }

    pub fn into_inner(self) -> T {
        self.transport
    }
}

fn encode_login(config: &SessionConfig) -> Bytes {
    let mut payload = BytesMut::with_capacity(46);
    payload.extend_from_slice(&config.username);
    payload.extend_from_slice(&config.password);
    payload.extend_from_slice(&config.session);
    let sequence = format!("{:020}", config.sequence);
    payload.extend_from_slice(sequence.as_bytes());
    payload.freeze()
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use mockall::mock;

    use super::*;

    mock! {
        pub Transport {}

        #[async_trait]
        impl OuchTransport for Transport {
            async fn send_packet(&mut self, packet: &SoupPacket)
                -> Result<(), OuchError>;
            async fn receive_packet(&mut self) -> Result<SoupPacket, OuchError>;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn logs_in_and_sends_order() {
        let mut transport = MockTransport::new();
        transport
            .expect_send_packet()
            .withf(|packet| packet.packet_type == b'L')
            .once()
            .returning(|_| Ok(()));
        transport.expect_receive_packet().once().returning(|| {
            Ok(SoupPacket {
                packet_type: b'A',
                payload: Bytes::new(),
            })
        });
        transport
            .expect_send_packet()
            .withf(|packet| packet.packet_type == b'U' && packet.payload[0] == b'O')
            .once()
            .returning(|_| Ok(()));

        let mut session = OuchSession::new(transport, SessionConfig::default());
        assert!(session.login().await.is_ok());
        assert_eq!(session.state(), SessionState::Active);
        let intent = OrderIntent {
            action: hft_protocol::OrderAction::Enter,
            side: hft_protocol::Side::Buy,
            symbol: *b"ACME    ",
            price: 100,
            quantity: 5,
            ..OrderIntent::default()
        };
        assert!(session.send_intent(&intent).await.is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn rejects_order_before_login() {
        let transport = MockTransport::new();
        let mut session = OuchSession::new(transport, SessionConfig::default());
        let result = session.send_intent(&OrderIntent::default()).await;
        assert!(matches!(result, Err(OuchError::NotActive)));
    }
}
