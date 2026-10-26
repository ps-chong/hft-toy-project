// FirmwareApp end to end on the host: market events through the Disruptor
// pipeline to intents, and every fail-closed path (overflow, feed gap,
// invalid control records) with its operator clear.

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include <gtest/gtest.h>

#include "hft/app.hpp"

namespace {

struct Clock {
  std::uint64_t now{100};
  [[nodiscard]] auto now_ns() noexcept -> std::uint64_t { return now++; }
};

struct Sink {
  std::vector<std::string> lines;
  auto write(std::string_view line) noexcept -> void { lines.emplace_back(line); }
};

auto armed(std::uint32_t revision = 1) -> hft::RiskConfig {
  return {
      .armed = true,
      .killed = false,
      .revision = revision,
      .max_orders_per_window = 5'000,
      .max_open_orders = 5'000,
  };
}

auto add_event(std::uint64_t sequence) -> hft::MarketEvent {
  return {
      .kind = hft::EventKind::add,
      .side = hft::Side::sell,
      .sequence = sequence,
      .symbol = hft::make_symbol("ACME"),
      .price = 100,
      .quantity = 10,
  };
}

auto control_record(std::uint32_t revision, std::uint16_t flags) -> hft::RiskConfigRecord {
  return {
      .flags = flags,
      .revision = revision,
      .max_quantity = 1'000,
      .max_orders_per_window = 5'000,
      .price_floor = 1,
      .price_ceiling = 1'000'000,
      .rate_window_ns = 1'000'000,
      .max_open_orders = 5'000,
  };
}

constexpr auto armed_flags = std::to_underlying(hft::ConfigFlag::armed);
constexpr auto clear_flags = armed_flags | std::to_underlying(hft::ConfigFlag::clear_kill);

auto collect(auto& app) -> std::vector<hft::OrderIntent> {
  std::vector<hft::OrderIntent> intents;
  static_cast<void>(app.drain_intents([&](hft::OrderIntent const& intent) noexcept {
    intents.push_back(intent);
    return true;
  }));
  return intents;
}

}  // namespace

TEST(FirmwareApp, RunsCompleteMarketToIntentSlice) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  ASSERT_TRUE(app.publish_market_event(add_event(1)));
  EXPECT_EQ(app.run_trading(8), 1);
  auto const intents = collect(app);
  ASSERT_EQ(intents.size(), 1U);
  EXPECT_EQ(intents[0].source_sequence, 1U);
  EXPECT_EQ(intents[0].side, hft::Side::buy);
  EXPECT_EQ(app.stats().counters.intents, 1U);
  EXPECT_FALSE(app.kill_switch().latched());

  auto killed = armed(2);
  killed.killed = true;
  app.publish_config(killed);
  ASSERT_TRUE(app.publish_market_event(add_event(2)));
  EXPECT_EQ(app.run_trading(8), 1);
  EXPECT_TRUE(collect(app).empty());
  EXPECT_EQ(app.stats().counters.rejected, 1U);
}

// Regression: the old executor re-applied the published configuration at the
// start of every batch, silently lifting the overflow kill on the next one.
TEST(FirmwareApp, IntentOverflowKillSurvivesLaterBatchesAndConfigs) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  constexpr auto capacity = decltype(app)::intent_capacity;
  for (std::uint64_t sequence = 1; sequence <= capacity + 1; ++sequence) {
    ASSERT_TRUE(app.publish_market_event(add_event(sequence)));
  }
  static_cast<void>(app.run_trading(capacity + 1));
  EXPECT_TRUE(app.kill_switch().latched());
  EXPECT_EQ(app.stats().counters.output_overflows, 1U);

  // Later batches, and a freshly published armed config, stay killed.
  app.publish_config(armed(2));
  static_cast<void>(collect(app));
  ASSERT_TRUE(app.publish_market_event(add_event(capacity + 2)));
  static_cast<void>(app.run_trading(64));
  EXPECT_TRUE(collect(app).empty());
  EXPECT_TRUE(app.kill_switch().latched());
}

TEST(FirmwareApp, OperatorClearWithNewerRevisionResumesTrading) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  app.kill_switch().trip(hft::KillReason::runtime_fault, 1);

  ASSERT_TRUE(app.deliver_config(control_record(2, clear_flags)));
  ASSERT_TRUE(app.publish_market_event(add_event(1)));
  static_cast<void>(app.run_trading(8));
  EXPECT_FALSE(app.kill_switch().latched());
  EXPECT_EQ(collect(app).size(), 1U);
}

TEST(FirmwareApp, FeedGapFlagLatchesKillUntilOperatorClears) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  auto gapped = add_event(1);
  gapped.flags = hft::event_flag_feed_gap;
  ASSERT_TRUE(app.publish_market_event(gapped));
  static_cast<void>(app.run_trading(8));
  EXPECT_TRUE(app.kill_switch().latched());
  EXPECT_EQ(app.kill_switch().reasons(), std::to_underlying(hft::KillReason::feed_gap));
  EXPECT_TRUE(collect(app).empty()) << "the gapped event's intent is suppressed at publish";

  ASSERT_TRUE(app.deliver_config(control_record(2, clear_flags)));
  ASSERT_TRUE(app.publish_market_event(add_event(2)));
  static_cast<void>(app.run_trading(8));
  EXPECT_EQ(collect(app).size(), 1U);
}

TEST(FirmwareApp, InvalidControlRecordFailsClosed) {
  Clock clock;
  Sink sink;
  hft::FirmwareApp app{clock, armed()};
  auto bad = control_record(2, armed_flags);
  bad.price_floor = 10;
  bad.price_ceiling = 5;
  ASSERT_TRUE(app.deliver_config(bad));
  EXPECT_TRUE(app.kill_switch().latched());

  ASSERT_TRUE(app.publish_market_event(add_event(1)));
  static_cast<void>(app.run_trading(8));
  EXPECT_TRUE(collect(app).empty());
  static_cast<void>(app.drain_logs(sink));
  ASSERT_FALSE(sink.lines.empty());
  EXPECT_EQ(sink.lines.front(), "ERROR risk config revision 2 rejected (reason 3)");
}

TEST(FirmwareApp, FailsClosedWhenMarketRingOverflows) {
  Clock clock;
  Sink sink;
  hft::FirmwareApp app{clock, armed()};
  constexpr auto capacity = decltype(app)::event_capacity;
  for (std::uint64_t sequence = 1; sequence <= capacity; ++sequence) {
    ASSERT_TRUE(app.publish_market_event(add_event(sequence)));
  }
  EXPECT_EQ(app.ring_free(), 0U);
  EXPECT_FALSE(app.publish_market_event(add_event(capacity + 1)));
  EXPECT_TRUE(app.kill_switch().latched());

  static_cast<void>(app.drain_logs(sink));
  ASSERT_EQ(sink.lines.size(), 1U);
  EXPECT_EQ(sink.lines[0], "ERROR market ring overflow; trading killed");
  static_cast<void>(app.run_trading(1));
  EXPECT_EQ(app.stats().market_overflows, 1U);
}

// Regression: a refused intent used to be popped and lost without a counter.
TEST(FirmwareApp, RefusedIntentStaysQueuedAndIsCounted) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  ASSERT_TRUE(app.publish_market_event(add_event(1)));
  static_cast<void>(app.run_trading(8));

  EXPECT_EQ(app.drain_intents([](hft::OrderIntent const&) noexcept { return false; }), 0U);
  static_cast<void>(app.run_trading(1));
  EXPECT_EQ(app.stats().counters.publish_failures, 1U);
  EXPECT_EQ(collect(app).size(), 1U);
}

TEST(FirmwareApp, JournalSeesEveryEventWithoutGatingTheProducer) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  for (std::uint64_t sequence = 1; sequence <= 3; ++sequence) {
    ASSERT_TRUE(app.publish_market_event(add_event(sequence)));
  }
  std::vector<std::uint64_t> journaled;
  EXPECT_EQ(app.poll_journal(8,
                             [&](hft::MarketEvent const& event, auto) noexcept {
                               journaled.push_back(event.sequence);
                             }),
            3U);
  EXPECT_EQ(journaled, (std::vector<std::uint64_t>{1, 2, 3}));
  EXPECT_EQ(app.journal_dropped(), 0U);
}

TEST(FirmwareApp, WarmUpLeavesLiveStateUntouched) {
  Clock clock;
  hft::FirmwareApp app{clock, armed()};
  app.warm_up(32);
  ASSERT_TRUE(app.publish_market_event(add_event(1)));
  static_cast<void>(app.run_trading(8));
  auto const intents = collect(app);
  ASSERT_EQ(intents.size(), 1U);
  EXPECT_EQ(intents[0].user_ref, 1U);
}
