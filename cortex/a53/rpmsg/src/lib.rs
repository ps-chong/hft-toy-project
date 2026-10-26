//! RPMsg endpoints between the A53 daemon and the R5 firmware.
//!
//! [`RpmsgEndpoint`] is the single owner of one channel. Receiving is
//! cancel-safe on both variants, so the owning task can `select!` between
//! inbound intents and outbound configuration without losing or splitting a
//! record:
//!
//! * [`RpmsgEndpoint::Device`]: Linux `rpmsg_char`, where each `read` returns
//!   exactly one message. The file is opened `O_NONBLOCK` and driven by
//!   `AsyncFd`, so no blocking-pool thread is involved.
//! * [`RpmsgEndpoint::Unix`]: a Unix stream stand-in used by the host demo,
//!   framed in 64-byte records by [`RecordCodec`].

use std::{
    fs::{File, OpenOptions},
    future::Future,
    io::{self, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

use futures_util::{SinkExt, StreamExt};
use hft_protocol::{
    MarketEvent, OrderIntent, ProtocolError, RiskConfigRecord, codec::RecordCodec, generated,
};
use thiserror::Error;
use tokio::{
    io::unix::AsyncFd,
    net::{
        UnixStream,
        unix::{OwnedReadHalf, OwnedWriteHalf},
    },
};
use tokio_util::codec::{FramedRead, FramedWrite};

/// RPMsg failures. Every variant is fatal for the endpoint: the daemon fails
/// closed rather than guessing at a desynchronized stream.
#[derive(Debug, Error)]
pub enum RpmsgError {
    /// The device or socket failed.
    #[error("RPMsg I/O failed: {0}")]
    Io(#[from] io::Error),
    /// A record failed validation.
    #[error("RPMsg record failed validation: {0}")]
    Protocol(#[from] ProtocolError),
    /// The peer speaks a different IPC ABI.
    #[error("remote ABI {remote} does not match local ABI {local}")]
    AbiMismatch {
        /// ABI found in the record.
        remote: u16,
        /// ABI this build speaks.
        local: u16,
    },
    /// The peer closed the channel.
    #[error("RPMsg peer closed the channel")]
    Closed,
    /// `rpmsg_char` returned a message that is not one IPC record.
    #[error("RPMsg message has {0} bytes, expected one IPC record")]
    MessageSize(usize),
}

/// Operations the daemon needs from the channel to the R5.
pub trait RpmsgTransport: Send {
    /// Next approved intent from the R5. Must be cancel-safe.
    fn receive_intent(&mut self) -> impl Future<Output = Result<OrderIntent, RpmsgError>> + Send;
    /// Sends one control snapshot to the R5.
    fn send_config(
        &mut self,
        config: &RiskConfigRecord,
    ) -> impl Future<Output = Result<(), RpmsgError>> + Send;
    /// Sends one normalized market event (software feed path).
    fn send_event(
        &mut self,
        event: &MarketEvent,
    ) -> impl Future<Output = Result<(), RpmsgError>> + Send;
}

/// Linux `rpmsg_char` device driven by `AsyncFd`.
pub struct DeviceRpmsg {
    path: PathBuf,
    file: AsyncFd<File>,
}

impl DeviceRpmsg {
    /// Opens the character device for non-blocking reads and writes.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, RpmsgError> {
        let path = path.as_ref().to_path_buf();
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&path)?;
        // Tokio 1.54 deprecated the safe constructors (RUSTSEC-2026-0386) in
        // favor of `unsafe fn register`, whose contract is that the descriptor
        // stays open and unchanged while the AsyncFd lives. A `File` owned by
        // the AsyncFd guarantees exactly that, and this crate forbids unsafe.
        #[allow(
            deprecated,
            reason = "an owned File satisfies AsyncFd::register's contract"
        )]
        let file = AsyncFd::new(file)?;
        Ok(Self { path, file })
    }

    /// Device path.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    async fn read_record(&self) -> Result<[u8; generated::IPC_RECORD_SIZE], RpmsgError> {
        let mut record = [0_u8; generated::IPC_RECORD_SIZE];
        loop {
            // Cancelling here consumes nothing: readiness is only a hint.
            let mut guard = self.file.readable().await?;
            match guard.try_io(|inner| inner.get_ref().read(&mut record)) {
                Ok(Ok(0)) => return Err(RpmsgError::Closed),
                Ok(Ok(length)) if length == record.len() => return Ok(record),
                Ok(Ok(length)) => return Err(RpmsgError::MessageSize(length)),
                Ok(Err(error)) => return Err(error.into()),
                Err(_would_block) => {}
            }
        }
    }

    async fn write_record(
        &self,
        record: &[u8; generated::IPC_RECORD_SIZE],
    ) -> Result<(), RpmsgError> {
        loop {
            let mut guard = self.file.writable().await?;
            match guard.try_io(|inner| inner.get_ref().write(record)) {
                Ok(Ok(length)) if length == record.len() => return Ok(()),
                Ok(Ok(length)) => return Err(RpmsgError::MessageSize(length)),
                Ok(Err(error)) => return Err(error.into()),
                Err(_would_block) => {}
            }
        }
    }
}

/// Unix-stream stand-in for `rpmsg_char` (host demo and tests).
pub struct UnixRpmsg {
    reader: FramedRead<OwnedReadHalf, RecordCodec>,
    writer: FramedWrite<OwnedWriteHalf, RecordCodec>,
}

impl UnixRpmsg {
    /// Wraps a connected stream.
    #[must_use]
    pub fn new(stream: UnixStream) -> Self {
        let (reader, writer) = stream.into_split();
        Self {
            reader: FramedRead::new(reader, RecordCodec),
            writer: FramedWrite::new(writer, RecordCodec),
        }
    }

    /// Connects to a listening R5 model.
    pub async fn connect(path: impl AsRef<Path>) -> Result<Self, RpmsgError> {
        Ok(Self::new(UnixStream::connect(path).await?))
    }
}

/// The daemon's one RPMsg channel.
pub enum RpmsgEndpoint {
    /// Hardware `rpmsg_char` device.
    Device(DeviceRpmsg),
    /// Unix-socket stand-in.
    Unix(UnixRpmsg),
}

impl RpmsgEndpoint {
    /// Opens `spec`: `unix:/path` connects to a socket, anything else is a
    /// device path.
    pub async fn open(spec: &str) -> Result<Self, RpmsgError> {
        match spec.strip_prefix("unix:") {
            Some(path) => Ok(Self::Unix(UnixRpmsg::connect(path).await?)),
            None => Ok(Self::Device(DeviceRpmsg::open(spec)?)),
        }
    }

    async fn read_record(&mut self) -> Result<[u8; generated::IPC_RECORD_SIZE], RpmsgError> {
        match self {
            Self::Device(device) => device.read_record().await,
            // FramedRead::next is cancel-safe: partial frames stay buffered.
            Self::Unix(unix) => unix
                .reader
                .next()
                .await
                .ok_or(RpmsgError::Closed)?
                .map_err(Into::into),
        }
    }

    async fn write_record(
        &mut self,
        record: [u8; generated::IPC_RECORD_SIZE],
    ) -> Result<(), RpmsgError> {
        match self {
            Self::Device(device) => device.write_record(&record).await,
            Self::Unix(unix) => unix.writer.send(record).await.map_err(Into::into),
        }
    }
}

fn check_abi(remote: u16) -> Result<(), RpmsgError> {
    if remote == generated::ABI_VERSION {
        Ok(())
    } else {
        Err(RpmsgError::AbiMismatch {
            remote,
            local: generated::ABI_VERSION,
        })
    }
}

impl RpmsgTransport for RpmsgEndpoint {
    async fn receive_intent(&mut self) -> Result<OrderIntent, RpmsgError> {
        let record = self.read_record().await?;
        let intent = OrderIntent::decode_ipc(&record)?;
        check_abi(intent.abi_version)?;
        Ok(intent)
    }

    async fn send_config(&mut self, config: &RiskConfigRecord) -> Result<(), RpmsgError> {
        check_abi(config.abi_version)?;
        self.write_record(config.encode_ipc()).await
    }

    async fn send_event(&mut self, event: &MarketEvent) -> Result<(), RpmsgError> {
        check_abi(event.abi_version)?;
        self.write_record(event.encode_ipc()).await
    }
}

#[cfg(test)]
mod tests {
    use futures_util::{SinkExt, StreamExt};
    use hft_protocol::{OrderAction, Side};
    use tokio::io::AsyncWriteExt;
    use tokio_util::codec::Framed;

    use super::*;

    #[tokio::test]
    async fn unix_endpoint_round_trips_records() {
        let (local, remote) = UnixStream::pair().unwrap();
        let mut endpoint = RpmsgEndpoint::Unix(UnixRpmsg::new(local));
        let mut r5 = Framed::new(remote, RecordCodec);

        let intent = OrderIntent {
            action: OrderAction::Enter,
            side: Side::Buy,
            user_ref: 42,
            ..OrderIntent::default()
        };
        r5.send(intent.encode_ipc()).await.unwrap();
        assert_eq!(endpoint.receive_intent().await.unwrap(), intent);

        let config = RiskConfigRecord {
            revision: 9,
            ..RiskConfigRecord::default()
        };
        endpoint.send_config(&config).await.unwrap();
        let echoed = r5.next().await.unwrap().unwrap();
        assert_eq!(RiskConfigRecord::decode_ipc(&echoed).unwrap(), config);
    }

    #[tokio::test]
    async fn receive_is_cancel_safe_across_split_frames() {
        let (local, mut remote) = UnixStream::pair().unwrap();
        let mut endpoint = RpmsgEndpoint::Unix(UnixRpmsg::new(local));
        let image = OrderIntent {
            user_ref: 5,
            ..OrderIntent::default()
        }
        .encode_ipc();

        remote.write_all(&image[..20]).await.unwrap();
        // A select! branch that loses mid-frame must not discard those bytes.
        tokio::select! {
            biased;
            () = tokio::time::sleep(std::time::Duration::from_millis(20)) => {}
            _ = endpoint.receive_intent() => panic!("frame was incomplete"),
        }
        remote.write_all(&image[20..]).await.unwrap();
        assert_eq!(endpoint.receive_intent().await.unwrap().user_ref, 5);
    }

    #[tokio::test]
    async fn rejects_foreign_abi() {
        let (local, remote) = UnixStream::pair().unwrap();
        let mut endpoint = RpmsgEndpoint::Unix(UnixRpmsg::new(local));
        let mut r5 = Framed::new(remote, RecordCodec);
        let mut image = OrderIntent::default().encode_ipc();
        image[0] = 99;
        r5.send(image).await.unwrap();
        assert!(matches!(
            endpoint.receive_intent().await,
            Err(RpmsgError::AbiMismatch { remote: 99, .. })
        ));
    }
}
