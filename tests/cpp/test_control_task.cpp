#include <vector>

#include <gtest/gtest.h>

#include "hft/control_task.hpp"

namespace {

auto two_step(std::vector<int>& trace) -> hft::ControlTask<> {
  trace.push_back(1);
  co_await std::suspend_always{};
  trace.push_back(2);
}

}  // namespace

TEST(ControlTask, ResumesCooperativelyAndOwnsFrame) {
  std::vector<int> trace;
  auto task = two_step(trace);
  ASSERT_TRUE(task);
  EXPECT_TRUE(trace.empty());

  EXPECT_TRUE(task.resume());
  ASSERT_EQ(trace.size(), 1);
  EXPECT_EQ(trace[0], 1);

  EXPECT_FALSE(task.resume());
  ASSERT_EQ(trace.size(), 2);
  EXPECT_EQ(trace[1], 2);
}

TEST(ControlTask, FailsAllocationWhenStaticFrameIsBusy) {
  std::vector<int> trace;
  auto first = two_step(trace);
  auto second = two_step(trace);
  EXPECT_TRUE(first);
  EXPECT_FALSE(second);
}
