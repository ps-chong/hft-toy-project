//! The record carried by the A53 intent ring.

use hft_disruptor::{SLOT_WORDS, Slotted};
use hft_protocol::{OrderIntent, generated};

/// An approved intent plus the A53 monotonic time it was read from RPMsg.
///
/// The receipt time rides in the intent's reserved bytes while the record is
/// inside the ring; those bytes are zero again whenever the intent leaves it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RingIntent {
    /// The intent as the R5 approved it.
    pub intent: OrderIntent,
    /// `CLOCK_MONOTONIC` nanoseconds at RPMsg receipt.
    pub received_ns: u64,
}

const STAMP: usize = generated::ipc::order_intent::RESERVED;

impl Slotted for RingIntent {
    fn pack(&self) -> [u64; SLOT_WORDS] {
        let mut image = self.intent.encode_ipc();
        if let Some(stamp) = image
            .get_mut(STAMP..)
            .and_then(<[u8]>::first_chunk_mut::<8>)
        {
            *stamp = self.received_ns.to_le_bytes();
        }
        let mut words = [0_u64; SLOT_WORDS];
        for (word, chunk) in words.iter_mut().zip(image.as_chunks::<8>().0) {
            *word = u64::from_le_bytes(*chunk);
        }
        words
    }

    fn unpack(words: [u64; SLOT_WORDS]) -> Option<Self> {
        let mut image = [0_u8; generated::IPC_RECORD_SIZE];
        for (chunk, word) in image.as_chunks_mut::<8>().0.iter_mut().zip(words) {
            *chunk = word.to_le_bytes();
        }
        let stamp = image
            .get_mut(STAMP..)
            .and_then(<[u8]>::first_chunk_mut::<8>)?;
        let received_ns = u64::from_le_bytes(*stamp);
        *stamp = [0; 8];
        let intent = OrderIntent::decode_ipc(&image).ok()?;
        Some(Self {
            intent,
            received_ns,
        })
    }
}

/// `CLOCK_MONOTONIC` in nanoseconds. On the host demo the R5 model uses the
/// same clock, so decision-to-receipt latency is meaningful there; on the
/// board the R5 and A53 clocks are separate domains.
#[must_use]
pub fn monotonic_ns() -> u64 {
    let now = rustix::time::clock_gettime(rustix::time::ClockId::Monotonic);
    u64::try_from(now.tv_sec).unwrap_or_default() * 1_000_000_000
        + u64::try_from(now.tv_nsec).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use hft_protocol::{OrderAction, Side};

    use super::*;

    #[test]
    fn ring_record_round_trips_and_clears_reserved_bytes() {
        let record = RingIntent {
            intent: OrderIntent {
                action: OrderAction::Enter,
                side: Side::Sell,
                user_ref: 3,
                ..OrderIntent::default()
            },
            received_ns: 0x1122_3344_5566_7788,
        };
        let unpacked = RingIntent::unpack(record.pack()).unwrap();
        assert_eq!(unpacked, record);
        assert_eq!(unpacked.intent.reserved, [0; 14]);
    }
}
