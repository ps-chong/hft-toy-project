//! Zero-allocation MoldUDP64 framing.
//!
//! [`MoldPacket::parse`] validates every length prefix once, up front, so
//! [`MoldMessages`] can then yield borrowed message slices without
//! allocating and without a failure path.

use crate::{ProtocolError, generated};

/// Validated MoldUDP64 packet borrowing the datagram.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MoldPacket<'a> {
    /// Session identifier.
    pub session: [u8; 10],
    /// Sequence number of the first message.
    pub sequence: u64,
    count: u16,
    body: &'a [u8],
}

/// Count value MoldUDP64 uses to mark end of session.
pub const END_OF_SESSION: u16 = u16::MAX;

impl<'a> MoldPacket<'a> {
    /// Validates the header and every message block.
    pub fn parse(packet: &'a [u8]) -> Result<Self, ProtocolError> {
        let (header, body) = packet
            .split_first_chunk::<{ generated::MOLDUDP64_HEADER_SIZE }>()
            .ok_or(ProtocolError::Truncated)?;
        let (session, rest) = header
            .split_first_chunk::<10>()
            .ok_or(ProtocolError::Truncated)?;
        let (sequence, rest) = rest
            .split_first_chunk::<8>()
            .ok_or(ProtocolError::Truncated)?;
        let (count, _) = rest
            .split_first_chunk::<2>()
            .ok_or(ProtocolError::Truncated)?;
        let count = u16::from_be_bytes(*count);
        let parsed = Self {
            session: *session,
            sequence: u64::from_be_bytes(*sequence),
            count,
            body,
        };
        if count == END_OF_SESSION {
            return Ok(Self {
                body: &[],
                ..parsed
            });
        }
        let mut remaining = body;
        for _ in 0..count {
            remaining = split_message(remaining)?.1;
        }
        if !remaining.is_empty() {
            return Err(ProtocolError::MessageCount);
        }
        Ok(parsed)
    }

    /// Number of messages in the packet (0 for heartbeats and end of session).
    #[must_use]
    pub fn message_count(&self) -> usize {
        if self.count == END_OF_SESSION {
            0
        } else {
            usize::from(self.count)
        }
    }

    /// True for heartbeats (no messages).
    #[must_use]
    pub fn is_heartbeat(&self) -> bool {
        self.count == 0
    }

    /// True for the end-of-session marker.
    #[must_use]
    pub fn is_end_of_session(&self) -> bool {
        self.count == END_OF_SESSION
    }

    /// Borrowed message slices in order.
    #[must_use]
    pub fn messages(&self) -> MoldMessages<'a> {
        MoldMessages {
            remaining: self.body,
            left: self.message_count(),
        }
    }
}

/// Iterator over the messages of a validated [`MoldPacket`].
#[derive(Clone, Debug)]
pub struct MoldMessages<'a> {
    remaining: &'a [u8],
    left: usize,
}

impl<'a> Iterator for MoldMessages<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<Self::Item> {
        if self.left == 0 {
            return None;
        }
        let (message, rest) = split_message(self.remaining).ok()?;
        self.remaining = rest;
        self.left -= 1;
        Some(message)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.left, Some(self.left))
    }
}

impl ExactSizeIterator for MoldMessages<'_> {}

fn split_message(block: &[u8]) -> Result<(&[u8], &[u8]), ProtocolError> {
    let (length, rest) = block
        .split_first_chunk::<2>()
        .ok_or(ProtocolError::Truncated)?;
    let length = usize::from(u16::from_be_bytes(*length));
    if length == 0 {
        return Err(ProtocolError::InvalidLength);
    }
    if rest.len() < length {
        return Err(ProtocolError::Truncated);
    }
    Ok(rest.split_at(length))
}

#[cfg(test)]
#[allow(clippy::indexing_slicing, reason = "tests index fixed fixtures")]
mod tests {
    use super::*;

    #[test]
    fn heartbeat_and_end_of_session_have_no_messages() {
        let mut heartbeat = b"SESSION001".to_vec();
        heartbeat.extend_from_slice(&5_u64.to_be_bytes());
        heartbeat.extend_from_slice(&0_u16.to_be_bytes());
        let packet = MoldPacket::parse(&heartbeat).unwrap_or_else(|error| panic!("{error}"));
        assert!(packet.is_heartbeat());
        assert_eq!(packet.messages().count(), 0);

        let mut end = heartbeat.clone();
        end[18..20].copy_from_slice(&END_OF_SESSION.to_be_bytes());
        let packet = MoldPacket::parse(&end).unwrap_or_else(|error| panic!("{error}"));
        assert!(packet.is_end_of_session());
        assert_eq!(packet.message_count(), 0);
    }

    #[test]
    fn rejects_zero_length_and_trailing_bytes() {
        let mut packet = b"SESSION001".to_vec();
        packet.extend_from_slice(&1_u64.to_be_bytes());
        packet.extend_from_slice(&1_u16.to_be_bytes());
        packet.extend_from_slice(&0_u16.to_be_bytes());
        assert_eq!(
            MoldPacket::parse(&packet),
            Err(ProtocolError::InvalidLength)
        );

        let mut trailing = b"SESSION001".to_vec();
        trailing.extend_from_slice(&1_u64.to_be_bytes());
        trailing.extend_from_slice(&1_u16.to_be_bytes());
        trailing.extend_from_slice(&1_u16.to_be_bytes());
        trailing.extend_from_slice(b"Sx");
        assert_eq!(
            MoldPacket::parse(&trailing),
            Err(ProtocolError::MessageCount)
        );
    }
}
