#pragma once

// Event admission and order decisions. Owned by the trading task and called
// from the Disruptor stages in hft/stages.hpp.

#include <cstdint>
#include <expected>
#include <optional>

#include "hft/concepts.hpp"
#include "hft/risk_engine.hpp"
#include "hft/strategy.hpp"
#include "hft/types.hpp"

namespace hft {

enum class ProcessingError : std::uint8_t {
  abi_mismatch,
  stale_event,
  risk_rejected,
};

/// What a validated market event means for the order path.
enum class Admission : std::uint8_t {
  ignored,
  lifecycle,
  entry_candidate,
};

template <MonotonicClock Clock, typename Risk = RiskEngine<>>
class OrderManager {
public:
  using admission_type = std::expected<Admission, ProcessingError>;
  using decision_type = std::expected<std::optional<OrderIntent>, ProcessingError>;

  constexpr OrderManager(Clock& clock, Risk& risk) noexcept : clock_(clock), risk_(risk) {}

  /// Rejects ABI mismatches and replays, and applies lifecycle events.
  [[nodiscard]] constexpr auto admit(MarketEvent const& event) noexcept -> admission_type {
    if (event.abi_version != ipc_abi_version) [[unlikely]] {
      return std::unexpected(ProcessingError::abi_mismatch);
    }
    if (event.sequence <= last_event_sequence_) [[unlikely]] {
      return std::unexpected(ProcessingError::stale_event);
    }
    last_event_sequence_ = event.sequence;

    switch (event.kind) {
    case EventKind::execute:
    case EventKind::cancel:
    case EventKind::erase:
      risk_.on_order_closed();
      return Admission::lifecycle;
    case EventKind::add:
      return Admission::entry_candidate;
    default:
      return Admission::ignored;
    }
  }

  /// Strategy proposal, then decision stamping, then risk. An empty optional
  /// means the strategy declined; an error means risk rejected the proposal.
  [[nodiscard]] constexpr auto decide(MarketEvent const& event,
                                      StrategySelector& strategies) noexcept
      -> decision_type {
    return decision_type{strategies.evaluate(event)}.and_then(
        [this, &event](std::optional<OrderIntent> candidate) -> decision_type {
          if (!candidate) {
            return std::optional<OrderIntent>{};
          }
          candidate->user_ref = next_user_ref_++;
          candidate->decision_timestamp_ns = clock_.now_ns();
          candidate->stock_locate = event.stock_locate;
          return risk_.check(*candidate)
              .transform([](OrderIntent const& approved) { return std::optional{approved}; })
              .transform_error([this](RiskError error) {
                last_risk_error_ = error;
                return ProcessingError::risk_rejected;
              });
        });
  }

  [[nodiscard]] constexpr auto last_risk_error() const noexcept -> std::optional<RiskError> {
    return last_risk_error_;
  }

private:
  Clock& clock_;
  Risk& risk_;
  std::uint64_t last_event_sequence_{};
  std::uint32_t next_user_ref_{1};
  std::optional<RiskError> last_risk_error_;
};

}  // namespace hft
