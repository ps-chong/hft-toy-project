// Sticky kill switch: trips win races, and only a newer revision clears.

#include <utility>

#include <gtest/gtest.h>

#include "hft/kill_switch.hpp"

TEST(KillSwitch, StartsClearAndTripsSticky) {
  hft::KillSwitch kill;
  EXPECT_FALSE(kill.latched());
  kill.trip(hft::KillReason::intent_ring_overflow, 5);
  EXPECT_TRUE(kill.latched());
  EXPECT_EQ(kill.reasons(), std::to_underlying(hft::KillReason::intent_ring_overflow));
}

TEST(KillSwitch, OnlyANewerRevisionClears) {
  hft::KillSwitch kill;
  kill.trip(hft::KillReason::market_ring_overflow, 5);
  EXPECT_FALSE(kill.clear(4));
  EXPECT_FALSE(kill.clear(5));
  EXPECT_TRUE(kill.latched());
  EXPECT_TRUE(kill.clear(6));
  EXPECT_FALSE(kill.latched());
}

TEST(KillSwitch, AccumulatesReasonsAndChangesVersionOnEveryTransition) {
  hft::KillSwitch kill;
  auto const initial = kill.version();
  kill.trip(hft::KillReason::operator_request, 1);
  auto const after_first = kill.version();
  kill.trip(hft::KillReason::operator_request, 1);
  EXPECT_NE(kill.version(), after_first) << "a repeated reason must still bump the epoch";
  kill.trip(hft::KillReason::invalid_config, 1);
  EXPECT_EQ(kill.reasons(), std::to_underlying(hft::KillReason::operator_request) |
                                std::to_underlying(hft::KillReason::invalid_config));
  EXPECT_NE(kill.version(), initial);
  EXPECT_TRUE(kill.clear(2));
  EXPECT_EQ(kill.reasons(), 0U);
}

TEST(KillSwitch, ClearOnUntrippedSwitchIsANoOp) {
  hft::KillSwitch kill;
  EXPECT_TRUE(kill.clear(0));
  EXPECT_FALSE(kill.latched());
}
