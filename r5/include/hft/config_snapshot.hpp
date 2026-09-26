#pragma once

#include <array>
#include <atomic>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace hft {

template <typename T>
  requires std::is_trivially_copyable_v<T>
class ConfigSnapshot {
public:
  constexpr explicit ConfigSnapshot(T initial = {}) noexcept
      : slots_{initial, initial} {}

  auto publish(T const& next) noexcept -> void {
    sequence_.fetch_add(1U, std::memory_order_acq_rel);
    auto const current = active_.load(std::memory_order_relaxed);
    auto const inactive = current ^ 1U;
    slots_[inactive] = next;
    active_.store(inactive, std::memory_order_release);
    sequence_.fetch_add(1U, std::memory_order_release);
  }

  [[nodiscard]] auto load() const noexcept -> T {
    for (;;) {
      auto const before = sequence_.load(std::memory_order_acquire);
      if ((before & 1U) != 0U) {
        continue;
      }
      auto snapshot = slots_[active_.load(std::memory_order_acquire)];
      std::atomic_thread_fence(std::memory_order_acquire);
      auto const after = sequence_.load(std::memory_order_relaxed);
      if (before == after) {
        return snapshot;
      }
    }
  }

private:
  std::array<T, 2> slots_{};
  alignas(64) mutable std::atomic<std::uint32_t> sequence_{};
  alignas(64) std::atomic<std::size_t> active_{};
};

}  // namespace hft
