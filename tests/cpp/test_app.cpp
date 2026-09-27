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
  std::vector<std::string> messages;
  auto write(std::string_view message) -> void { messages.emplace_back(message); }
};

auto armed() -> hft::RiskConfig {
  return {
      .armed = true,
      .killed = false,
      .max_orders_per_window = 2'000,
      .max_open_orders = 2'000,
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

}  // namespace

TEST(FirmwareApp, RunsCompleteMarketToIntentSlice) {
  Clock clock;
  Sink sink;
  hft::FirmwareApp app{clock, sink, armed()};
  ASSERT_TRUE(app.publish_market_event(add_event(1)));
  EXPECT_EQ(app.run_once(8), 1);
  auto intent = app.next_intent();
  ASSERT_TRUE(intent);
  EXPECT_EQ(intent->source_sequence, 1);
  EXPECT_EQ(intent->side, hft::Side::buy);
  EXPECT_EQ(app.stats().intents, 1);
  EXPECT_FALSE(app.fault_latched());

  auto killed = armed();
  killed.killed = true;
  app.publish_config(killed);
  ASSERT_TRUE(app.publish_market_event(add_event(2)));
  EXPECT_EQ(app.run_once(8), 1);
  EXPECT_FALSE(app.next_intent());
  EXPECT_EQ(app.stats().rejected, 1);
}

TEST(FirmwareApp, FailsClosedWhenMarketRingOverflows) {
  Clock clock;
  Sink sink;
  hft::FirmwareApp app{clock, sink, armed()};
  for (std::uint64_t sequence = 1; sequence <= 1024; ++sequence) {
    ASSERT_TRUE(app.publish_market_event(add_event(sequence)));
  }
  EXPECT_FALSE(app.publish_market_event(add_event(1025)));
  ASSERT_EQ(sink.messages.size(), 1);
  EXPECT_EQ(sink.messages[0], "ERROR market ring overflow; trading killed");
}
