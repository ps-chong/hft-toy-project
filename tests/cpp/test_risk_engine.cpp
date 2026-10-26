// Branch-free compile-time risk rules: every violation is reported, the
// first one decides, and per-rule counters advance.

#include <bit>
#include <cstdint>

#include <gtest/gtest.h>

#include "hft/risk_engine.hpp"

namespace {

constexpr auto armed_config() -> hft::RiskConfig {
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

constexpr auto intent(std::uint64_t sequence, std::uint64_t timestamp = 1) -> hft::OrderIntent {
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

using Rules = hft::RiskEngine<>::rules;

template <typename Rule>
constexpr auto bit_of() -> std::uint32_t {
  return std::uint32_t{1} << boost::mp11::mp_find<hft::DefaultRiskRules, Rule>::value;
}

}  // namespace

// The fold is constexpr: rule evaluation is verified at compile time too.
static_assert(Rules::evaluate(intent(1), armed_config(), {}) == 0U);
static_assert(Rules::size == 11);

TEST(RiskEngine, AppliesCompileTimeRuleSetAndRevision) {
  hft::RiskEngine engine{armed_config()};
  auto const result = engine.check(intent(1));
  ASSERT_TRUE(result.has_value());
  EXPECT_EQ(result->risk_revision, 7);
  EXPECT_EQ(engine.state().open_orders, 1);
}

TEST(RiskEngine, ReportsEveryViolatedRuleAndPrioritizesTheFirst) {
  auto config = armed_config();
  config.killed = true;
  auto bad = intent(1);
  bad.quantity = 0;
  bad.price = 1;
  auto const mask = Rules::evaluate(bad, config, {});
  EXPECT_EQ(mask, bit_of<hft::TradingStateRule>() | bit_of<hft::ZeroQuantityRule>() |
                      bit_of<hft::PriceCollarRule>());
  EXPECT_EQ(Rules::first_error(mask), hft::RiskError::killed);

  hft::RiskEngine engine{config};
  ASSERT_FALSE(engine.check(bad));
  auto const counts = engine.rejections();
  constexpr auto killed_index =
      boost::mp11::mp_find<hft::DefaultRiskRules, hft::TradingStateRule>::value;
  constexpr auto collar_index =
      boost::mp11::mp_find<hft::DefaultRiskRules, hft::PriceCollarRule>::value;
  EXPECT_EQ(counts[killed_index], 1U);
  EXPECT_EQ(counts[collar_index], 1U);
  EXPECT_EQ(std::popcount(mask), 3);
}

TEST(RiskEngine, RejectsKilledOversizedAndUnknownSymbol) {
  auto config = armed_config();
  config.killed = true;
  hft::RiskEngine killed{config};
  auto const killed_result = killed.check(intent(1));
  ASSERT_FALSE(killed_result);
  EXPECT_EQ(killed_result.error(), hft::RiskError::killed);

  hft::RiskEngine engine{armed_config()};
  auto oversized = intent(1);
  oversized.quantity = 101;
  auto const oversized_result = engine.check(oversized);
  ASSERT_FALSE(oversized_result);
  EXPECT_EQ(oversized_result.error(), hft::RiskError::quantity_limit);

  auto unknown = intent(2);
  unknown.symbol = hft::make_symbol("OTHER");
  auto const unknown_result = engine.check(unknown);
  ASSERT_FALSE(unknown_result);
  EXPECT_EQ(unknown_result.error(), hft::RiskError::symbol_disabled);
}

TEST(RiskEngine, EnforcesStockLocateAllowlist) {
  auto config = armed_config();
  config.allowed_locates = {1, 7};
  config.allowed_locate_count = 2;
  hft::RiskEngine engine{config};
  auto allowed = intent(1);
  allowed.stock_locate = 7;
  EXPECT_TRUE(engine.check(allowed));
  auto blocked = intent(2);
  blocked.stock_locate = 3;
  auto const result = engine.check(blocked);
  ASSERT_FALSE(result);
  EXPECT_EQ(result.error(), hft::RiskError::locate_disabled);
}

TEST(RiskEngine, RejectsStaleSequenceAndRateBurst) {
  hft::RiskEngine engine{armed_config()};
  ASSERT_TRUE(engine.check(intent(1, 1)));

  auto const stale = engine.check(intent(1, 2));
  ASSERT_FALSE(stale);
  EXPECT_EQ(stale.error(), hft::RiskError::stale_sequence);

  ASSERT_TRUE(engine.check(intent(2, 2)));
  auto const burst = engine.check(intent(3, 3));
  ASSERT_FALSE(burst);
  EXPECT_EQ(burst.error(), hft::RiskError::rate_limit);

  EXPECT_TRUE(engine.check(intent(4, 101)));
}

TEST(RiskEngine, ClockRegressionCountsAsInsideTheRateWindow) {
  hft::RiskEngine engine{armed_config()};
  ASSERT_TRUE(engine.check(intent(1, 200)));  // opens a window at t=200
  ASSERT_TRUE(engine.check(intent(2, 200)));
  // t=150 precedes the window start; unsigned subtraction used to wrap and
  // reopen the window, letting the burst through.
  auto const regressed = engine.check(intent(3, 150));
  ASSERT_FALSE(regressed);
  EXPECT_EQ(regressed.error(), hft::RiskError::rate_limit);
}

TEST(RiskEngine, TracksOpenOrders) {
  auto config = armed_config();
  config.max_orders_per_window = 10;
  config.max_open_orders = 1;
  hft::RiskEngine engine{config};

  ASSERT_TRUE(engine.check(intent(1)));
  auto const full = engine.check(intent(2));
  ASSERT_FALSE(full);
  EXPECT_EQ(full.error(), hft::RiskError::open_order_limit);

  engine.on_order_closed();
  EXPECT_TRUE(engine.check(intent(3)));
}

TEST(RiskEngine, RejectsMalformedOrderFields) {
  hft::RiskEngine engine{armed_config()};

  auto invalid_side = intent(1);
  invalid_side.side = hft::Side::unknown;
  auto const invalid_side_result = engine.check(invalid_side);
  ASSERT_FALSE(invalid_side_result);
  EXPECT_EQ(invalid_side_result.error(), hft::RiskError::invalid_side);

  auto zero = intent(2);
  zero.quantity = 0;
  auto const zero_result = engine.check(zero);
  ASSERT_FALSE(zero_result);
  EXPECT_EQ(zero_result.error(), hft::RiskError::zero_quantity);

  auto outside_collar = intent(3);
  outside_collar.price = 111;
  auto const price_result = engine.check(outside_collar);
  ASSERT_FALSE(price_result);
  EXPECT_EQ(price_result.error(), hft::RiskError::price_collar);
}
