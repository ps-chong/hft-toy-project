// RAII owners: interrupt registration released exactly once, and the
// bitmap-backed FixedPool behind std::unique_ptr.

#include <cstdint>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "hft/raii.hpp"

namespace {

class MockInterruptController {
public:
  MOCK_METHOD(bool, register_irq, (std::uint32_t), (noexcept));
  MOCK_METHOD(void, unregister_irq, (std::uint32_t), (noexcept));
};

struct Tracked {
  explicit Tracked(int& destructions) : destructions_(&destructions) {}
  ~Tracked() { ++*destructions_; }

  Tracked(Tracked const&) = delete;
  auto operator=(Tracked const&) -> Tracked& = delete;
  Tracked(Tracked&&) = delete;
  auto operator=(Tracked&&) -> Tracked& = delete;

  int* destructions_;
};

}  // namespace

TEST(ScopedInterrupt, UnregistersExactlyOnceAfterMove) {
  MockInterruptController controller;
  EXPECT_CALL(controller, register_irq(7)).WillOnce(testing::Return(true));
  EXPECT_CALL(controller, unregister_irq(7)).Times(1);

  {
    auto first = hft::make_scoped_interrupt(controller, 7);
    ASSERT_TRUE(first);
    auto second = std::move(first);
    EXPECT_TRUE(second);
    EXPECT_FALSE(first);  // NOLINT(bugprone-use-after-move): moved-from state is specified
  }
}

TEST(ScopedInterrupt, DoesNotUnregisterFailedRegistration) {
  MockInterruptController controller;
  EXPECT_CALL(controller, register_irq(9)).WillOnce(testing::Return(false));
  EXPECT_CALL(controller, unregister_irq(testing::_)).Times(0);
  auto const interrupt = hft::make_scoped_interrupt(controller, 9);
  EXPECT_FALSE(interrupt);
}

TEST(FixedPool, UsesUniquePointerCustomDeleterWithoutHeapOwnership) {
  int destructions = 0;
  hft::FixedPool<Tracked, 2> pool;
  EXPECT_EQ(pool.available(), 2);

  auto first = pool.acquire(destructions);
  auto second = pool.acquire(destructions);
  auto exhausted = pool.acquire(destructions);
  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  EXPECT_FALSE(exhausted);
  EXPECT_EQ(pool.available(), 0);

  first.reset();
  EXPECT_EQ(destructions, 1);
  EXPECT_EQ(pool.available(), 1);
  second.reset();
  EXPECT_EQ(destructions, 2);
  EXPECT_EQ(pool.available(), 2);
}

TEST(FixedPool, BitmapSpansWordsAndReusesTheLowestFreeSlot) {
  int destructions = 0;
  hft::FixedPool<Tracked, 70> pool;
  EXPECT_EQ(pool.available(), 70);
  std::vector<hft::FixedPool<Tracked, 70>::pointer> held;
  for (int index = 0; index < 70; ++index) {
    held.push_back(pool.acquire(destructions));
    ASSERT_TRUE(held.back());
  }
  EXPECT_FALSE(pool.acquire(destructions));
  auto* const slot_65 = held[65].get();
  auto* const slot_3 = held[3].get();
  held[65].reset();
  held[3].reset();
  EXPECT_EQ(pool.available(), 2);
  auto reused = pool.acquire(destructions);
  EXPECT_EQ(reused.get(), slot_3);
  auto next = pool.acquire(destructions);
  EXPECT_EQ(next.get(), slot_65);
}
