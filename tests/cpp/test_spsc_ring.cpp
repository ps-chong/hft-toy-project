#include <cstdint>

#include <gtest/gtest.h>

#include "hft/spsc_ring.hpp"

TEST(SpscRing, PreservesOrderAndWraps) {
  hft::SpscRing<std::uint32_t, 4> ring;

  EXPECT_TRUE(ring.empty());
  EXPECT_TRUE(ring.try_push(1));
  EXPECT_TRUE(ring.try_push(2));
  EXPECT_EQ(ring.try_pop(), 1);
  EXPECT_TRUE(ring.try_push(3));
  EXPECT_TRUE(ring.try_push(4));
  EXPECT_TRUE(ring.try_push(5));
  EXPECT_FALSE(ring.try_push(6));

  EXPECT_EQ(ring.try_pop(), 2);
  EXPECT_EQ(ring.try_pop(), 3);
  EXPECT_EQ(ring.try_pop(), 4);
  EXPECT_EQ(ring.try_pop(), 5);
  EXPECT_FALSE(ring.try_pop().has_value());
}

TEST(SpscRing, ReportsApproximateSize) {
  hft::SpscRing<std::uint32_t, 8> ring;
  EXPECT_EQ(ring.capacity(), 8);
  EXPECT_EQ(ring.size_approx(), 0);
  ASSERT_TRUE(ring.try_push(10));
  ASSERT_TRUE(ring.try_push(11));
  EXPECT_EQ(ring.size_approx(), 2);
  ASSERT_TRUE(ring.try_pop());
  EXPECT_EQ(ring.size_approx(), 1);
}
