#include <gtest/gtest.h>

#include "hft/risk_engine.hpp"

namespace {

auto armed_config() -> hft::RiskConfig {
  return {
      .armed = true,
      .killed = false,
      .revision = 7,
      .max_quantity = 100,
      .price_floor = 90,
      .price_ceiling = 110,
      .max_orders_per_window = 2,
      .rate_window_ns = 100,
      .max_open_orders = 3,
      .allowed_symbols = {hft::make_symbol("ACME")},
      .allowed_symbol_count = 1,
  };
}

auto intent(std::uint64_t sequence, std::uint64_t timestamp = 1)
    -> hft::OrderIntent {
  return {
      .action = hft::OrderAction::enter,
      .side = hft::Side::buy,
      .source_sequence = sequence,
      .decision_timestamp_ns = timestamp,
      .symbol = hft::make_symbol("ACME"),
      .price = 100,
      .quantity = 10,
  };
}

}  // namespace

TEST(RiskEngine, AppliesCompileTimeRuleSetAndRevision) {
  hft::RiskEngine engine{armed_config()};
  auto result = engine.check(intent(1));
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(result.assume_value().risk_revision, 7);
  EXPECT_EQ(engine.state().open_orders, 1);
}

TEST(RiskEngine, RejectsKilledOversizedAndUnknownSymbol) {
  auto config = armed_config();
  config.killed = true;
  hft::RiskEngine killed{config};
  auto killed_result = killed.check(intent(1));
  ASSERT_FALSE(killed_result);
  EXPECT_EQ(killed_result.assume_error(), hft::RiskError::killed);

  hft::RiskEngine engine{armed_config()};
  auto oversized = intent(1);
  oversized.quantity = 101;
  auto oversized_result = engine.check(oversized);
  ASSERT_FALSE(oversized_result);
  EXPECT_EQ(oversized_result.assume_error(), hft::RiskError::quantity_limit);

  auto unknown = intent(2);
  unknown.symbol = hft::make_symbol("OTHER");
  auto unknown_result = engine.check(unknown);
  ASSERT_FALSE(unknown_result);
  EXPECT_EQ(unknown_result.assume_error(), hft::RiskError::symbol_disabled);
}

TEST(RiskEngine, RejectsStaleSequenceAndRateBurst) {
  hft::RiskEngine engine{armed_config()};
  ASSERT_TRUE(engine.check(intent(1, 1)));

  auto stale = engine.check(intent(1, 2));
  ASSERT_FALSE(stale);
  EXPECT_EQ(stale.assume_error(), hft::RiskError::stale_sequence);

  ASSERT_TRUE(engine.check(intent(2, 2)));
  auto burst = engine.check(intent(3, 3));
  ASSERT_FALSE(burst);
  EXPECT_EQ(burst.assume_error(), hft::RiskError::rate_limit);

  auto next_window = engine.check(intent(4, 101));
  EXPECT_TRUE(next_window);
}

TEST(RiskEngine, TracksOpenOrders) {
  auto config = armed_config();
  config.max_orders_per_window = 10;
  config.max_open_orders = 1;
  hft::RiskEngine engine{config};

  ASSERT_TRUE(engine.check(intent(1)));
  auto full = engine.check(intent(2));
  ASSERT_FALSE(full);
  EXPECT_EQ(full.assume_error(), hft::RiskError::open_order_limit);

  engine.on_order_closed();
  EXPECT_TRUE(engine.check(intent(3)));
}

TEST(RiskEngine, RejectsMalformedOrderFields) {
  hft::RiskEngine engine{armed_config()};

  auto invalid_side = intent(1);
  invalid_side.side = hft::Side::unknown;
  auto invalid_side_result = engine.check(invalid_side);
  ASSERT_FALSE(invalid_side_result);
  EXPECT_EQ(invalid_side_result.assume_error(), hft::RiskError::invalid_side);

  auto zero = intent(2);
  zero.quantity = 0;
  auto zero_result = engine.check(zero);
  ASSERT_FALSE(zero_result);
  EXPECT_EQ(zero_result.assume_error(), hft::RiskError::zero_quantity);

  auto outside_collar = intent(3);
  outside_collar.price = 111;
  auto price_result = engine.check(outside_collar);
  ASSERT_FALSE(price_result);
  EXPECT_EQ(price_result.assume_error(), hft::RiskError::price_collar);
}
