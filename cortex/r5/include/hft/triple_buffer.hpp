#pragma once

// Wait-free single-writer/single-reader snapshot hand-off.
//
// Replaces the former seqlock ConfigSnapshot. On the single-core R5 a seqlock
// reader that preempts a mid-publish writer spins forever, and its plain slot
// copy races with the writer. Here each of the three slots is owned by exactly
// one side at any instant (writer: back, reader: front, neither: middle), so
// no slot is ever read and written concurrently and neither side retries.

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <type_traits>

#include "hft/types.hpp"

namespace hft {

template <typename T>
  requires std::is_trivially_copyable_v<T>
class TripleBuffer {
public:
  constexpr explicit TripleBuffer(T const& initial = {}) noexcept
      : slots_{initial, initial, initial} {}

  TripleBuffer(TripleBuffer const&) = delete;
  auto operator=(TripleBuffer const&) -> TripleBuffer& = delete;

  /// Writer only. Fills the back slot, then swaps it into the middle with the
  /// fresh bit set. acq_rel: release publishes the slot contents to the
  /// reader; acquire makes the slot the reader just returned safe to reuse.
  auto publish(T const& next) noexcept -> void {
    slots_[back_] = next;
    back_ = static_cast<std::uint8_t>(
        middle_.exchange(static_cast<std::uint8_t>(back_ | fresh_bit),
                         std::memory_order_acq_rel) &
        index_mask);
  }

  /// Reader only. Takes the newest published slot when one is pending and
  /// otherwise keeps the current front. The relaxed probe is only a hint; the
  /// acq_rel exchange is what synchronizes with publish().
  [[nodiscard]] auto acquire() noexcept -> T const& {
    if ((middle_.load(std::memory_order_relaxed) & fresh_bit) != 0U) {
      front_ = static_cast<std::uint8_t>(
          middle_.exchange(front_, std::memory_order_acq_rel) & index_mask);
    }
    return slots_[front_];
  }

  /// Reader only: true when a publish has happened since the last acquire().
  [[nodiscard]] auto has_fresh() const noexcept -> bool {
    return (middle_.load(std::memory_order_relaxed) & fresh_bit) != 0U;
  }

private:
  static constexpr std::uint8_t index_mask = 0b011U;
  static constexpr std::uint8_t fresh_bit = 0b100U;

  std::array<T, 3> slots_;
  alignas(cache_line_size) std::atomic<std::uint8_t> middle_{1};
  alignas(cache_line_size) std::uint8_t back_{0};
  alignas(cache_line_size) std::uint8_t front_{2};
};

}  // namespace hft
