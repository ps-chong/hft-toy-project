#pragma once

// Non-gating Disruptor reader for noncritical consumers (journal, telemetry).
//
// It never slows the producer. If the producer laps it, it skips ahead and
// counts the gap. Each copy is validated seqlock-style: copy the slot, take an
// acquire fence, then re-read the cursor. If the producer could have started
// rewriting that slot, the copy is discarded and counted as dropped.

#include <concepts>
#include <cstddef>
#include <cstdint>

#include "hft/disruptor/ring.hpp"

namespace hft::disruptor {

template <typename RingT>
class LossyReader {
public:
  using value_type = typename RingT::value_type;

  constexpr explicit LossyReader(RingT const& ring) noexcept
      : ring_(ring), next_(ring.cursor()) {}

  /// Delivers up to `budget` intact events in order. Single owner (journal task).
  template <std::invocable<value_type const&, sequence_t> Deliver>
  auto poll(std::size_t budget, Deliver&& deliver) noexcept -> std::size_t {
    auto const cursor = ring_.cursor();
    skip_if_lapped(cursor);

    std::size_t delivered{};
    while (delivered < budget && next_ != cursor) {
      auto const value = ring_.read(next_);
      std::atomic_thread_fence(std::memory_order_acquire);
      // The producer rewrites slot `next_` while publishing next_ + Capacity,
      // i.e. once the cursor has reached that sequence.
      if (distance(next_, ring_.cursor_after_fence()) >= RingT::capacity()) [[unlikely]] {
        ++dropped_;
      } else {
        deliver(value, next_);
        ++delivered;
      }
      ++next_;
    }
    delivered_ += delivered;
    return delivered;
  }

  [[nodiscard]] constexpr auto dropped() const noexcept -> std::uint64_t { return dropped_; }
  [[nodiscard]] constexpr auto delivered() const noexcept -> std::uint64_t { return delivered_; }

private:
  auto skip_if_lapped(sequence_t cursor) noexcept -> void {
    // The oldest slot that is safe to read is cursor - Capacity + 1, because
    // the slot of sequence `cursor` may be in the middle of a rewrite.
    auto constexpr window = static_cast<sequence_t>(RingT::capacity() - 1U);
    auto const behind = distance(next_, cursor);
    if (behind > window) {
      dropped_ += behind - window;
      next_ = cursor - window;
    }
  }

  RingT const& ring_;
  sequence_t next_;
  std::uint64_t dropped_{};
  std::uint64_t delivered_{};
};

}  // namespace hft::disruptor
