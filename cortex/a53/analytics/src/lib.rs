//! Bounded, noncritical latency aggregation.
//!
//! A [`LatencyBook`] is owned by exactly one task (the gateway for
//! intent-to-ack, the analytics consumer for decision-to-receipt); other tasks
//! only ever see copied [`LatencySummary`] values.

use hdrhistogram::{CreationError, Histogram};
use serde::{Deserialize, Serialize};

/// Percentile snapshot of one latency domain.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct LatencySummary {
    /// Recorded samples.
    pub samples: u64,
    /// Smallest sample.
    pub minimum_ns: u64,
    /// Median.
    pub p50_ns: u64,
    /// 99th percentile.
    pub p99_ns: u64,
    /// 99.9th percentile.
    pub p999_ns: u64,
    /// Largest sample.
    pub maximum_ns: u64,
}

/// Two fixed-bound histograms with 3 significant digits.
pub struct LatencyBook {
    tick_to_intent: Histogram<u64>,
    intent_to_ack: Histogram<u64>,
    dropped_samples: u64,
}

impl LatencyBook {
    /// Creates histograms covering 1 ns to `maximum_ns`.
    pub fn new(maximum_ns: u64) -> Result<Self, CreationError> {
        Ok(Self {
            tick_to_intent: Histogram::new_with_bounds(1, maximum_ns, 3)?,
            intent_to_ack: Histogram::new_with_bounds(1, maximum_ns, 3)?,
            dropped_samples: 0,
        })
    }

    /// Records a decision-path latency; out-of-range samples are counted.
    pub fn record_tick_to_intent(&mut self, latency_ns: u64) {
        if self.tick_to_intent.record(latency_ns.max(1)).is_err() {
            self.dropped_samples = self.dropped_samples.saturating_add(1);
        }
    }

    /// Records an exchange round trip; out-of-range samples are counted.
    pub fn record_intent_to_ack(&mut self, latency_ns: u64) {
        if self.intent_to_ack.record(latency_ns.max(1)).is_err() {
            self.dropped_samples = self.dropped_samples.saturating_add(1);
        }
    }

    /// Decision-path percentiles.
    #[must_use]
    pub fn tick_to_intent(&self) -> LatencySummary {
        summarize(&self.tick_to_intent)
    }

    /// Exchange round-trip percentiles.
    #[must_use]
    pub fn intent_to_ack(&self) -> LatencySummary {
        summarize(&self.intent_to_ack)
    }

    /// Samples outside the histogram bounds.
    #[must_use]
    pub fn dropped_samples(&self) -> u64 {
        self.dropped_samples
    }
}

fn summarize(histogram: &Histogram<u64>) -> LatencySummary {
    if histogram.is_empty() {
        return LatencySummary::default();
    }
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
        let mut book = LatencyBook::new(1_000_000).unwrap();
        for sample in [100, 200, 300, 400, 500] {
            book.record_tick_to_intent(sample);
        }
        let summary = book.tick_to_intent();
        assert_eq!(summary.samples, 5);
        assert!(summary.minimum_ns <= 100);
        assert!(summary.maximum_ns >= 500);
        assert!(summary.p99_ns >= 400);
        assert_eq!(book.intent_to_ack(), LatencySummary::default());
    }

    #[test]
    fn counts_out_of_range_samples() {
        let mut book = LatencyBook::new(1_000).unwrap();
        book.record_intent_to_ack(10_000_000);
        assert_eq!(book.dropped_samples(), 1);
    }
}
