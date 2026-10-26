#pragma once

// Sticky, fail-closed kill switch shared by every R5 context.
//
// Any context (trading task, producer, ISR) may trip it; only the control
// actor may clear it, and only with a risk_config revision newer than the
// one in force when it tripped. A trip that races with a clear always wins:
// the clear is a compare-exchange against the exact state it inspected, and
// every trip bumps an epoch inside that state.

#include <atomic>
#include <cstdint>
#include <utility>

namespace hft {

enum class KillReason : std::uint8_t {
  operator_request = 1U << 0U,
  market_ring_overflow = 1U << 1U,
  intent_ring_overflow = 1U << 2U,
  invalid_config = 1U << 3U,
  runtime_fault = 1U << 4U,
  feed_gap = 1U << 5U,
};

class KillSwitch {
public:
  constexpr KillSwitch() noexcept = default;
  KillSwitch(KillSwitch const&) = delete;
  auto operator=(KillSwitch const&) -> KillSwitch& = delete;

  /// Any context. Records the revision in force, then ORs the reason in and
  /// bumps the epoch so a concurrent clear() cannot succeed.
  auto trip(KillReason reason, std::uint32_t revision_in_force) noexcept -> void {
    tripped_revision_.store(revision_in_force, std::memory_order_relaxed);
    auto state = state_.load(std::memory_order_relaxed);
    // release: a reader that observes the new state also observes the
    // tripped revision stored above.
    while (!state_.compare_exchange_weak(
        state, next_trip_state(state, reason), std::memory_order_release,
        std::memory_order_relaxed)) {
    }
  }

  /// Control actor only. Clears iff no trip happened since `observed` was
  /// read and the operator acknowledged with a strictly newer revision.
  [[nodiscard]] auto clear(std::uint32_t acknowledging_revision) noexcept -> bool {
    auto observed = state_.load(std::memory_order_acquire);
    if (reasons_of(observed) == 0U) {
      return true;
    }
    if (acknowledging_revision <= tripped_revision_.load(std::memory_order_relaxed)) {
      return false;
    }
    auto const cleared = observed & epoch_mask;
    return state_.compare_exchange_strong(observed, cleared, std::memory_order_acq_rel,
                                          std::memory_order_acquire);
  }

  /// Any context. Acquire pairs with trip() so callers see the revision too.
  [[nodiscard]] auto latched() const noexcept -> bool {
    return reasons_of(state_.load(std::memory_order_acquire)) != 0U;
  }

  [[nodiscard]] auto reasons() const noexcept -> std::uint16_t {
    return reasons_of(state_.load(std::memory_order_acquire));
  }

  /// Changes on every trip and clear; lets the trading task re-apply its
  /// effective configuration only when the kill state actually changed.
  [[nodiscard]] auto version() const noexcept -> std::uint32_t {
    return state_.load(std::memory_order_acquire);
  }

private:
  static constexpr std::uint32_t epoch_mask = 0xFFFF'0000U;
  static constexpr std::uint32_t epoch_step = 0x0001'0000U;

  [[nodiscard]] static constexpr auto reasons_of(std::uint32_t state) noexcept
      -> std::uint16_t {
    return static_cast<std::uint16_t>(state & ~epoch_mask);
  }

  [[nodiscard]] static constexpr auto next_trip_state(std::uint32_t state,
                                                      KillReason reason) noexcept
      -> std::uint32_t {
    return ((state & epoch_mask) + epoch_step) | reasons_of(state) |
           std::to_underlying(reason);
  }

  // Bits 0-15: active reasons. Bits 16-31: trip/clear epoch.
  std::atomic<std::uint32_t> state_{};
  std::atomic<std::uint32_t> tripped_revision_{};
};

}  // namespace hft
