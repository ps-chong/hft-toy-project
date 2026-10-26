//! Typed Nasdaq TotalView-ITCH 5.0 messages.
//!
//! [`ItchMessage::parse`] checks the exact length of each supported type
//! first; after that, field extraction cannot fail. Offsets come from
//! `protocol/schema/itch50.yaml` through [`crate::generated::itch`].

use crate::generated::itch as layout;
use crate::{EventKind, MarketEvent, ProtocolError, SYMBOL_LEN, Side};

/// Fields shared by every ITCH message.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ItchHeader {
    /// Stock locate code.
    pub stock_locate: u16,
    /// Tracking number.
    pub tracking_number: u16,
    /// Nanoseconds since midnight (48 bits on the wire).
    pub timestamp_ns: u64,
}

/// The ITCH messages the trading path decodes. Everything else is `Other`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ItchMessage {
    /// `S`: system event.
    SystemEvent {
        /// Common fields.
        header: ItchHeader,
        /// Event code (`O`, `S`, `Q`, `M`, `E`, `C`).
        event_code: u8,
    },
    /// `A` (no attribution) or `F` (with MPID attribution).
    AddOrder {
        /// Common fields.
        header: ItchHeader,
        /// Order reference.
        order_reference: u64,
        /// Side.
        side: Side,
        /// Displayed shares.
        shares: u32,
        /// Space-padded symbol.
        stock: [u8; SYMBOL_LEN],
        /// Price (1/10000).
        price: u32,
        /// MPID for `F` messages.
        attribution: Option<[u8; 4]>,
    },
    /// `E`: execution at the displayed price.
    OrderExecuted {
        /// Common fields.
        header: ItchHeader,
        /// Order reference.
        order_reference: u64,
        /// Executed shares.
        executed_shares: u32,
        /// Match number.
        match_number: u64,
    },
    /// `C`: execution at a different price.
    OrderExecutedWithPrice {
        /// Common fields.
        header: ItchHeader,
        /// Order reference.
        order_reference: u64,
        /// Executed shares.
        executed_shares: u32,
        /// Match number.
        match_number: u64,
        /// Execution price (1/10000).
        execution_price: u32,
    },
    /// `X`: partial cancel.
    OrderCancel {
        /// Common fields.
        header: ItchHeader,
        /// Order reference.
        order_reference: u64,
        /// Cancelled shares.
        cancelled_shares: u32,
    },
    /// `D`: full delete.
    OrderDelete {
        /// Common fields.
        header: ItchHeader,
        /// Order reference.
        order_reference: u64,
    },
    /// `U`: cancel-replace with a new reference.
    OrderReplace {
        /// Common fields.
        header: ItchHeader,
        /// Reference being replaced.
        original_order_reference: u64,
        /// New reference.
        new_order_reference: u64,
        /// New shares.
        shares: u32,
        /// New price (1/10000).
        price: u32,
    },
    /// `P`: non-displayed trade.
    Trade {
        /// Common fields.
        header: ItchHeader,
        /// Order reference.
        order_reference: u64,
        /// Side.
        side: Side,
        /// Shares.
        shares: u32,
        /// Space-padded symbol.
        stock: [u8; SYMBOL_LEN],
        /// Price (1/10000).
        price: u32,
    },
    /// A well-formed message of a type the trading path ignores.
    Other {
        /// ITCH message type byte.
        message_type: u8,
    },
}

/// Big-endian field at a compile-time offset. Callers have already checked
/// the message length, so the fallback is never taken.
fn be<const OFFSET: usize, const N: usize>(message: &[u8]) -> [u8; N] {
    message
        .get(OFFSET..)
        .and_then(<[u8]>::first_chunk::<N>)
        .copied()
        .unwrap_or([0; N])
}

fn u48(bytes: [u8; 6]) -> u64 {
    bytes
        .iter()
        .fold(0, |value, byte| (value << 8) | u64::from(*byte))
}

fn side(byte: u8) -> Result<Side, ProtocolError> {
    match Side::try_from(byte)? {
        Side::Unknown => Err(ProtocolError::Unsupported(byte)),
        known => Ok(known),
    }
}

fn expect_length(message: &[u8], length: usize) -> Result<(), ProtocolError> {
    if message.len() == length {
        Ok(())
    } else {
        Err(ProtocolError::InvalidLength)
    }
}

impl ItchMessage {
    /// Parses one ITCH message (without its MoldUDP64 length prefix).
    pub fn parse(message: &[u8]) -> Result<Self, ProtocolError> {
        let &message_type = message.first().ok_or(ProtocolError::Truncated)?;
        if message.len() < layout::TIMESTAMP + 6 {
            return Err(ProtocolError::Truncated);
        }
        let header = ItchHeader {
            stock_locate: u16::from_be_bytes(be::<{ layout::STOCK_LOCATE }, 2>(message)),
            tracking_number: u16::from_be_bytes(be::<{ layout::TRACKING_NUMBER }, 2>(message)),
            timestamp_ns: u48(be::<{ layout::TIMESTAMP }, 6>(message)),
        };
        let parsed = match message_type {
            b'S' => {
                expect_length(message, layout::system_event::LENGTH)?;
                Self::SystemEvent {
                    header,
                    event_code: be::<{ layout::system_event::EVENT_CODE }, 1>(message)[0],
                }
            }
            b'A' | b'F' => Self::parse_add(message, header, message_type == b'F')?,
            b'E' => {
                use layout::order_executed as f;
                expect_length(message, f::LENGTH)?;
                Self::OrderExecuted {
                    header,
                    order_reference: u64::from_be_bytes(be::<{ f::ORDER_REFERENCE }, 8>(message)),
                    executed_shares: u32::from_be_bytes(be::<{ f::EXECUTED_SHARES }, 4>(message)),
                    match_number: u64::from_be_bytes(be::<{ f::MATCH_NUMBER }, 8>(message)),
                }
            }
            b'C' => {
                use layout::order_executed_with_price as f;
                expect_length(message, f::LENGTH)?;
                Self::OrderExecutedWithPrice {
                    header,
                    order_reference: u64::from_be_bytes(be::<{ f::ORDER_REFERENCE }, 8>(message)),
                    executed_shares: u32::from_be_bytes(be::<{ f::EXECUTED_SHARES }, 4>(message)),
                    match_number: u64::from_be_bytes(be::<{ f::MATCH_NUMBER }, 8>(message)),
                    execution_price: u32::from_be_bytes(be::<{ f::EXECUTION_PRICE }, 4>(message)),
                }
            }
            b'X' => {
                use layout::order_cancel as f;
                expect_length(message, f::LENGTH)?;
                Self::OrderCancel {
                    header,
                    order_reference: u64::from_be_bytes(be::<{ f::ORDER_REFERENCE }, 8>(message)),
                    cancelled_shares: u32::from_be_bytes(be::<{ f::CANCELLED_SHARES }, 4>(message)),
                }
            }
            b'D' => {
                use layout::order_delete as f;
                expect_length(message, f::LENGTH)?;
                Self::OrderDelete {
                    header,
                    order_reference: u64::from_be_bytes(be::<{ f::ORDER_REFERENCE }, 8>(message)),
                }
            }
            b'U' => {
                use layout::order_replace as f;
                expect_length(message, f::LENGTH)?;
                Self::OrderReplace {
                    header,
                    original_order_reference: u64::from_be_bytes(be::<
                        { f::ORIGINAL_ORDER_REFERENCE },
                        8,
                    >(message)),
                    new_order_reference: u64::from_be_bytes(be::<{ f::NEW_ORDER_REFERENCE }, 8>(
                        message,
                    )),
                    shares: u32::from_be_bytes(be::<{ f::SHARES }, 4>(message)),
                    price: u32::from_be_bytes(be::<{ f::PRICE }, 4>(message)),
                }
            }
            b'P' => {
                use layout::trade as f;
                expect_length(message, f::LENGTH)?;
                Self::Trade {
                    header,
                    order_reference: u64::from_be_bytes(be::<{ f::ORDER_REFERENCE }, 8>(message)),
                    side: side(be::<{ f::SIDE }, 1>(message)[0])?,
                    shares: u32::from_be_bytes(be::<{ f::SHARES }, 4>(message)),
                    stock: be::<{ f::STOCK }, 8>(message),
                    price: u32::from_be_bytes(be::<{ f::PRICE }, 4>(message)),
                }
            }
            other => Self::Other {
                message_type: other,
            },
        };
        Ok(parsed)
    }

    fn parse_add(
        message: &[u8],
        header: ItchHeader,
        with_mpid: bool,
    ) -> Result<Self, ProtocolError> {
        use layout::add_order as f;
        let length = if with_mpid {
            layout::add_order_mpid::LENGTH
        } else {
            f::LENGTH
        };
        expect_length(message, length)?;
        Ok(Self::AddOrder {
            header,
            order_reference: u64::from_be_bytes(be::<{ f::ORDER_REFERENCE }, 8>(message)),
            side: side(be::<{ f::SIDE }, 1>(message)[0])?,
            shares: u32::from_be_bytes(be::<{ f::SHARES }, 4>(message)),
            stock: be::<{ f::STOCK }, 8>(message),
            price: u32::from_be_bytes(be::<{ f::PRICE }, 4>(message)),
            attribution: with_mpid
                .then(|| be::<{ layout::add_order_mpid::ATTRIBUTION }, 4>(message)),
        })
    }

    /// ITCH type byte of the message.
    #[must_use]
    pub fn message_type(&self) -> u8 {
        match self {
            Self::SystemEvent { .. } => b'S',
            Self::AddOrder { attribution, .. } => {
                if attribution.is_some() {
                    b'F'
                } else {
                    b'A'
                }
            }
            Self::OrderExecuted { .. } => b'E',
            Self::OrderExecutedWithPrice { .. } => b'C',
            Self::OrderCancel { .. } => b'X',
            Self::OrderDelete { .. } => b'D',
            Self::OrderReplace { .. } => b'U',
            Self::Trade { .. } => b'P',
            Self::Other { message_type } => *message_type,
        }
    }

    /// Normalizes order-book messages into the R5 event record, mirroring
    /// the PL normalization: `F` becomes Add and `C` becomes Execute.
    #[must_use]
    pub fn to_event(&self, sequence: u64) -> Option<MarketEvent> {
        let base = |header: &ItchHeader| MarketEvent {
            sequence,
            timestamp_ns: header.timestamp_ns,
            stock_locate: header.stock_locate,
            ..MarketEvent::default()
        };
        let event = match *self {
            Self::AddOrder {
                ref header,
                order_reference,
                side,
                shares,
                stock,
                price,
                ..
            } => MarketEvent {
                kind: EventKind::Add,
                side,
                order_reference,
                quantity: shares,
                symbol: stock,
                price: u64::from(price),
                ..base(header)
            },
            Self::OrderExecuted {
                ref header,
                order_reference,
                executed_shares,
                ..
            } => MarketEvent {
                kind: EventKind::Execute,
                order_reference,
                quantity: executed_shares,
                ..base(header)
            },
            Self::OrderExecutedWithPrice {
                ref header,
                order_reference,
                executed_shares,
                execution_price,
                ..
            } => MarketEvent {
                kind: EventKind::Execute,
                order_reference,
                quantity: executed_shares,
                price: u64::from(execution_price),
                ..base(header)
            },
            Self::OrderCancel {
                ref header,
                order_reference,
                cancelled_shares,
            } => MarketEvent {
                kind: EventKind::Cancel,
                order_reference,
                quantity: cancelled_shares,
                ..base(header)
            },
            Self::OrderDelete {
                ref header,
                order_reference,
            } => MarketEvent {
                kind: EventKind::Delete,
                order_reference,
                ..base(header)
            },
            Self::OrderReplace {
                ref header,
                original_order_reference,
                new_order_reference,
                shares,
                price,
            } => MarketEvent {
                kind: EventKind::Replace,
                order_reference: original_order_reference,
                new_order_reference,
                quantity: shares,
                price: u64::from(price),
                ..base(header)
            },
            Self::Trade {
                ref header,
                order_reference,
                side,
                shares,
                stock,
                price,
            } => MarketEvent {
                kind: EventKind::Trade,
                side,
                order_reference,
                quantity: shares,
                symbol: stock,
                price: u64::from(price),
                ..base(header)
            },
            Self::SystemEvent { .. } | Self::Other { .. } => return None,
        };
        Some(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn replace_message() -> Vec<u8> {
        let mut message = vec![b'U'];
        message.extend_from_slice(&3_u16.to_be_bytes());
        message.extend_from_slice(&9_u16.to_be_bytes());
        message.extend_from_slice(&[0, 0, 0, 0, 1, 0]);
        message.extend_from_slice(&11_u64.to_be_bytes());
        message.extend_from_slice(&12_u64.to_be_bytes());
        message.extend_from_slice(&40_u32.to_be_bytes());
        message.extend_from_slice(&5_000_u32.to_be_bytes());
        message
    }

    #[test]
    fn replace_carries_both_references_and_stock_locate() {
        let event = ItchMessage::parse(&replace_message())
            .ok()
            .and_then(|message| message.to_event(77));
        let event = event.unwrap_or_default();
        assert_eq!(event.kind, EventKind::Replace);
        assert_eq!(event.order_reference, 11);
        assert_eq!(event.new_order_reference, 12);
        assert_eq!(event.quantity, 40);
        assert_eq!(event.price, 5_000);
        assert_eq!(event.stock_locate, 3);
        assert_eq!(event.timestamp_ns, 256);
        assert_eq!(event.sequence, 77);
    }

    #[test]
    fn exact_lengths_are_enforced() {
        let mut long = replace_message();
        long.push(0);
        assert_eq!(ItchMessage::parse(&long), Err(ProtocolError::InvalidLength));
        assert_eq!(ItchMessage::parse(b"U"), Err(ProtocolError::Truncated));
    }

    #[test]
    fn unknown_types_are_well_formed_but_not_events() {
        let mut message = vec![b'R'];
        message.extend_from_slice(&[0; 38]);
        let parsed = ItchMessage::parse(&message).unwrap_or(ItchMessage::Other { message_type: 0 });
        assert_eq!(parsed.message_type(), b'R');
        assert_eq!(parsed.to_event(1), None);
    }
}
