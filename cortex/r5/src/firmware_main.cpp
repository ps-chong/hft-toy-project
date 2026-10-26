// R5 firmware entry point.
//
// All long-lived state lives in one function-local static Runtime, built by
// main() before the scheduler starts and passed to each FreeRTOS task
// through pvParameters. The only other definitions at namespace scope are the
// weak C hooks that let the freestanding CI target link without the AMD BSP.

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <string_view>

#include "hft/app.hpp"
#include "hft/platform.h"

#if defined(HFT_WITH_XILINX_FREERTOS)
extern "C" {
#include "FreeRTOS.h"
#include "task.h"
}
// The BSP linker script maps these sections to the zero-wait-state R5 TCMs.
#define HFT_TCM_TEXT [[gnu::section(".hft_atcm_text"), gnu::hot]]
#else
#define HFT_TCM_TEXT [[gnu::hot]]
#endif

// Fallback hooks for the freestanding link. The BSP build provides strong
// definitions; see hft/platform.h for each hook's calling context.
extern "C" {

[[gnu::weak]] auto hft_platform_now_ns() noexcept -> std::uint64_t {
  // Only the trading task calls this hook, so a plain counter is race-free.
  static std::uint64_t fallback_ticks{};
  return ++fallback_ticks;
}

[[gnu::weak]] auto hft_platform_poll_event(hft_ipc_record*) noexcept -> bool { return false; }

[[gnu::weak]] auto hft_platform_publish_intent(hft_ipc_record const*) noexcept -> bool {
  return true;
}

[[gnu::weak]] auto hft_platform_poll_config(hft_ipc_record*) noexcept -> bool { return false; }

[[gnu::weak]] auto hft_platform_publish_log(char const*, std::size_t) noexcept -> bool {
  return true;
}

[[gnu::weak]] auto hft_platform_publish_journal(hft_ipc_record const*) noexcept -> bool {
  return true;
}

[[gnu::weak]] auto hft_platform_dcache_invalidate(void const*, std::size_t) noexcept -> void {}

[[gnu::weak]] auto hft_platform_dcache_clean(void const*, std::size_t) noexcept -> void {}

}  // extern "C"

namespace {

constexpr std::size_t trading_budget = 32;
constexpr std::size_t journal_budget = 32;

struct PlatformClock {
  [[nodiscard]] auto now_ns() noexcept -> std::uint64_t { return hft_platform_now_ns(); }
};

struct RpmsgLogSink {
  auto write(std::string_view line) noexcept -> void {
    static_cast<void>(hft_platform_publish_log(line.data(), line.size()));
  }
};

// The CPU-side ring is fed through hft_platform_poll_event. When the PL
// writes the BRAM ring directly, the ring switches to PlSharedMemory.
using App = hft::FirmwareApp<PlatformClock, hft::disruptor::HostMemory>;

constexpr hft::RiskConfig fail_closed{.armed = false, .killed = true};

struct Runtime {
  PlatformClock clock{};
  RpmsgLogSink log_sink{};
  App app{clock, fail_closed};
#if defined(HFT_WITH_XILINX_FREERTOS)
  template <std::size_t StackWords>
  struct TaskStorage {
    StaticTask_t control{};
    std::array<StackType_t, StackWords> stack{};
  };
  TaskStorage<2048> trading_task{};
  TaskStorage<1024> control_task{};
  TaskStorage<1024> journal_task{};
  TaskStorage<1024> log_task{};
#endif
};

// Built from main() before any task exists, so the unguarded initialization
// that -fno-threadsafe-statics produces cannot race.
auto runtime() noexcept -> Runtime& {
  static Runtime instance;
  return instance;
}

HFT_TCM_TEXT auto trading_iteration(Runtime& rt) noexcept -> void {
  auto& app = rt.app;
  // Accept at most what the ring can hold, so a burst neither spins here nor
  // overflows the ring.
  auto const intake = std::views::iota(std::size_t{0}, std::min(app.ring_free(), trading_budget));
  static_cast<void>(std::ranges::find_if_not(intake, [&app](std::size_t) noexcept {
    hft_ipc_record raw{};
    if (!hft_platform_poll_event(&raw)) {
      return false;
    }
    static_cast<void>(app.publish_market_event(hft::from_ipc<hft::MarketEvent>(raw)));
    return true;
  }));
  static_cast<void>(app.run_trading(trading_budget));
  static_cast<void>(app.drain_intents([](hft::OrderIntent const& intent) noexcept {
    auto const raw = hft::to_ipc(intent);
    return hft_platform_publish_intent(&raw);
  }));
}

auto control_iteration(Runtime& rt) noexcept -> void {
  hft_ipc_record raw{};
  if (hft_platform_poll_config(&raw)) {
    static_cast<void>(rt.app.deliver_config(hft::from_ipc<hft::RiskConfigRecord>(raw)));
  }
}

auto journal_iteration(Runtime& rt) noexcept -> void {
  static_cast<void>(rt.app.poll_journal(
      journal_budget, [](hft::MarketEvent const& event, hft::disruptor::sequence_t) noexcept {
        auto const raw = hft::to_ipc(event);
        static_cast<void>(hft_platform_publish_journal(&raw));
      }));
}

auto log_iteration(Runtime& rt) noexcept -> void {
  static_cast<void>(rt.app.drain_logs(rt.log_sink));
}

#if defined(HFT_WITH_XILINX_FREERTOS)
// The trading task is woken by the PL doorbell notification and otherwise
// polls every tick; lower-priority tasks run on fixed periods.
extern "C" auto trading_task(void* parameter) -> void {
  auto& rt = *static_cast<Runtime*>(parameter);
  for (;;) {
    static_cast<void>(ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1)));
    trading_iteration(rt);
    taskYIELD();
  }
}

template <void (*Iteration)(Runtime&) noexcept, std::uint32_t PeriodMs>
auto periodic_task(void* parameter) -> void {
  auto& rt = *static_cast<Runtime*>(parameter);
  for (;;) {
    Iteration(rt);
    vTaskDelay(pdMS_TO_TICKS(PeriodMs));
  }
}

template <std::size_t StackWords>
auto start_task(TaskFunction_t entry, char const* name, UBaseType_t priority,
                Runtime::TaskStorage<StackWords>& storage, Runtime& rt) -> void {
  static_cast<void>(xTaskCreateStatic(entry, name, static_cast<std::uint32_t>(StackWords), &rt,
                                      priority, storage.stack.data(), &storage.control));
}
#endif

}  // namespace

auto main() -> int {
  auto& rt = runtime();
  rt.app.warm_up(64);
#if defined(HFT_WITH_XILINX_FREERTOS)
  start_task(trading_task, "hft-trade", configMAX_PRIORITIES - 2U, rt.trading_task, rt);
  start_task(periodic_task<control_iteration, 1>, "hft-ctrl", 3U, rt.control_task, rt);
  start_task(periodic_task<journal_iteration, 5>, "hft-jrnl", 2U, rt.journal_task, rt);
  start_task(periodic_task<log_iteration, 10>, "hft-log", 1U, rt.log_task, rt);
  vTaskStartScheduler();
  for (;;) {
  }
#else
  // Freestanding link smoke target used by CI: one pass of every context.
  trading_iteration(rt);
  control_iteration(rt);
  journal_iteration(rt);
  log_iteration(rt);
  return 0;
#endif
}
