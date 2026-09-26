#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "hft/config_snapshot.hpp"
#include "hft/cooperative_executor.hpp"
#include "hft/order_manager.hpp"
#include "hft/risk_engine.hpp"
#include "hft/spsc_ring.hpp"

namespace {

class MockClock {
public:
  MOCK_METHOD(std::uint64_t, now_ns, (), (noexcept));
};

auto config() -> hft::RiskConfig {
  return {
      .armed = true,
      .killed = false,
      .max_orders_per_window = 100,
      .max_open_orders = 100,
  };
}

auto event(std::uint64_t sequence) -> hft::MarketEvent {
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

TEST(CooperativeExecutor, HonorsBatchBudgetAndYields) {
  hft::SpscRing<hft::MarketEvent, 8> events;
  hft::SpscRing<hft::OrderIntent, 8> intents;
  MockClock clock;
  hft::RiskEngine risk{config()};
  hft::OrderManager manager{clock, risk};
  hft::ConfigSnapshot snapshot{config()};
  hft::CooperativeExecutor executor{events, intents, manager, snapshot};

  ASSERT_TRUE(events.try_push(event(1)));
  ASSERT_TRUE(events.try_push(event(2)));
  ASSERT_TRUE(events.try_push(event(3)));
  EXPECT_CALL(clock, now_ns())
      .WillOnce(testing::Return(10))
      .WillOnce(testing::Return(11))
      .WillOnce(testing::Return(12));

  EXPECT_EQ(executor.run_batch(2), 2);
  EXPECT_EQ(executor.stats().events, 2);
  EXPECT_EQ(executor.stats().yields, 1);
  EXPECT_EQ(events.size_approx(), 1);
  EXPECT_EQ(intents.size_approx(), 2);

  EXPECT_EQ(executor.run_batch(2), 1);
  EXPECT_EQ(executor.stats().events, 3);
  EXPECT_EQ(executor.stats().yields, 2);
}

TEST(CooperativeExecutor, FailsClosedWhenIntentRingIsFull) {
  hft::SpscRing<hft::MarketEvent, 8> events;
  hft::SpscRing<hft::OrderIntent, 2> intents;
  MockClock clock;
  hft::RiskEngine risk{config()};
  hft::OrderManager manager{clock, risk};
  hft::ConfigSnapshot snapshot{config()};
  hft::CooperativeExecutor executor{events, intents, manager, snapshot};

  ASSERT_TRUE(events.try_push(event(1)));
  ASSERT_TRUE(events.try_push(event(2)));
  ASSERT_TRUE(events.try_push(event(3)));
  EXPECT_CALL(clock, now_ns()).Times(3).WillRepeatedly(testing::Return(10));

  EXPECT_EQ(executor.run_batch(8), 3);
  EXPECT_TRUE(executor.fault_latched());
  EXPECT_EQ(executor.stats().output_overflows, 1);
  EXPECT_EQ(intents.size_approx(), 2);
}
