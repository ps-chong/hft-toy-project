#pragma once

#include <array>
#include <atomic>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>
#include <utility>

#include "hft/types.hpp"

namespace hft {

template <typename T, std::size_t Capacity> class SpscRing {
  static_assert(Capacity >= 2);
  static_assert(std::has_single_bit(Capacity), "capacity must be a power of two");
  static_assert(std::is_nothrow_move_assignable_v<T>);

public:
  SpscRing() = default;
  SpscRing(SpscRing const&) = delete;
  auto operator=(SpscRing const&) -> SpscRing& = delete;

  [[nodiscard]] auto try_push(T const& value) noexcept -> bool
    requires std::is_nothrow_copy_assignable_v<T>
  {
    return emplace_value(value);
  }

  [[nodiscard]] auto try_push(T&& value) noexcept -> bool {
    return emplace_value(std::move(value));
  }

  [[nodiscard]] auto try_pop() noexcept -> std::optional<T> {
    auto const read = read_index_.value.load(std::memory_order_relaxed);
    auto const write = write_index_.value.load(std::memory_order_acquire);
    if (read == write) {
      return std::nullopt;
    }

    auto value = std::move(storage_[read & index_mask]);
    read_index_.value.store(read + 1U, std::memory_order_release);
    return value;
  }

  [[nodiscard]] auto empty() const noexcept -> bool {
    return read_index_.value.load(std::memory_order_acquire) ==
           write_index_.value.load(std::memory_order_acquire);
  }

  [[nodiscard]] auto size_approx() const noexcept -> std::size_t {
    auto const write = write_index_.value.load(std::memory_order_acquire);
    auto const read = read_index_.value.load(std::memory_order_acquire);
    return static_cast<std::size_t>(write - read);
  }

  [[nodiscard]] static consteval auto capacity() noexcept -> std::size_t { return Capacity; }

private:
  template <typename U> [[nodiscard]] auto emplace_value(U&& value) noexcept -> bool {
    auto const write = write_index_.value.load(std::memory_order_relaxed);
    auto const read = read_index_.value.load(std::memory_order_acquire);
    if (write - read == Capacity) {
      return false;
    }

    storage_[write & index_mask] = std::forward<U>(value);
    write_index_.value.store(write + 1U, std::memory_order_release);
    return true;
  }

  struct alignas(cache_line_size) AlignedIndex {
    std::atomic<std::uint32_t> value{};
  };

  static constexpr std::uint32_t index_mask = static_cast<std::uint32_t>(Capacity - 1U);
  std::array<T, Capacity> storage_{};
  AlignedIndex write_index_{};
  AlignedIndex read_index_{};
};

}  // namespace hft
