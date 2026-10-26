//! Software model of the PL market-data ingress (`moldudp64_rx` and
//! `itch_decoder`) used by the host demo.
//!
//! The model is deliberately the same function the RTL implements: sequence
//! tracking with gap flagging, then ITCH normalization. The demo's RTL replay
//! compares the two outputs byte for byte.

use hft_protocol::{
    MarketEvent, MoldPacket, ProtocolError, generated::ipc::normalized_event_flags,
};

/// Feed state: the next expected MoldUDP64 sequence.
#[derive(Debug, Default)]
pub struct FeedModel {
    expected: Option<u64>,
    gaps: u64,
    duplicates: u64,
    flag_next: bool,
}

/// Outcome of one datagram.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Ingest {
    /// Normalized order-book events, in feed order.
    pub events: Vec<MarketEvent>,
    /// True when this packet skipped sequence numbers.
    pub gap: bool,
    /// True when the whole packet was already seen (A/B line duplicate).
    pub duplicate: bool,
}

impl FeedModel {
    /// Processes one MoldUDP64 datagram.
    pub fn ingest(&mut self, datagram: &[u8]) -> Result<Ingest, ProtocolError> {
        let packet = MoldPacket::parse(datagram)?;
        let count = u64::try_from(packet.message_count()).unwrap_or(u64::MAX);
        let mut outcome = Ingest::default();
        match self.expected {
            Some(expected) if packet.sequence + count <= expected && count > 0 => {
                // Entirely old: drop, as an A/B arbiter would.
                self.duplicates += 1;
                outcome.duplicate = true;
                return Ok(outcome);
            }
            Some(expected) if packet.sequence > expected => {
                self.gaps += 1;
                outcome.gap = true;
                self.flag_next = true;
            }
            _ => {}
        }
        self.expected = Some(packet.sequence + count);

        for (message, sequence) in packet.messages().zip(packet.sequence..) {
            let Ok(mut event) = MarketEvent::parse_itch(message, sequence) else {
                continue;
            };
            if std::mem::take(&mut self.flag_next) {
                event.flags |= normalized_event_flags::FEED_GAP;
            }
            outcome.events.push(event);
        }
        Ok(outcome)
    }

    /// Gaps seen so far.
    #[must_use]
    pub fn gaps(&self) -> u64 {
        self.gaps
    }

    /// Duplicate packets dropped so far.
    #[must_use]
    pub fn duplicates(&self) -> u64 {
        self.duplicates
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ADD: &[u8] = include_bytes!("../../../../protocol/vectors/mold_add_order.bin");
    const MIXED: &[u8] = include_bytes!("../../../../protocol/vectors/mold_mixed.bin");
    const REPLAY_CAPTURE: &[u8] = include_bytes!("../../../../protocol/vectors/replay_capture.bin");
    const REPLAY_EXPECTED: &[u8] =
        include_bytes!("../../../../protocol/vectors/replay_expected.bin");

    /// The generator's expectation, the RTL (`tb_replay`) and this model must
    /// agree byte for byte on the replay session.
    #[test]
    fn matches_the_generated_replay_session() {
        let mut model = FeedModel::default();
        let mut produced = Vec::new();
        let mut rest = REPLAY_CAPTURE;
        while let Some((length, tail)) = rest.split_first_chunk::<2>() {
            let (datagram, remainder) = tail.split_at(usize::from(u16::from_be_bytes(*length)));
            // The session includes one truncated datagram, rejected whole.
            if let Ok(outcome) = model.ingest(datagram) {
                for event in outcome.events {
                    produced.extend_from_slice(&event.encode_ipc());
                }
            }
            rest = remainder;
        }
        assert_eq!(produced, REPLAY_EXPECTED);
        assert_eq!(model.gaps(), 1);
        assert_eq!(model.duplicates(), 1);
    }

    #[test]
    fn flags_the_first_event_after_a_gap() {
        let mut model = FeedModel::default();
        let first = model.ingest(ADD).unwrap();
        assert_eq!(first.events.len(), 1);
        assert!(!first.gap);
        // The mixed vector starts at sequence 10; 2..9 were never seen.
        let second = model.ingest(MIXED).unwrap();
        assert!(second.gap);
        assert_eq!(second.events.len(), 7);
        assert_ne!(second.events[0].flags & normalized_event_flags::FEED_GAP, 0);
        assert_eq!(second.events[1].flags, 0);
        assert_eq!(model.gaps(), 1);
    }

    #[test]
    fn drops_replayed_packets() {
        let mut model = FeedModel::default();
        model.ingest(MIXED).unwrap();
        let replay = model.ingest(MIXED).unwrap();
        assert!(replay.duplicate);
        assert!(replay.events.is_empty());
    }
}
