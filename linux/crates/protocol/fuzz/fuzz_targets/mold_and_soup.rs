#![no_main]

use hft_protocol::{MoldPacket, SoupPacket};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _mold = MoldPacket::parse(data);
    let _soup = SoupPacket::decode(data);
});
