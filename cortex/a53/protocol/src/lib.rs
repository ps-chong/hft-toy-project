//! Endian-explicit wire and IPC contracts shared with the PL and the R5.
//!
//! Every item is a plain value type or a pure codec: no I/O, no shared
//! mutable state, and no `unsafe`, so all of it is `Send + Sync` and free of
//! data races. IPC layouts and codecs are generated from
//! `protocol/schema/ipc.yaml`; see [`generated`].

pub mod codec;
pub mod control;
pub mod itch;
pub mod mold;

use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub use itch::ItchMessage;
pub use mold::{MoldMessages, MoldPacket};

/// Constants, offsets, and IPC codecs generated from `protocol/schema`.
#[allow(missing_docs, clippy::pedantic, reason = "generated from the schema")]
pub mod generated {
    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../protocol/generated/rust/protocol_generated.rs"
    ));
}

/// Width of an ITCH/OUCH stock symbol (space padded).
pub const SYMBOL_LEN: usize = 8;

/// Errors for every wire and IPC decoder in this crate.
#[derive(Debug, Error, Eq, PartialEq)]
pub enum ProtocolError {
    /// Fewer bytes than the header or declared length requires.
    #[error("packet is truncated")]
    Truncated,
    /// A length field or frame length is inconsistent.
    #[error("declared length is invalid")]
    InvalidLength,
    /// The MoldUDP64 message count does not match the payload.
    #[error("message count does not match payload")]
    MessageCount,
    /// An enum byte or message type outside the supported set.
    #[error("unsupported message type {0:#04x}")]
    Unsupported(u8),
}

macro_rules! wire_enum {
    ($(#[$meta:meta])* $name:ident { $($(#[$variant_meta:meta])* $variant:ident = $value:expr),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Hash, Serialize, Deserialize)]
        #[repr(u8)]
        pub enum $name {
            $($(#[$variant_meta])* $variant = $value),+
        }

        impl TryFrom<u8> for $name {
            type Error = ProtocolError;

            fn try_from(value: u8) -> Result<Self, Self::Error> {
                match value {
                    $(v if v == $value => Ok(Self::$variant),)+
                    other => Err(ProtocolError::Unsupported(other)),
                }
            }
        }
    };
}

wire_enum! {
    /// Normalized market event kind (ITCH message types after normalization).
    EventKind {
        /// No event.
        #[default]
        None = 0,
        /// New displayed order (ITCH `A` and `F`).
        Add = b'A',
        /// Execution against a resting order (ITCH `E` and `C`).
        Execute = b'E',
        /// Partial cancel (ITCH `X`).
        Cancel = b'X',
        /// Full delete (ITCH `D`).
        Delete = b'D',
        /// Replace with a new reference (ITCH `U`).
        Replace = b'U',
        /// Non-displayed trade (ITCH `P`).
        Trade = b'P',
    }
}

wire_enum! {
    /// Order side.
    Side {
        /// Not set.
        #[default]
        Unknown = 0,
        /// Buy.
        Buy = b'B',
        /// Sell.
        Sell = b'S',
    }
}

wire_enum! {
    /// Requested order action.
    OrderAction {
        /// Not set.
        #[default]
        None = 0,
        /// Enter a new order.
        Enter = b'O',
        /// Replace an order.
        Replace = b'U',
        /// Cancel an order.
        Cancel = b'X',
    }
}

/// Normalized market event, PL/A53 -> R5 (`normalized_event` in ipc.yaml).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[repr(C, align(64))]
pub struct MarketEvent {
    /// Must equal [`generated::ABI_VERSION`].
    pub abi_version: u16,
    /// Normalized kind.
    pub kind: EventKind,
    /// Side for adds and trades.
    pub side: Side,
    /// Reserved flag bits.
    pub flags: u32,
    /// MoldUDP64 sequence of the source message.
    pub sequence: u64,
    /// ITCH timestamp (nanoseconds since midnight).
    pub timestamp_ns: u64,
    /// Order reference (original reference for replaces).
    pub order_reference: u64,
    /// Space-padded symbol.
    pub symbol: [u8; SYMBOL_LEN],
    /// Price in ITCH 1/10000 units.
    pub price: u64,
    /// Shares added, executed, or cancelled.
    pub quantity: u32,
    /// ITCH stock locate code.
    pub stock_locate: u16,
    /// Reserved.
    pub reserved: [u8; 2],
    /// New reference for replaces.
    pub new_order_reference: u64,
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
            symbol: [b' '; SYMBOL_LEN],
            price: 0,
            quantity: 0,
            stock_locate: 0,
            reserved: [0; 2],
            new_order_reference: 0,
        }
    }
}

impl MarketEvent {
    /// Parses one ITCH message into a normalized event.
    pub fn parse_itch(message: &[u8], sequence: u64) -> Result<Self, ProtocolError> {
        let parsed = ItchMessage::parse(message)?;
        parsed
            .to_event(sequence)
            .ok_or(ProtocolError::Unsupported(parsed.message_type()))
    }
}

/// Approved order intent, R5 -> A53 (`order_intent` in ipc.yaml).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[repr(C, align(64))]
pub struct OrderIntent {
    /// Must equal [`generated::ABI_VERSION`].
    pub abi_version: u16,
    /// Requested action.
    pub action: OrderAction,
    /// Side.
    pub side: Side,
    /// R5-assigned user reference.
    pub user_ref: u32,
    /// Sequence of the market event that triggered the decision.
    pub source_sequence: u64,
    /// R5 clock at decision time.
    pub decision_timestamp_ns: u64,
    /// Space-padded symbol.
    pub symbol: [u8; SYMBOL_LEN],
    /// Limit price.
    pub price: u64,
    /// Shares.
    pub quantity: u32,
    /// Risk configuration revision that approved the intent.
    pub risk_revision: u32,
    /// ITCH stock locate code.
    pub stock_locate: u16,
    /// Reserved.
    pub reserved: [u8; 14],
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
            symbol: [b' '; SYMBOL_LEN],
            price: 0,
            quantity: 0,
            risk_revision: 0,
            stock_locate: 0,
            reserved: [0; 14],
        }
    }
}

/// Control-plane snapshot, A53 -> R5 (`risk_config` in ipc.yaml).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[repr(C, align(64))]
pub struct RiskConfigRecord {
    /// Must equal [`generated::ABI_VERSION`].
    pub abi_version: u16,
    /// [`generated::ipc::risk_config_flags`] bits.
    pub flags: u16,
    /// Strictly increasing control revision.
    pub revision: u32,
    /// Maximum shares per order.
    pub max_quantity: u32,
    /// Orders allowed per rate window.
    pub max_orders_per_window: u32,
    /// Lowest accepted price.
    pub price_floor: u64,
    /// Highest accepted price.
    pub price_ceiling: u64,
    /// Rate window length.
    pub rate_window_ns: u64,
    /// Maximum concurrently open orders.
    pub max_open_orders: u32,
    /// Active R5 strategy (variant index).
    pub strategy_id: u8,
    /// Valid entries in `allowed_locates`; 0 allows every locate.
    pub allowed_locate_count: u8,
    /// Reserved.
    pub reserved: [u8; 2],
    /// Allowed stock locate codes.
    pub allowed_locates: [u16; 8],
}

impl Default for RiskConfigRecord {
    fn default() -> Self {
        Self {
            abi_version: generated::ABI_VERSION,
            flags: 0,
            revision: 0,
            max_quantity: 0,
            max_orders_per_window: 0,
            price_floor: 0,
            price_ceiling: 0,
            rate_window_ns: 0,
            max_open_orders: 0,
            strategy_id: 0,
            allowed_locate_count: 0,
            reserved: [0; 2],
            allowed_locates: [0; 8],
        }
    }
}

// Helpers used by the generated codecs. OFFSET and N are compile-time
// constants checked against the record size, so the `get` calls below always
// succeed; the fallbacks exist only to avoid panicking code paths.

pub(crate) const fn assert_in_record(offset: usize, size: usize) {
    assert!(offset + size <= generated::IPC_RECORD_SIZE);
}

pub(crate) fn put<const OFFSET: usize, const N: usize>(
    out: &mut [u8; generated::IPC_RECORD_SIZE],
    bytes: [u8; N],
) {
    const { assert_in_record(OFFSET, N) };
    if let Some(slot) = out.get_mut(OFFSET..).and_then(<[u8]>::first_chunk_mut::<N>) {
        *slot = bytes;
    }
}

pub(crate) fn take<const OFFSET: usize, const N: usize>(
    input: &[u8; generated::IPC_RECORD_SIZE],
) -> [u8; N] {
    const { assert_in_record(OFFSET, N) };
    input
        .get(OFFSET..)
        .and_then(<[u8]>::first_chunk::<N>)
        .copied()
        .unwrap_or([0; N])
}

pub(crate) fn u16_array_le(values: [u16; 8]) -> [u8; 16] {
    let mut out = [0_u8; 16];
    for (chunk, value) in out.chunks_exact_mut(2).zip(values) {
        chunk.copy_from_slice(&value.to_le_bytes());
    }
    out
}

pub(crate) fn u16_array_from_le(bytes: [u8; 16]) -> [u16; 8] {
    let mut out = [0_u16; 8];
    for (value, chunk) in out.iter_mut().zip(bytes.as_chunks::<2>().0) {
        *value = u16::from_le_bytes(*chunk);
    }
    out
}

/// One SoupBinTCP frame: a type byte and its payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SoupPacket {
    /// SoupBinTCP packet type (`L`, `A`, `U`, `S`, `H`, ...).
    pub packet_type: u8,
    /// Payload after the type byte.
    pub payload: Bytes,
}

impl SoupPacket {
    /// Encodes the length-prefixed frame.
    pub fn encode(&self) -> Result<Bytes, ProtocolError> {
        let mut output = BytesMut::new();
        self.encode_into(&mut output)?;
        Ok(output.freeze())
    }

    /// Appends the length-prefixed frame to `output`.
    pub fn encode_into(&self, output: &mut BytesMut) -> Result<(), ProtocolError> {
        let body_len =
            u16::try_from(self.payload.len() + 1).map_err(|_| ProtocolError::InvalidLength)?;
        output.reserve(usize::from(body_len) + 2);
        output.put_u16(body_len);
        output.put_u8(self.packet_type);
        output.extend_from_slice(&self.payload);
        Ok(())
    }

    /// Decodes exactly one frame (length prefix included).
    pub fn decode(frame: &[u8]) -> Result<Self, ProtocolError> {
        let (length, body) = frame
            .split_first_chunk::<2>()
            .ok_or(ProtocolError::Truncated)?;
        let body_len = usize::from(u16::from_be_bytes(*length));
        if body_len == 0 || body.len() != body_len {
            return Err(ProtocolError::InvalidLength);
        }
        let (&packet_type, payload) = body.split_first().ok_or(ProtocolError::Truncated)?;
        Ok(Self {
            packet_type,
            payload: Bytes::copy_from_slice(payload),
        })
    }
}

/// Encodes the simulator's subset of an OUCH 5.0 Enter Order message.
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
#[allow(clippy::indexing_slicing, reason = "tests index fixed fixtures")]
mod tests {
    use proptest::prelude::*;

    use super::*;

    const ADD_VECTOR: &[u8] = include_bytes!("../../../../protocol/vectors/mold_add_order.bin");
    const MIXED_VECTOR: &[u8] = include_bytes!("../../../../protocol/vectors/mold_mixed.bin");
    const TRUNCATED_VECTOR: &[u8] =
        include_bytes!("../../../../protocol/vectors/mold_truncated.bin");
    const EVENT_VECTOR: &[u8] =
        include_bytes!("../../../../protocol/vectors/ipc_normalized_event.bin");
    const INTENT_VECTOR: &[u8] =
        include_bytes!("../../../../protocol/vectors/ipc_order_intent.bin");
    const CONFIG_VECTOR: &[u8] = include_bytes!("../../../../protocol/vectors/ipc_risk_config.bin");

    fn ok<T, E: std::fmt::Display>(result: Result<T, E>) -> T {
        result.unwrap_or_else(|error| panic!("{error}"))
    }

    #[test]
    fn parses_shared_add_vector() {
        let packet = ok(MoldPacket::parse(ADD_VECTOR));
        assert_eq!(packet.sequence, 1);
        assert_eq!(packet.message_count(), 1);
        let message = packet.messages().next().unwrap_or_default();
        let event = ok(MarketEvent::parse_itch(message, packet.sequence));
        assert_eq!(event.kind, EventKind::Add);
        assert_eq!(event.side, Side::Buy);
        assert_eq!(event.quantity, 100);
        assert_eq!(event.price, 1_234_500);
        assert_eq!(event.stock_locate, 1);
        assert_eq!(&event.symbol, b"ACME    ");
    }

    #[test]
    fn normalizes_every_mixed_vector_message() {
        let packet = ok(MoldPacket::parse(MIXED_VECTOR));
        let kinds: Vec<EventKind> = packet
            .messages()
            .zip(packet.sequence..)
            .map(|(message, sequence)| ok(MarketEvent::parse_itch(message, sequence)).kind)
            .collect();
        assert_eq!(
            kinds,
            [
                EventKind::Add,
                EventKind::Add,
                EventKind::Execute,
                EventKind::Execute,
                EventKind::Cancel,
                EventKind::Replace,
                EventKind::Delete,
            ]
        );
    }

    #[test]
    fn rejects_truncated_shared_vector() {
        assert_eq!(
            MoldPacket::parse(TRUNCATED_VECTOR).err(),
            Some(ProtocolError::Truncated)
        );
    }

    #[test]
    fn decodes_generated_ipc_images() {
        let event = ok(MarketEvent::decode_ipc(EVENT_VECTOR));
        assert_eq!(event.abi_version, generated::ABI_VERSION);
        assert_eq!(event.order_reference, 0x0102_0304_0506_0708);
        assert_eq!(event.encode_ipc().as_slice(), EVENT_VECTOR);

        let intent = ok(OrderIntent::decode_ipc(INTENT_VECTOR));
        assert_eq!(intent.side, Side::Sell);
        assert_eq!(intent.user_ref, 7);
        assert_eq!(intent.encode_ipc().as_slice(), INTENT_VECTOR);

        let config = ok(RiskConfigRecord::decode_ipc(CONFIG_VECTOR));
        assert_eq!(config.revision, 4);
        assert_eq!(config.allowed_locates[1], 7);
        assert_eq!(config.encode_ipc().as_slice(), CONFIG_VECTOR);
    }

    #[test]
    fn rejects_unknown_enum_bytes_in_ipc_images() {
        let mut image = [0_u8; generated::IPC_RECORD_SIZE];
        image.copy_from_slice(EVENT_VECTOR);
        image[generated::ipc::normalized_event::KIND] = b'?';
        assert_eq!(
            MarketEvent::decode_ipc(&image),
            Err(ProtocolError::Unsupported(b'?'))
        );
        assert_eq!(
            MarketEvent::decode_ipc(&image[..10]),
            Err(ProtocolError::InvalidLength)
        );
    }

    #[test]
    fn soup_round_trip() {
        let packet = SoupPacket {
            packet_type: b'U',
            payload: Bytes::from_static(b"order"),
        };
        let encoded = ok(packet.encode());
        assert_eq!(ok(SoupPacket::decode(&encoded)), packet);
    }

    proptest! {
        #[test]
        fn arbitrary_soup_payload_round_trips(
            packet_type in any::<u8>(),
            payload in proptest::collection::vec(any::<u8>(), 0..512),
        ) {
            let packet = SoupPacket {
                packet_type,
                payload: Bytes::from(payload),
            };
            let decoded = packet.encode().and_then(|frame| SoupPacket::decode(&frame));
            prop_assert_eq!(decoded, Ok(packet));
        }

        #[test]
        fn arbitrary_bytes_never_panic(payload in proptest::collection::vec(any::<u8>(), 0..2048)) {
            if let Ok(packet) = MoldPacket::parse(&payload) {
                for message in packet.messages() {
                    let _ = ItchMessage::parse(message);
                }
            }
            let _ = ItchMessage::parse(&payload);
            let _ = MarketEvent::decode_ipc(&payload);
        }
    }
}
