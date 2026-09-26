//! Endian-explicit wire and IPC contracts shared with PL and R5.

use std::{array::TryFromSliceError, mem::size_of};

use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub mod generated {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../protocol/generated/rust/protocol_generated.rs"
    ));
}

pub const SYMBOL_LEN: usize = 8;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[repr(u8)]
pub enum EventKind {
    #[default]
    None = 0,
    Add = b'A',
    Execute = b'E',
    Cancel = b'X',
    Delete = b'D',
    Replace = b'U',
    Trade = b'P',
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[repr(u8)]
pub enum Side {
    #[default]
    Unknown = 0,
    Buy = b'B',
    Sell = b'S',
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[repr(u8)]
pub enum OrderAction {
    #[default]
    None = 0,
    Enter = b'O',
    Replace = b'U',
    Cancel = b'X',
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[repr(C, align(64))]
pub struct MarketEvent {
    pub abi_version: u16,
    pub kind: EventKind,
    pub side: Side,
    pub flags: u32,
    pub sequence: u64,
    pub timestamp_ns: u64,
    pub order_reference: u64,
    pub symbol: [u8; SYMBOL_LEN],
    pub price: u64,
    pub quantity: u32,
    pub reserved: [u8; 12],
}

impl Default for MarketEvent {
    fn default() -> Self {
        Self {
            abi_version: generated::ABI_VERSION,
            kind: EventKind::None,
            side: Side::Unknown,
            flags: 0,
            sequence: 0,
            timestamp_ns: 0,
            order_reference: 0,
            symbol: [0; SYMBOL_LEN],
            price: 0,
            quantity: 0,
            reserved: [0; 12],
        }
    }
}

impl MarketEvent {
    #[must_use]
    pub fn encode_ipc(&self) -> [u8; generated::IPC_RECORD_SIZE] {
        let mut output = [0_u8; generated::IPC_RECORD_SIZE];
        output[0..2].copy_from_slice(&self.abi_version.to_le_bytes());
        output[2] = self.kind as u8;
        output[3] = self.side as u8;
        output[4..8].copy_from_slice(&self.flags.to_le_bytes());
        output[8..16].copy_from_slice(&self.sequence.to_le_bytes());
        output[16..24].copy_from_slice(&self.timestamp_ns.to_le_bytes());
        output[24..32].copy_from_slice(&self.order_reference.to_le_bytes());
        output[32..40].copy_from_slice(&self.symbol);
        output[40..48].copy_from_slice(&self.price.to_le_bytes());
        output[48..52].copy_from_slice(&self.quantity.to_le_bytes());
        output[52..64].copy_from_slice(&self.reserved);
        output
    }

    pub fn decode_ipc(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() != generated::IPC_RECORD_SIZE {
            return Err(ProtocolError::InvalidLength);
        }
        Ok(Self {
            abi_version: u16::from_le_bytes(input[0..2].try_into()?),
            kind: decode_event_kind(input[2])?,
            side: decode_side(input[3])?,
            flags: u32::from_le_bytes(input[4..8].try_into()?),
            sequence: u64::from_le_bytes(input[8..16].try_into()?),
            timestamp_ns: u64::from_le_bytes(input[16..24].try_into()?),
            order_reference: u64::from_le_bytes(input[24..32].try_into()?),
            symbol: input[32..40].try_into()?,
            price: u64::from_le_bytes(input[40..48].try_into()?),
            quantity: u32::from_le_bytes(input[48..52].try_into()?),
            reserved: input[52..64].try_into()?,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[repr(C, align(64))]
pub struct OrderIntent {
    pub abi_version: u16,
    pub action: OrderAction,
    pub side: Side,
    pub user_ref: u32,
    pub source_sequence: u64,
    pub decision_timestamp_ns: u64,
    pub symbol: [u8; SYMBOL_LEN],
    pub price: u64,
    pub quantity: u32,
    pub risk_revision: u32,
    pub reserved: [u8; 16],
}

impl Default for OrderIntent {
    fn default() -> Self {
        Self {
            abi_version: generated::ABI_VERSION,
            action: OrderAction::None,
            side: Side::Unknown,
            user_ref: 0,
            source_sequence: 0,
            decision_timestamp_ns: 0,
            symbol: [0; SYMBOL_LEN],
            price: 0,
            quantity: 0,
            risk_revision: 0,
            reserved: [0; 16],
        }
    }
}

impl OrderIntent {
    #[must_use]
    pub fn encode_ipc(&self) -> [u8; generated::IPC_RECORD_SIZE] {
        let mut output = [0_u8; generated::IPC_RECORD_SIZE];
        output[0..2].copy_from_slice(&self.abi_version.to_le_bytes());
        output[2] = self.action as u8;
        output[3] = self.side as u8;
        output[4..8].copy_from_slice(&self.user_ref.to_le_bytes());
        output[8..16].copy_from_slice(&self.source_sequence.to_le_bytes());
        output[16..24].copy_from_slice(&self.decision_timestamp_ns.to_le_bytes());
        output[24..32].copy_from_slice(&self.symbol);
        output[32..40].copy_from_slice(&self.price.to_le_bytes());
        output[40..44].copy_from_slice(&self.quantity.to_le_bytes());
        output[44..48].copy_from_slice(&self.risk_revision.to_le_bytes());
        output[48..64].copy_from_slice(&self.reserved);
        output
    }

    pub fn decode_ipc(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() != generated::IPC_RECORD_SIZE {
            return Err(ProtocolError::InvalidLength);
        }
        Ok(Self {
            abi_version: u16::from_le_bytes(input[0..2].try_into()?),
            action: decode_order_action(input[2])?,
            side: decode_side(input[3])?,
            user_ref: u32::from_le_bytes(input[4..8].try_into()?),
            source_sequence: u64::from_le_bytes(input[8..16].try_into()?),
            decision_timestamp_ns: u64::from_le_bytes(input[16..24].try_into()?),
            symbol: input[24..32].try_into()?,
            price: u64::from_le_bytes(input[32..40].try_into()?),
            quantity: u32::from_le_bytes(input[40..44].try_into()?),
            risk_revision: u32::from_le_bytes(input[44..48].try_into()?),
            reserved: input[48..64].try_into()?,
        })
    }
}

const _: () = assert!(size_of::<MarketEvent>() == generated::IPC_RECORD_SIZE);
const _: () = assert!(size_of::<OrderIntent>() == generated::IPC_RECORD_SIZE);

#[derive(Debug, Error, Eq, PartialEq)]
pub enum ProtocolError {
    #[error("packet is truncated")]
    Truncated,
    #[error("declared length is invalid")]
    InvalidLength,
    #[error("message count does not match payload")]
    MessageCount,
    #[error("unsupported message type {0:#04x}")]
    Unsupported(u8),
    #[error("numeric field conversion failed")]
    Numeric,
}

impl From<TryFromSliceError> for ProtocolError {
    fn from(_: TryFromSliceError) -> Self {
        Self::Numeric
    }
}

fn decode_event_kind(value: u8) -> Result<EventKind, ProtocolError> {
    match value {
        0 => Ok(EventKind::None),
        b'A' => Ok(EventKind::Add),
        b'E' => Ok(EventKind::Execute),
        b'X' => Ok(EventKind::Cancel),
        b'D' => Ok(EventKind::Delete),
        b'U' => Ok(EventKind::Replace),
        b'P' => Ok(EventKind::Trade),
        other => Err(ProtocolError::Unsupported(other)),
    }
}

fn decode_side(value: u8) -> Result<Side, ProtocolError> {
    match value {
        0 => Ok(Side::Unknown),
        b'B' => Ok(Side::Buy),
        b'S' => Ok(Side::Sell),
        other => Err(ProtocolError::Unsupported(other)),
    }
}

fn decode_order_action(value: u8) -> Result<OrderAction, ProtocolError> {
    match value {
        0 => Ok(OrderAction::None),
        b'O' => Ok(OrderAction::Enter),
        b'U' => Ok(OrderAction::Replace),
        b'X' => Ok(OrderAction::Cancel),
        other => Err(ProtocolError::Unsupported(other)),
    }
}

#[derive(Debug, Eq, PartialEq)]
pub struct MoldPacket<'a> {
    pub session: [u8; 10],
    pub sequence: u64,
    pub messages: Vec<&'a [u8]>,
}

impl<'a> MoldPacket<'a> {
    pub fn parse(packet: &'a [u8]) -> Result<Self, ProtocolError> {
        if packet.len() < generated::MOLDUDP64_HEADER_SIZE {
            return Err(ProtocolError::Truncated);
        }
        let session = packet[0..10].try_into()?;
        let sequence = u64::from_be_bytes(packet[10..18].try_into()?);
        let count = usize::from(u16::from_be_bytes(packet[18..20].try_into()?));
        if count == usize::from(u16::MAX) {
            return Ok(Self {
                session,
                sequence,
                messages: Vec::new(),
            });
        }

        let mut messages = Vec::with_capacity(count);
        let mut offset = generated::MOLDUDP64_HEADER_SIZE;
        for _ in 0..count {
            let length_end = offset.checked_add(2).ok_or(ProtocolError::InvalidLength)?;
            let length_bytes = packet
                .get(offset..length_end)
                .ok_or(ProtocolError::Truncated)?;
            let length = usize::from(u16::from_be_bytes(length_bytes.try_into()?));
            if length == 0 {
                return Err(ProtocolError::InvalidLength);
            }
            offset = length_end;
            let message_end = offset
                .checked_add(length)
                .ok_or(ProtocolError::InvalidLength)?;
            messages.push(
                packet
                    .get(offset..message_end)
                    .ok_or(ProtocolError::Truncated)?,
            );
            offset = message_end;
        }
        if offset != packet.len() {
            return Err(ProtocolError::MessageCount);
        }
        Ok(Self {
            session,
            sequence,
            messages,
        })
    }

    #[must_use]
    pub fn is_heartbeat(&self) -> bool {
        self.messages.is_empty()
    }
}

impl MarketEvent {
    pub fn parse_itch(message: &[u8], sequence: u64) -> Result<Self, ProtocolError> {
        let kind = *message.first().ok_or(ProtocolError::Truncated)?;
        let timestamp = read_u48(message.get(5..11).ok_or(ProtocolError::Truncated)?)?;
        let mut event = Self {
            sequence,
            timestamp_ns: timestamp,
            ..Self::default()
        };

        match kind {
            b'A' | b'F' => {
                let required = if kind == b'A' { 36 } else { 40 };
                if message.len() != required {
                    return Err(ProtocolError::InvalidLength);
                }
                event.kind = EventKind::Add;
                event.order_reference = u64::from_be_bytes(message[11..19].try_into()?);
                event.side = match message[19] {
                    b'B' => Side::Buy,
                    b'S' => Side::Sell,
                    value => return Err(ProtocolError::Unsupported(value)),
                };
                event.quantity = u32::from_be_bytes(message[20..24].try_into()?);
                event.symbol.copy_from_slice(&message[24..32]);
                event.price = u64::from(u32::from_be_bytes(message[32..36].try_into()?));
            }
            b'X' => {
                if message.len() != 23 {
                    return Err(ProtocolError::InvalidLength);
                }
                event.kind = EventKind::Cancel;
                event.order_reference = u64::from_be_bytes(message[11..19].try_into()?);
                event.quantity = u32::from_be_bytes(message[19..23].try_into()?);
            }
            b'D' => {
                if message.len() != 19 {
                    return Err(ProtocolError::InvalidLength);
                }
                event.kind = EventKind::Delete;
                event.order_reference = u64::from_be_bytes(message[11..19].try_into()?);
            }
            value => return Err(ProtocolError::Unsupported(value)),
        }
        Ok(event)
    }
}

fn read_u48(bytes: &[u8]) -> Result<u64, ProtocolError> {
    if bytes.len() != 6 {
        return Err(ProtocolError::InvalidLength);
    }
    Ok(bytes
        .iter()
        .fold(0_u64, |value, byte| (value << 8) | u64::from(*byte)))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SoupPacket {
    pub packet_type: u8,
    pub payload: Bytes,
}

impl SoupPacket {
    pub fn encode(&self) -> Result<Bytes, ProtocolError> {
        let body_len = self
            .payload
            .len()
            .checked_add(1)
            .ok_or(ProtocolError::InvalidLength)?;
        let body_len = u16::try_from(body_len).map_err(|_| ProtocolError::InvalidLength)?;
        let mut output = BytesMut::with_capacity(usize::from(body_len) + 2);
        output.put_u16(body_len);
        output.put_u8(self.packet_type);
        output.extend_from_slice(&self.payload);
        Ok(output.freeze())
    }

    pub fn decode(frame: &[u8]) -> Result<Self, ProtocolError> {
        if frame.len() < 3 {
            return Err(ProtocolError::Truncated);
        }
        let body_len = usize::from(u16::from_be_bytes(frame[0..2].try_into()?));
        if body_len == 0 || frame.len() != body_len + 2 {
            return Err(ProtocolError::InvalidLength);
        }
        Ok(Self {
            packet_type: frame[2],
            payload: Bytes::copy_from_slice(&frame[3..]),
        })
    }
}

pub fn encode_enter_order(intent: &OrderIntent) -> Result<Bytes, ProtocolError> {
    if intent.action != OrderAction::Enter {
        return Err(ProtocolError::Unsupported(intent.action as u8));
    }
    let mut payload = BytesMut::with_capacity(27);
    payload.put_u8(OrderAction::Enter as u8);
    payload.put_u32(intent.user_ref);
    payload.put_u8(intent.side as u8);
    payload.put_u32(intent.quantity);
    payload.extend_from_slice(&intent.symbol);
    payload.put_u64(intent.price);
    payload.put_u8(0);
    Ok(payload.freeze())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ADD_VECTOR: &[u8] = include_bytes!("../../../../protocol/vectors/mold_add_order.bin");
    const TRUNCATED_VECTOR: &[u8] =
        include_bytes!("../../../../protocol/vectors/mold_truncated.bin");

    #[test]
    fn parses_shared_add_vector() {
        let packet = MoldPacket::parse(ADD_VECTOR);
        assert!(packet.is_ok());
        let packet = packet.unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(packet.sequence, 1);
        assert_eq!(packet.messages.len(), 1);

        let event = MarketEvent::parse_itch(packet.messages[0], packet.sequence);
        assert!(event.is_ok());
        let event = event.unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(event.kind, EventKind::Add);
        assert_eq!(event.side, Side::Buy);
        assert_eq!(event.quantity, 100);
        assert_eq!(event.price, 1_234_500);
        assert_eq!(&event.symbol, b"ACME    ");
    }

    #[test]
    fn rejects_truncated_shared_vector() {
        assert_eq!(
            MoldPacket::parse(TRUNCATED_VECTOR),
            Err(ProtocolError::Truncated)
        );
    }

    #[test]
    fn soup_round_trip() {
        let packet = SoupPacket {
            packet_type: b'U',
            payload: Bytes::from_static(b"order"),
        };
        let encoded = packet.encode().unwrap_or_else(|error| panic!("{error}"));
        assert_eq!(
            SoupPacket::decode(&encoded).unwrap_or_else(|error| panic!("{error}")),
            packet
        );
    }
}
