// Wait-free triple buffer: whole snapshots only, newest first, never torn
// under a concurrent reader.

#include <atomic>
#include <cstdint>
#include <thread>

#include <gtest/gtest.h>

#include "hft/risk_engine.hpp"
#include "hft/triple_buffer.hpp"

TEST(TripleBuffer, PublishesWholeSnapshotAtSafePoint) {
  hft::RiskConfig initial{.armed = false, .killed = true, .revision = 1};
  hft::TripleBuffer buffer{initial};

  auto observed = buffer.acquire();
  EXPECT_FALSE(observed.armed);
  EXPECT_TRUE(observed.killed);
  EXPECT_EQ(observed.revision, 1);

  auto next = initial;
  next.armed = true;
  next.killed = false;
  next.revision = 2;
  next.allowed_symbols[0] = hft::make_symbol("ACME");
  next.allowed_symbol_count = 1;
  buffer.publish(next);
  EXPECT_TRUE(buffer.has_fresh());

  observed = buffer.acquire();
  EXPECT_FALSE(buffer.has_fresh());
  EXPECT_TRUE(observed.armed);
  EXPECT_FALSE(observed.killed);
  EXPECT_EQ(observed.revision, 2);
  EXPECT_EQ(observed.allowed_symbols[0], hft::make_symbol("ACME"));
}

TEST(TripleBuffer, ReaderAlwaysGetsNewestAndKeepsItUntilNextPublish) {
  hft::TripleBuffer<std::uint64_t> buffer{0};
  buffer.publish(1);
  buffer.publish(2);
  buffer.publish(3);
  EXPECT_EQ(buffer.acquire(), 3U);
  EXPECT_EQ(buffer.acquire(), 3U);
  buffer.publish(4);
  EXPECT_EQ(buffer.acquire(), 4U);
}

namespace {

// The writer keeps `check == ~value`; a torn copy would break the relation.
struct Paired {
  std::uint64_t value{};
  std::uint64_t padding[6]{};
  std::uint64_t check{~std::uint64_t{0}};
};

}  // namespace

TEST(TripleBuffer, ConcurrentReaderNeverSeesTornOrStaleSnapshot) {
  hft::TripleBuffer<Paired> buffer{Paired{}};
  std::atomic<bool> done{false};
  constexpr std::uint64_t rounds = 100'000;

  std::jthread writer{[&] {
    for (std::uint64_t value = 1; value <= rounds; ++value) {
      buffer.publish(Paired{.value = value, .check = ~value});
    }
    done.store(true, std::memory_order_release);
  }};

  std::uint64_t last{};
  while (!done.load(std::memory_order_acquire)) {
    auto const& snapshot = buffer.acquire();
    ASSERT_EQ(snapshot.check, ~snapshot.value);
    ASSERT_GE(snapshot.value, last);
    last = snapshot.value;
  }
  writer.join();
  EXPECT_EQ(buffer.acquire().value, rounds);
}
