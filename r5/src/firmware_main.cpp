#include <cstdint>
#include <iterator>
#include <string_view>

#include "hft/app.hpp"

#if defined(HFT_WITH_XILINX_FREERTOS)
extern "C" {
#include "FreeRTOS.h"
#include "task.h"
}
#endif

extern "C" [[gnu::weak]] auto hft_platform_now_ns() noexcept -> std::uint64_t {
  static std::uint64_t fallback_ticks{};
  return ++fallback_ticks;
}

extern "C" [[gnu::weak]] auto hft_platform_poll_event(hft::MarketEvent*) noexcept
    -> bool {
  return false;
}

extern "C" [[gnu::weak]] auto
hft_platform_publish_intent(hft::OrderIntent const*) noexcept -> bool {
  return true;
}

extern "C" [[gnu::weak]] auto hft_platform_publish_log(char const*,
                                                        std::size_t) noexcept
    -> bool {
  return true;
}

namespace {

struct PlatformClock {
  [[nodiscard]] auto now_ns() const noexcept -> std::uint64_t {
    return hft_platform_now_ns();
  }
};

struct RpmsgLogSink {
  auto write(std::string_view message) noexcept -> void {
    static_cast<void>(hft_platform_publish_log(message.data(), message.size()));
  }
};

PlatformClock clock_source;
RpmsgLogSink log_sink;
hft::RiskConfig initial_config{
    .armed = false,
    .killed = true,
};
hft::FirmwareApp app{clock_source, log_sink, initial_config};

auto executor_iteration() noexcept -> void {
  hft::MarketEvent event;
  while (hft_platform_poll_event(&event)) {
    static_cast<void>(app.publish_market_event(event));
  }
  static_cast<void>(app.run_once(32));
  while (auto intent = app.next_intent()) {
    if (!hft_platform_publish_intent(&*intent)) {
      break;
    }
  }
}

#if defined(HFT_WITH_XILINX_FREERTOS)
StaticTask_t executor_task_control;
StackType_t executor_stack[2048];

extern "C" auto trading_executor(void*) -> void {
  for (;;) {
    static_cast<void>(ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1)));
    executor_iteration();
    taskYIELD();
  }
}
#endif

}  // namespace

extern "C" auto main() -> int {
#if defined(HFT_WITH_XILINX_FREERTOS)
  static_cast<void>(xTaskCreateStatic(
      trading_executor, "hft-exec",
      static_cast<std::uint32_t>(std::size(executor_stack)), nullptr,
      configMAX_PRIORITIES - 2U, executor_stack, &executor_task_control));
  vTaskStartScheduler();
  for (;;) {
  }
#else
  // Freestanding link smoke target used by CI. The real target defines
  // HFT_WITH_XILINX_FREERTOS and supplies the AMD BSP platform hooks.
  executor_iteration();
  return 0;
#endif
}
