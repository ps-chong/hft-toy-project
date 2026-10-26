// The R5 control actor: coroutine frames in a fixed arena, and risk_config
// validation, publication and stale-revision rejection.

#include <bit>
#include <coroutine>
#include <cstdint>
#include <vector>

#include <gtest/gtest.h>

#include "hft/control_task.hpp"

namespace {

struct FrameProbe {
  std::uintptr_t address{};
};

// See control_task.hpp: GCC false positive for leading-allocator coroutines.
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmismatched-new-delete"
#endif
auto two_step(hft::FrameArena<512>& /*arena*/, std::vector<int>& trace, FrameProbe& probe)
    -> hft::ControlTask {
  int local = 0;
  probe.address = std::bit_cast<std::uintptr_t>(&local);
  trace.push_back(1);
  co_await std::suspend_always{};
  trace.push_back(2);
}
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif

struct CountingLog {
  std::vector<hft::LogMessage> messages;
  auto log(hft::LogLevel, hft::LogMessage message, std::uint64_t = 0, std::uint64_t = 0) noexcept
      -> void {
    messages.push_back(message);
  }
};

auto record(std::uint32_t revision) -> hft::RiskConfigRecord {
  return {.flags = std::to_underlying(hft::ConfigFlag::armed),
          .revision = revision,
          .max_quantity = 10,
          .max_orders_per_window = 10,
          .price_floor = 1,
          .price_ceiling = 100,
          .rate_window_ns = 1'000,
          .max_open_orders = 10};
}

}  // namespace

TEST(ControlTask, ResumesCooperativelyInsideItsArena) {
  hft::FrameArena<512> arena;
  std::vector<int> trace;
  FrameProbe probe;
  auto task = two_step(arena, trace, probe);
  ASSERT_TRUE(task);
  EXPECT_TRUE(arena.in_use());
  EXPECT_TRUE(trace.empty());

  EXPECT_TRUE(task.resume());
  ASSERT_EQ(trace.size(), 1U);
  EXPECT_FALSE(task.resume());
  ASSERT_EQ(trace.size(), 2U);
}

// Regression: the frame buffer used to be a byte array with alignment 1.
TEST(ControlTask, FrameStorageHasDefaultNewAlignment) {
  hft::FrameArena<512> arena;
  EXPECT_EQ(std::bit_cast<std::uintptr_t>(arena.address()) %
                __STDCPP_DEFAULT_NEW_ALIGNMENT__,
            0U);
}

TEST(ControlTask, BusyArenaFailsAllocationAndReleasesOnDestroy) {
  hft::FrameArena<512> arena;
  std::vector<int> trace;
  FrameProbe probe;
  {
    auto first = two_step(arena, trace, probe);
    auto second = two_step(arena, trace, probe);
    EXPECT_TRUE(first);
    EXPECT_FALSE(second);
  }
  EXPECT_FALSE(arena.in_use());
  auto third = two_step(arena, trace, probe);
  EXPECT_TRUE(third);
}

TEST(ControlActor, ValidatesPublishesAndRejectsStaleRevisions) {
  hft::FrameArena<1024> arena;
  hft::ControlMailbox mailbox;
  hft::TripleBuffer<hft::RiskConfig> configs{hft::RiskConfig{}};
  hft::KillSwitch kill;
  CountingLog log;
  auto actor = hft::control_actor(arena, mailbox, configs, kill, log, 1);
  ASSERT_TRUE(actor.resume());

  ASSERT_TRUE(mailbox.deliver(record(2)));
  ASSERT_TRUE(configs.has_fresh());
  EXPECT_EQ(configs.acquire().revision, 2U);
  EXPECT_TRUE(configs.acquire().armed);

  ASSERT_TRUE(mailbox.deliver(record(2)));
  EXPECT_FALSE(configs.has_fresh()) << "replayed revisions are ignored";
  EXPECT_FALSE(kill.latched()) << "a stale revision alone does not kill";
  EXPECT_EQ(log.messages.back(), hft::LogMessage::config_rejected);
}

TEST(ControlActor, DecodeRejectsEveryInvalidRecordClass) {
  auto const base = record(5);
  EXPECT_TRUE(hft::decode_risk_config(base, 4));

  auto abi = base;
  abi.abi_version = 99;
  EXPECT_EQ(hft::decode_risk_config(abi, 4).error(), hft::ConfigError::abi_mismatch);
  EXPECT_EQ(hft::decode_risk_config(base, 5).error(), hft::ConfigError::stale_revision);
  auto collar = base;
  collar.price_floor = 200;
  EXPECT_EQ(hft::decode_risk_config(collar, 4).error(), hft::ConfigError::invalid_collar);
  auto limits = base;
  limits.rate_window_ns = 0;
  EXPECT_EQ(hft::decode_risk_config(limits, 4).error(), hft::ConfigError::invalid_limits);
  auto locates = base;
  locates.allowed_locate_count = 9;
  EXPECT_EQ(hft::decode_risk_config(locates, 4).error(), hft::ConfigError::invalid_locates);
  auto strategy = base;
  strategy.strategy_id = 7;
  EXPECT_EQ(hft::decode_risk_config(strategy, 4).error(), hft::ConfigError::unknown_strategy);
}
