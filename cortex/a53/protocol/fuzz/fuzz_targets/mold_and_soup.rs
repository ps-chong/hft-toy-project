#![no_main]

//! Feeds arbitrary bytes to every decoder that faces the network or the R5.
//! None of them may panic, loop, or allocate without bound.

use bytes::BytesMut;
use hft_protocol::{
    ItchMessage, MarketEvent, MoldPacket, OrderIntent, RiskConfigRecord, SoupPacket,
    codec::SoupCodec,
};
use libfuzzer_sys::fuzz_target;
use tokio_util::codec::Decoder;

fuzz_target!(|data: &[u8]| {
    if let Ok(packet) = MoldPacket::parse(data) {
        for message in packet.messages() {
            let _ = ItchMessage::parse(message).map(|parsed| parsed.to_event(packet.sequence));
        }
    }
    let _ = ItchMessage::parse(data);
    let _ = SoupPacket::decode(data);
    let _ = MarketEvent::decode_ipc(data);
    let _ = OrderIntent::decode_ipc(data);
    let _ = RiskConfigRecord::decode_ipc(data);

    let mut codec = SoupCodec;
    let mut buffer = BytesMut::from(data);
    while let Ok(Some(_)) = codec.decode(&mut buffer) {}
});
