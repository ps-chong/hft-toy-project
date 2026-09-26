//! Bounded, noncritical latency aggregation.

use hdrhistogram::{CreationError, Histogram};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct LatencySummary {
    pub samples: u64,
    pub minimum_ns: u64,
    pub p50_ns: u64,
    pub p99_ns: u64,
    pub p999_ns: u64,
    pub maximum_ns: u64,
}

pub struct LatencyBook {
    tick_to_intent: Histogram<u64>,
    intent_to_ack: Histogram<u64>,
    dropped_samples: u64,
}

impl LatencyBook {
    pub fn new(maximum_ns: u64) -> Result<Self, CreationError> {
        Ok(Self {
            tick_to_intent: Histogram::new_with_bounds(1, maximum_ns, 3)?,
            intent_to_ack: Histogram::new_with_bounds(1, maximum_ns, 3)?,
            dropped_samples: 0,
        })
    }

    pub fn record_tick_to_intent(&mut self, latency_ns: u64) {
        if self.tick_to_intent.record(latency_ns).is_err() {
            self.dropped_samples = self.dropped_samples.saturating_add(1);
        }
    }

    pub fn record_intent_to_ack(&mut self, latency_ns: u64) {
        if self.intent_to_ack.record(latency_ns).is_err() {
            self.dropped_samples = self.dropped_samples.saturating_add(1);
        }
    }

    #[must_use]
    pub fn tick_to_intent(&self) -> LatencySummary {
        summarize(&self.tick_to_intent)
    }

    #[must_use]
    pub fn intent_to_ack(&self) -> LatencySummary {
        summarize(&self.intent_to_ack)
    }

    #[must_use]
    pub fn dropped_samples(&self) -> u64 {
        self.dropped_samples
    }
}

fn summarize(histogram: &Histogram<u64>) -> LatencySummary {
    LatencySummary {
        samples: histogram.len(),
        minimum_ns: histogram.min(),
        p50_ns: histogram.value_at_quantile(0.5),
        p99_ns: histogram.value_at_quantile(0.99),
        p999_ns: histogram.value_at_quantile(0.999),
        maximum_ns: histogram.max(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summarizes_without_affecting_trading_path() {
        let mut book =
            LatencyBook::new(1_000_000).unwrap_or_else(|error| panic!("{error}"));
        for sample in [100, 200, 300, 400, 500] {
            book.record_tick_to_intent(sample);
        }
        let summary = book.tick_to_intent();
        assert_eq!(summary.samples, 5);
        assert!(summary.minimum_ns <= 100);
        assert!(summary.maximum_ns >= 500);
        assert!(summary.p99_ns >= 400);
    }
}
