//! Async ownership wrapper for Linux `rpmsg_char` endpoints.

use std::{
    io,
    path::{Path, PathBuf},
};

use async_trait::async_trait;
use hft_protocol::{MarketEvent, OrderIntent, ProtocolError, generated};
use thiserror::Error;
use tokio::{
    fs::{File, OpenOptions},
    io::{AsyncReadExt, AsyncWriteExt},
};

#[derive(Debug, Error)]
pub enum RpmsgError {
    #[error("RPMsg I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("RPMsg record failed validation: {0}")]
    Protocol(#[from] ProtocolError),
    #[error("remote ABI {remote} does not match local ABI {local}")]
    AbiMismatch { remote: u16, local: u16 },
}

#[async_trait]
pub trait RpmsgTransport: Send {
    async fn receive_intent(&mut self) -> Result<OrderIntent, RpmsgError>;
    async fn send_event(&mut self, event: &MarketEvent) -> Result<(), RpmsgError>;
}

pub struct FileRpmsg {
    path: PathBuf,
    file: File,
}

impl FileRpmsg {
    pub async fn open(path: impl AsRef<Path>) -> Result<Self, RpmsgError> {
        let path = path.as_ref().to_path_buf();
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .await?;
        Ok(Self { path, file })
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[async_trait]
impl RpmsgTransport for FileRpmsg {
    async fn receive_intent(&mut self) -> Result<OrderIntent, RpmsgError> {
        let mut record = [0_u8; generated::IPC_RECORD_SIZE];
        self.file.read_exact(&mut record).await?;
        let intent = OrderIntent::decode_ipc(&record)?;
        if intent.abi_version != generated::ABI_VERSION {
            return Err(RpmsgError::AbiMismatch {
                remote: intent.abi_version,
                local: generated::ABI_VERSION,
            });
        }
        Ok(intent)
    }

    async fn send_event(&mut self, event: &MarketEvent) -> Result<(), RpmsgError> {
        if event.abi_version != generated::ABI_VERSION {
            return Err(RpmsgError::AbiMismatch {
                remote: event.abi_version,
                local: generated::ABI_VERSION,
            });
        }
        self.file.write_all(&event.encode_ipc()).await?;
        self.file.flush().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use async_trait::async_trait;
    use mockall::mock;

    use super::*;

    mock! {
        pub Channel {}

        #[async_trait]
        impl RpmsgTransport for Channel {
            async fn receive_intent(&mut self) -> Result<OrderIntent, RpmsgError>;
            async fn send_event(
                &mut self,
                event: &MarketEvent,
            ) -> Result<(), RpmsgError>;
        }
    }

    #[tokio::test]
    async fn mockall_models_owned_channel_boundary() {
        let mut channel = MockChannel::new();
        channel.expect_receive_intent().once().returning(|| {
            Ok(OrderIntent {
                source_sequence: 42,
                ..OrderIntent::default()
            })
        });

        let intent = channel.receive_intent().await;
        assert!(intent.is_ok());
        let intent = intent.unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(intent.source_sequence, 42);
    }
}
