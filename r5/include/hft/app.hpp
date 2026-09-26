#pragma once

#include <cstddef>
#include <optional>
#include <utility>

#include "hft/config_snapshot.hpp"
#include "hft/cooperative_executor.hpp"
#include "hft/logging.hpp"
#include "hft/order_manager.hpp"
#include "hft/risk_engine.hpp"
#include "hft/spsc_ring.hpp"
#include "hft/types.hpp"

namespace hft {

template <typename Clock, typename LogSink> class FirmwareApp {
public:
  explicit FirmwareApp(Clock& clock, LogSink& sink, RiskConfig initial = {}) noexcept
      : risk_(initial), manager_(clock, risk_), configuration_(initial),
        executor_(events_, intents_, manager_, configuration_), logger_(sink) {
    HFT_CIB_INFO("R5 firmware application composed");
  }

  [[nodiscard]] auto publish_market_event(MarketEvent event) noexcept -> bool {
    if (events_.try_push(std::move(event))) {
      return true;
    }
    auto failed = configuration_.load();
    failed.killed = true;
    configuration_.publish(failed);
    logger_.write(LogLevel::error, "market ring overflow; trading killed");
    return false;
  }

  auto publish_config(RiskConfig config) noexcept -> void {
    configuration_.publish(config);
  }

  [[nodiscard]] auto run_once(std::size_t batch_budget = 32) noexcept
      -> std::size_t {
    return executor_.run_batch(batch_budget);
  }

  [[nodiscard]] auto next_intent() noexcept -> std::optional<OrderIntent> {
    return intents_.try_pop();
  }

  [[nodiscard]] constexpr auto stats() const noexcept -> ExecutorStats const& {
    return executor_.stats();
  }

  [[nodiscard]] constexpr auto fault_latched() const noexcept -> bool {
    return executor_.fault_latched();
  }

private:
  SpscRing<MarketEvent, 1024> events_;
  SpscRing<OrderIntent, 256> intents_;
  RiskEngine<> risk_;
  OrderManager<Clock> manager_;
  ConfigSnapshot<RiskConfig> configuration_;
  CooperativeExecutor<decltype(events_), decltype(intents_), decltype(manager_)>
      executor_;
  Logger<LogSink> logger_;
};

}  // namespace hft
