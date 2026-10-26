//! Exhaustive interleaving checks of the ring's memory ordering.
//!
//! Run with: `RUSTFLAGS="--cfg loom" cargo test -p hft-disruptor --release --test loom`
#![cfg(loom)]
#![allow(clippy::unwrap_used, reason = "model setup panics on failure")]

use hft_disruptor::{SLOT_WORDS, build};

fn record(value: u64) -> [u64; SLOT_WORDS] {
    [value; SLOT_WORDS]
}

fn model(test: impl Fn() + Sync + Send + 'static) {
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(2);
    builder.check(test);
}

#[test]
fn gating_consumer_sees_every_record_intact_and_in_order() {
    model(|| {
        let (mut producer, mut consumers) = build::<[u64; SLOT_WORDS]>(2, 1).unwrap();
        let mut consumer = consumers.pop().unwrap();
        let writer = loom::thread::spawn(move || {
            for value in 1..=3 {
                while producer.try_publish(&record(value)).is_err() {
                    loom::thread::yield_now();
                }
            }
        });
        let mut expected = 1;
        while expected <= 3 {
            consumer.read_batch(2, |_, value| {
                assert_eq!(value, record(expected));
                expected += 1;
            });
            loom::thread::yield_now();
        }
        writer.join().unwrap();
    });
}

#[test]
fn lossy_consumer_never_delivers_a_torn_record() {
    model(|| {
        let (mut producer, _) = build::<[u64; SLOT_WORDS]>(2, 0).unwrap();
        let mut lossy = producer.lossy_consumer();
        let writer = loom::thread::spawn(move || {
            for value in 1..=3 {
                producer.try_publish(&record(value)).unwrap();
            }
        });
        for _ in 0..2 {
            lossy.read_batch(2, |_, value| {
                assert!(value.iter().all(|word| *word == value[0]), "torn read");
            });
        }
        writer.join().unwrap();
    });
}
