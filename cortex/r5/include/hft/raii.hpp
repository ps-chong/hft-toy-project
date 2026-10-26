#pragma once

// RAII owners for platform resources used during R5 bring-up.
//
// FixedPool gives std::unique_ptr ownership over fixed storage: acquiring and
// releasing are O(1) through a free-slot bitmap, and the custom deleter
// returns the slot instead of freeing heap memory. ScopedInterrupt is a
// Boost.Scope unique_resource that unregisters a vector exactly once.
// Neither type is shared across tasks; each pool and interrupt has one owner.

#include <algorithm>
#include <array>
#include <bit>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <numeric>
#include <optional>
#include <type_traits>
#include <utility>

#include <boost/scope/unique_resource.hpp>

#include "hft/concepts.hpp"

namespace hft {

template <typename T, std::size_t Capacity>
class FixedPool {
  static_assert(Capacity > 0);
  static constexpr std::size_t word_bits = 64;
  static constexpr std::size_t word_count = (Capacity + word_bits - 1) / word_bits;

public:
  class Deleter {
  public:
    constexpr Deleter() noexcept = default;
    constexpr Deleter(FixedPool* owner, std::size_t index) noexcept
        : owner_(owner), index_(index) {}

    auto operator()(T* value) const noexcept -> void {
      if (owner_ != nullptr && value != nullptr) {
        owner_->release(index_);
      }
    }

  private:
    FixedPool* owner_{};
    std::size_t index_{};
  };

  using pointer = std::unique_ptr<T, Deleter>;

  constexpr FixedPool() noexcept {
    // Bit set = slot free. Trailing bits past Capacity stay clear forever.
    free_.fill(~std::uint64_t{0});
    if constexpr (Capacity % word_bits != 0) {
      free_.back() = (std::uint64_t{1} << (Capacity % word_bits)) - 1U;
    }
  }

  FixedPool(FixedPool const&) = delete;
  auto operator=(FixedPool const&) -> FixedPool& = delete;

  /// Constructs a T in the lowest free slot; an empty pointer when exhausted.
  template <typename... Args>
    requires std::constructible_from<T, Args...>
  [[nodiscard]] auto acquire(Args&&... args) noexcept(
      std::is_nothrow_constructible_v<T, Args...>) -> pointer {
    auto const word = std::ranges::find_if(free_, [](std::uint64_t bits) { return bits != 0U; });
    if (word == free_.end()) {
      return pointer{nullptr, Deleter{}};
    }
    auto const bit = static_cast<std::size_t>(std::countr_zero(*word));
    auto const index = static_cast<std::size_t>(word - free_.begin()) * word_bits + bit;
    *word &= *word - 1U;  // claim the lowest set bit
    auto& slot = slots_[index].emplace(std::forward<Args>(args)...);
    return pointer{std::addressof(slot), Deleter{this, index}};
  }

  [[nodiscard]] auto available() const noexcept -> std::size_t {
    return std::transform_reduce(free_.begin(), free_.end(), std::size_t{0}, std::plus<>{},
                                 [](std::uint64_t bits) {
                                   return static_cast<std::size_t>(std::popcount(bits));
                                 });
  }

private:
  auto release(std::size_t index) noexcept -> void {
    slots_[index].reset();
    free_[index / word_bits] |= std::uint64_t{1} << (index % word_bits);
  }

  std::array<std::optional<T>, Capacity> slots_{};
  std::array<std::uint64_t, word_count> free_{};
};

template <InterruptController Controller>
struct InterruptRelease {
  Controller* controller{};

  auto operator()(std::uint32_t vector) const noexcept -> void {
    controller->unregister_irq(vector);
  }
};

template <InterruptController Controller>
using ScopedInterrupt = boost::scope::unique_resource<std::uint32_t, InterruptRelease<Controller>>;

/// Registers `vector`; the result owns the registration only on success.
template <InterruptController Controller>
[[nodiscard]] auto make_scoped_interrupt(Controller& controller, std::uint32_t vector) noexcept
    -> ScopedInterrupt<Controller> {
  if (!controller.register_irq(vector)) {
    return ScopedInterrupt<Controller>{};
  }
  return ScopedInterrupt<Controller>{vector, InterruptRelease<Controller>{&controller}};
}

}  // namespace hft
