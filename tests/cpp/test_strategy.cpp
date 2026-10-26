// std::variant strategies and the wire-id selector.

#include <cstdint>

#include <gtest/gtest.h>

#include "hft/strategy.hpp"

namespace {

auto add(std::uint64_t sequence, hft::Side side, std::uint32_t quantity) -> hft::MarketEvent {
  return {.kind = hft::EventKind::add,
          .side = side,
          .sequence = sequence,
          .symbol = hft::make_symbol("ACME"),
          .price = 100 + sequence,
          .quantity = quantity};
}

}  // namespace

TEST(Strategy, MirrorTakesTheOtherSideCappedAtOrderQuantity) {
  hft::MirrorStrategy mirror{.order_quantity = 3};
  auto const intent = mirror.evaluate(add(1, hft::Side::sell, 10));
  ASSERT_TRUE(intent);
  EXPECT_EQ(intent->side, hft::Side::buy);
  EXPECT_EQ(intent->quantity, 3U);
  EXPECT_FALSE(mirror.evaluate(hft::MarketEvent{.kind = hft::EventKind::trade}));
}

TEST(Strategy, ImbalanceTradesWithAccumulatedPressure) {
  hft::ImbalanceStrategy imbalance;
  EXPECT_FALSE(imbalance.evaluate(add(1, hft::Side::buy, 100)));
  // Buy volume (100) now outweighs sell volume (10) by more than 2x, so an
  // incoming offer is lifted.
  auto const lift = imbalance.evaluate(add(2, hft::Side::sell, 10));
  ASSERT_TRUE(lift);
  EXPECT_EQ(lift->side, hft::Side::buy);
  EXPECT_EQ(lift->price, 102U);
}

TEST(Strategy, SelectorSwitchesByWireIdAndRefusesUnknownIds) {
  hft::StrategySelector selector;
  EXPECT_EQ(selector.active_id(), 0U);
  EXPECT_TRUE(selector.evaluate(add(1, hft::Side::sell, 5)));

  ASSERT_TRUE(selector.select(1));
  EXPECT_EQ(selector.active_id(), 1U);
  EXPECT_FALSE(selector.evaluate(add(2, hft::Side::sell, 5)))
      << "a fresh imbalance strategy has no accumulated pressure";

  EXPECT_FALSE(selector.select(hft::StrategySelector::count));
  EXPECT_EQ(selector.active_id(), 1U);
}
