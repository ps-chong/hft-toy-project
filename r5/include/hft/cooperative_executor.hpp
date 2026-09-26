#pragma once

#include <cstddef>
#include <cstdint>
#include <utility>

#include "hft/config_snapshot.hpp"
#include "hft/risk_engine.hpp"
#include "hft/types.hpp"

namespace hft {

struct ExecutorStats {
  std::uint64_t events{};
  std::uint64_t intents{};
  std::uint64_t ignored{};
  std::uint64_t rejected{};
  std::uint64_t output_overflows{};
  std::uint64_t yields{};
};

template <typename EventQueue, typename IntentQueue, typename Manager>
class CooperativeExecutor {
public:
  constexpr CooperativeExecutor(EventQueue& events, IntentQueue& intents,
                                Manager& manager,
                                ConfigSnapshot<RiskConfig>& configuration) noexcept
      : events_(events), intents_(intents), manager_(manager),
        configuration_(configuration) {}

  [[nodiscard]] auto run_batch(std::size_t budget) noexcept -> std::size_t {
    manager_.apply_config(configuration_.load());
    std::size_t processed{};
    while (processed < budget) {
      auto event = events_.try_pop();
      if (!event) {
        break;
      }
      ++processed;
      ++stats_.events;

      auto result = manager_.on_event(*event);
      if (!result) {
        ++stats_.rejected;
        continue;
      }
      if (!result.value()) {
        ++stats_.ignored;
        continue;
      }
      if (!intents_.try_push(std::move(*result.value()))) {
        ++stats_.output_overflows;
        fault_latched_ = true;
        auto fail_closed = configuration_.load();
        fail_closed.killed = true;
        manager_.apply_config(fail_closed);
        break;
      }
      ++stats_.intents;
    }
    ++stats_.yields;
    return processed;
  }

  [[nodiscard]] constexpr auto fault_latched() const noexcept -> bool {
    return fault_latched_;
  }

  [[nodiscard]] constexpr auto stats() const noexcept -> ExecutorStats const& {
    return stats_;
  }

private:
  EventQueue& events_;
  IntentQueue& intents_;
  Manager& manager_;
  ConfigSnapshot<RiskConfig>& configuration_;
  ExecutorStats stats_{};
  bool fault_latched_{};
};

}  // namespace hft
