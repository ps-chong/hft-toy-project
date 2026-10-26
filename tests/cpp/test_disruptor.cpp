// Disruptor ring, compile-time stage pipeline and lossy journal reader,
// including a multi-threaded stress run for ThreadSanitizer.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "hft/disruptor/lossy_reader.hpp"
#include "hft/disruptor/pipeline.hpp"
#include "hft/disruptor/ring.hpp"
#include "hft/types.hpp"

namespace {

using hft::disruptor::distance;
using hft::disruptor::sequence_t;
using hft::disruptor::StageControl;

// Every field is derived from the sequence so any torn copy is detectable.
auto event(std::uint64_t sequence) -> hft::MarketEvent {
  return {.kind = hft::EventKind::add,
          .side = hft::Side::buy,
          .sequence = sequence,
          .order_reference = sequence * 7U,
          .price = sequence * 3U,
          .quantity = static_cast<std::uint32_t>(sequence),
          .new_order_reference = ~sequence};
}

auto intact(hft::MarketEvent const& value) -> bool {
  return value.order_reference == value.sequence * 7U && value.price == value.sequence * 3U &&
         value.quantity == static_cast<std::uint32_t>(value.sequence) &&
         value.new_order_reference == ~value.sequence;
}

using SmallRing = hft::disruptor::Ring<hft::MarketEvent, 8>;

struct Tagging {
  std::vector<sequence_t>* seen;
  auto on_event(hft::MarketEvent const& value, std::uint64_t& tag, sequence_t sequence) noexcept
      -> StageControl {
    tag = value.sequence;
    seen->push_back(sequence);
    return StageControl::proceed;
  }
};

struct Checking {
  std::size_t halt_after{std::numeric_limits<std::size_t>::max()};
  std::size_t processed{};
  bool mismatch{};
  auto on_event(hft::MarketEvent const& value, std::uint64_t& tag, sequence_t) noexcept
      -> StageControl {
    if (processed == halt_after) {
      return StageControl::halt;
    }
    mismatch = mismatch || tag != value.sequence;
    ++processed;
    return StageControl::proceed;
  }
};

}  // namespace

TEST(DisruptorRing, GatesOnSlowestConsumerAndWrapsAt32Bits) {
  constexpr auto start = std::numeric_limits<sequence_t>::max() - 3U;
  SmallRing ring{start};
  auto gating = start;
  for (std::uint64_t index = 1; index <= SmallRing::capacity(); ++index) {
    ASSERT_TRUE(ring.try_publish(event(index), gating));
  }
  EXPECT_FALSE(ring.try_publish(event(9), gating)) << "full ring must refuse";
  EXPECT_EQ(distance(start, ring.cursor()), SmallRing::capacity());
  EXPECT_LT(ring.cursor(), start) << "the cursor wrapped past 2^32";
  EXPECT_EQ(ring.read(start + 7U).sequence, 8U);

  ++gating;
  ASSERT_TRUE(ring.try_publish(event(9), gating));
  EXPECT_EQ(ring.read(start + 8U).sequence, 9U);
}

TEST(DisruptorPipeline, StagesRunInOrderAndBatchSequences) {
  SmallRing ring;
  std::vector<sequence_t> seen;
  Tagging tagging{&seen};
  Checking checking;
  hft::disruptor::Pipeline<SmallRing, std::uint64_t, Tagging, Checking> pipeline{ring, tagging,
                                                                                  checking};

  for (std::uint64_t index = 1; index <= 5; ++index) {
    ASSERT_TRUE(ring.try_publish(event(index), pipeline.gating_sequence()));
  }
  EXPECT_EQ(pipeline.run(3), 3U);
  EXPECT_EQ(pipeline.gating_sequence(), 3U);
  EXPECT_EQ(pipeline.run(8), 2U);
  EXPECT_EQ(pipeline.gating_sequence(), 5U);
  EXPECT_FALSE(checking.mismatch) << "stage 2 must see stage 1's annotation";
  EXPECT_EQ(seen, (std::vector<sequence_t>{0, 1, 2, 3, 4}));
}

TEST(DisruptorPipeline, HaltLeavesTheEventForTheNextRunAndGatesTheProducer) {
  SmallRing ring;
  std::vector<sequence_t> seen;
  Tagging tagging{&seen};
  Checking checking{.halt_after = 2};
  hft::disruptor::Pipeline<SmallRing, std::uint64_t, Tagging, Checking> pipeline{ring, tagging,
                                                                                  checking};
  for (std::uint64_t index = 1; index <= 4; ++index) {
    ASSERT_TRUE(ring.try_publish(event(index), pipeline.gating_sequence()));
  }
  EXPECT_EQ(pipeline.run(8), 2U);
  EXPECT_EQ(pipeline.gating_sequence(), 2U) << "the halted event is not consumed";
  EXPECT_EQ(pipeline.stage_sequence(0), 4U) << "earlier stages keep their progress";

  checking.halt_after = std::numeric_limits<std::size_t>::max();
  EXPECT_EQ(pipeline.run(8), 2U);
  EXPECT_EQ(pipeline.gating_sequence(), 4U);
}

TEST(DisruptorLossyReader, SkipsAndCountsWhatTheProducerOverwrote) {
  SmallRing ring;
  hft::disruptor::LossyReader reader{ring};
  for (std::uint64_t index = 1; index <= 20; ++index) {
    // No gating consumer: the producer may always advance.
    ASSERT_TRUE(ring.try_publish(event(index), ring.cursor()));
  }
  std::vector<std::uint64_t> delivered;
  auto const count = reader.poll(64, [&](hft::MarketEvent const& value, sequence_t) {
    EXPECT_TRUE(intact(value));
    delivered.push_back(value.sequence);
  });
  EXPECT_EQ(count, SmallRing::capacity() - 1U);
  EXPECT_EQ(reader.dropped(), 20U - (SmallRing::capacity() - 1U));
  EXPECT_EQ(delivered.front(), 14U);
  EXPECT_EQ(delivered.back(), 20U);
}

// Run under the host-clang-tsan preset: producer, gating pipeline, and lossy
// reader on three threads must be free of data races.
TEST(DisruptorStress, ProducerPipelineAndLossyReaderAcrossThreads) {
  using Ring = hft::disruptor::Ring<hft::MarketEvent, 64>;
  constexpr std::uint64_t total = 50'000;
  Ring ring;
  struct Verifying {
    std::uint64_t expected{1};
    bool ok{true};
    auto on_event(hft::MarketEvent const& value, std::uint64_t&, sequence_t) noexcept
        -> StageControl {
      ok = ok && intact(value) && value.sequence == expected;
      ++expected;
      return StageControl::proceed;
    }
  } verifying;
  hft::disruptor::Pipeline<Ring, std::uint64_t, Verifying> pipeline{ring, verifying};
  hft::disruptor::LossyReader reader{ring};
  std::atomic<bool> produced{false};
  std::atomic<bool> lossy_ok{true};

  std::jthread producer{[&] {
    for (std::uint64_t index = 1; index <= total;) {
      if (ring.try_publish(event(index), pipeline.gating_sequence())) {
        ++index;
      } else {
        std::this_thread::yield();
      }
    }
    produced.store(true, std::memory_order_release);
  }};
  std::jthread journal{[&] {
    while (!produced.load(std::memory_order_acquire)) {
      reader.poll(16, [&](hft::MarketEvent const& value, sequence_t) {
        if (!intact(value)) {
          lossy_ok.store(false, std::memory_order_relaxed);
        }
      });
    }
  }};

  std::uint64_t consumed{};
  while (consumed < total) {
    consumed += pipeline.run(32);
  }
  producer.join();
  journal.join();
  EXPECT_TRUE(verifying.ok);
  EXPECT_EQ(verifying.expected, total + 1U);
  EXPECT_TRUE(lossy_ok.load());
  EXPECT_LE(reader.delivered() + reader.dropped(), total);
}
