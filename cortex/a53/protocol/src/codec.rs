//! `tokio-util` codecs for the two byte streams the A53 speaks.
//!
//! Framed readers built on these codecs are cancel-safe: a frame leaves the
//! read buffer only once it is complete, so `select!` may drop a pending read
//! without losing bytes or desynchronizing the stream.

use bytes::{Buf, BytesMut};
use thiserror::Error;
use tokio_util::codec::{Decoder, Encoder};

use crate::{ProtocolError, SoupPacket, generated};

/// Stream framing failure: transport I/O or an invalid frame.
#[derive(Debug, Error)]
pub enum FrameError {
    /// The underlying stream failed.
    #[error("stream I/O failed: {0}")]
    Io(#[from] std::io::Error),
    /// The bytes do not form a valid frame.
    #[error("invalid frame: {0}")]
    Protocol(#[from] ProtocolError),
}

/// One 64-byte IPC record (`rpmsg_char` message or Unix-socket frame).
pub type IpcFrame = [u8; generated::IPC_RECORD_SIZE];

/// Fixed-size record framing for Unix-socket RPMsg stand-ins.
#[derive(Clone, Copy, Debug, Default)]
pub struct RecordCodec;

impl Decoder for RecordCodec {
    type Item = IpcFrame;
    type Error = std::io::Error;

    fn decode(&mut self, source: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        let Some(frame) = source
            .first_chunk::<{ generated::IPC_RECORD_SIZE }>()
            .copied()
        else {
            source.reserve(generated::IPC_RECORD_SIZE);
            return Ok(None);
        };
        source.advance(generated::IPC_RECORD_SIZE);
        Ok(Some(frame))
    }
}

impl Encoder<IpcFrame> for RecordCodec {
    type Error = std::io::Error;

    fn encode(&mut self, item: IpcFrame, destination: &mut BytesMut) -> Result<(), Self::Error> {
        destination.extend_from_slice(&item);
        Ok(())
    }
}

/// Upper bound on one SoupBinTCP frame accepted from the network.
pub const MAX_SOUP_FRAME: usize = 4 * 1024;

/// SoupBinTCP framing: a big-endian u16 length, then type byte and payload.
#[derive(Clone, Copy, Debug, Default)]
pub struct SoupCodec;

impl Decoder for SoupCodec {
    type Item = SoupPacket;
    type Error = FrameError;

    fn decode(&mut self, source: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        let Some(length) = source.first_chunk::<2>() else {
            return Ok(None);
        };
        let body_len = usize::from(u16::from_be_bytes(*length));
        if body_len == 0 || body_len > MAX_SOUP_FRAME {
            return Err(ProtocolError::InvalidLength.into());
        }
        if source.len() < body_len + 2 {
            source.reserve(body_len + 2 - source.len());
            return Ok(None);
        }
        source.advance(2);
        let mut body = source.split_to(body_len);
        let packet_type = body.get_u8();
        // split_to + freeze hands the payload out without copying it.
        Ok(Some(SoupPacket {
            packet_type,
            payload: body.freeze(),
        }))
    }
}

impl Encoder<SoupPacket> for SoupCodec {
    type Error = FrameError;

    fn encode(&mut self, item: SoupPacket, destination: &mut BytesMut) -> Result<(), Self::Error> {
        Ok(item.encode_into(destination)?)
    }
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, reason = "tests index fixed fixtures")]
mod tests {
    use bytes::Bytes;

    use super::*;

    #[test]
    fn soup_codec_waits_for_complete_frames() {
        let mut codec = SoupCodec;
        let frame = SoupPacket {
            packet_type: b'S',
            payload: Bytes::from_static(b"A\0\0\0\x07"),
        }
        .encode()
        .unwrap_or_default();
        let mut buffer = BytesMut::from(&frame[..3]);
        assert!(matches!(codec.decode(&mut buffer), Ok(None)));
        buffer.extend_from_slice(&frame[3..]);
        let decoded = codec.decode(&mut buffer).ok().flatten();
        assert_eq!(decoded.map(|packet| packet.packet_type), Some(b'S'));
        assert!(buffer.is_empty());
    }

    #[test]
    fn soup_codec_rejects_oversized_frames() {
        let mut codec = SoupCodec;
        let mut buffer = BytesMut::from(&[0xFF_u8, 0xFF][..]);
        assert!(matches!(
            codec.decode(&mut buffer),
            Err(FrameError::Protocol(ProtocolError::InvalidLength))
        ));
    }

    #[test]
    fn record_codec_splits_concatenated_records() {
        let mut codec = RecordCodec;
        let mut buffer = BytesMut::from(&[1_u8; 100][..]);
        assert!(codec.decode(&mut buffer).ok().flatten().is_some());
        assert!(codec.decode(&mut buffer).ok().flatten().is_none());
        assert_eq!(buffer.len(), 36);
    }
}
