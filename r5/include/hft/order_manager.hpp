#pragma once

#include <algorithm>
#include <cstdint>
#include <expected>
#include <optional>

#include "hft/risk_engine.hpp"
#include "hft/types.hpp"

namespace hft {

enum class ProcessingError : std::uint8_t {
  abi_mismatch,
  stale_event,
  risk_rejected,
};

template <typename Derived> struct Strategy {
  [[nodiscard]] constexpr auto evaluate(MarketEvent const& event) const noexcept
      -> std::optional<OrderIntent> {
    return static_cast<Derived const&>(*this).evaluate_impl(event);
  }
};

struct MirrorStrategy : Strategy<MirrorStrategy> {
  std::uint32_t order_quantity{1};

  [[nodiscard]] constexpr auto evaluate_impl(MarketEvent const& event) const noexcept
      -> std::optional<OrderIntent> {
    if (event.kind != EventKind::add || event.quantity == 0 ||
        (event.side != Side::buy && event.side != Side::sell)) {
      return std::nullopt;
    }
    return OrderIntent{
        .action = OrderAction::enter,
        .side = event.side == Side::buy ? Side::sell : Side::buy,
        .source_sequence = event.sequence,
        .symbol = event.symbol,
        .price = event.price,
        .quantity = std::min(order_quantity, event.quantity),
    };
  }
};

template <typename Clock, typename Risk = RiskEngine<>,
          typename StrategyPolicy = MirrorStrategy>
class OrderManager {
public:
  constexpr OrderManager(Clock& clock, Risk& risk, StrategyPolicy strategy = {}) noexcept
      : clock_(clock), risk_(risk), strategy_(strategy) {}

  [[nodiscard]] auto on_event(MarketEvent const& event) noexcept
      -> std::expected<std::optional<OrderIntent>, ProcessingError> {
    if (event.abi_version != ipc_abi_version) {
      return std::unexpected{ProcessingError::abi_mismatch};
    }
    if (event.sequence <= last_event_sequence_) {
      return std::unexpected{ProcessingError::stale_event};
    }
    last_event_sequence_ = event.sequence;

    if (event.kind == EventKind::execute || event.kind == EventKind::cancel ||
        event.kind == EventKind::erase) {
      risk_.on_order_closed();
      return std::nullopt;
    }

    auto candidate = strategy_.evaluate(event);
    if (!candidate) {
      return std::nullopt;
    }
    candidate->user_ref = next_user_ref_++;
    candidate->decision_timestamp_ns = clock_.now_ns();

    auto checked = risk_.check(*candidate);
    if (!checked) {
      last_risk_error_ = checked.error();
      return std::unexpected{ProcessingError::risk_rejected};
    }
    return std::optional{*checked};
  }

  [[nodiscard]] constexpr auto last_risk_error() const noexcept
      -> std::optional<RiskError> {
    return last_risk_error_;
  }

  constexpr auto apply_config(RiskConfig config) noexcept -> void {
    risk_.update_config(config);
  }

private:
  Clock& clock_;
  Risk& risk_;
  StrategyPolicy strategy_;
  std::uint64_t last_event_sequence_{};
  std::uint32_t next_user_ref_{1};
  std::optional<RiskError> last_risk_error_;
};

}  // namespace hft
