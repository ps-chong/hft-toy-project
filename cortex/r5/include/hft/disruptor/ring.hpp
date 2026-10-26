#pragma once

// LMAX Disruptor ring for the PL -> R5 market-event path.
//
// One producer (the PL DMA engine on hardware, a feeder in host builds)
// claims slots by sequence. Gating consumers advance their own Sequence;
// the producer may only reuse a slot once the slowest gating consumer has
// passed it. Non-gating (lossy) readers never hold the producer back and
// detect being lapped instead.
//
// Sequences are 32-bit and compared by wrap-safe distance, because the PL
// cannot take part in 64-bit exclusive accesses and 32-bit aligned stores are
// single-copy atomic on both sides of the AXI interconnect.
//
// Every slot access is a relaxed atomic word access (std::atomic_ref), so a
// lossy reader copying a slot the producer is rewriting gets a stale or mixed
// value, which it detects and discards, rather than undefined behaviour.
// Relaxed word accesses compile to plain LDR/STR on Arm.

#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <type_traits>

#include "hft/platform.h"
#include "hft/types.hpp"

namespace hft::disruptor {

using sequence_t = std::uint32_t;

/// `to - from` modulo 2^32. Valid while the true distance is below 2^31,
/// which every ring capacity guarantees.
[[nodiscard]] constexpr auto distance(sequence_t from, sequence_t to) noexcept -> sequence_t {
  return static_cast<sequence_t>(to - from);
}

/// One cursor or consumer position on its own cache line, so the producer and
/// each consumer write disjoint lines.
struct alignas(cache_line_size) Sequence {
  std::atomic<sequence_t> value;

  constexpr Sequence() noexcept : value{0} {}
  constexpr explicit Sequence(sequence_t initial) noexcept : value{initial} {}

  /// Acquire: everything the owner wrote before store() is visible.
  [[nodiscard]] auto load() const noexcept -> sequence_t {
    return value.load(std::memory_order_acquire);
  }

  /// Release: publishes every slot or annotation write made before it.
  auto store(sequence_t next) noexcept -> void { value.store(next, std::memory_order_release); }

  /// The owner reading its own position needs no ordering.
  [[nodiscard]] auto owned() const noexcept -> sequence_t {
    return value.load(std::memory_order_relaxed);
  }
};

/// Cache maintenance around slot accesses.
template <typename M>
concept MemoryPolicy = requires(void const* address, std::size_t length) {
  { M::before_read(address, length) } noexcept;
  { M::after_write(address, length) } noexcept;
};

/// Coherent memory (host builds and tests): nothing to do.
struct HostMemory {
  static auto before_read(void const*, std::size_t) noexcept -> void {}
  static auto after_write(void const*, std::size_t) noexcept -> void {}
};

/// BRAM/OCM shared with the PL through non-coherent ports: invalidate before
/// reading PL-written lines and clean after writing lines the PL reads. The
/// platform adapter adds the DMB/DSB barriers the AMD BSP requires.
struct PlSharedMemory {
  static auto before_read(void const* address, std::size_t length) noexcept -> void {
    hft_platform_dcache_invalidate(address, length);
  }
  static auto after_write(void const* address, std::size_t length) noexcept -> void {
    hft_platform_dcache_clean(address, length);
  }
};

static_assert(MemoryPolicy<HostMemory>);
static_assert(MemoryPolicy<PlSharedMemory>);

template <typename T, std::size_t Capacity, MemoryPolicy Memory = HostMemory>
  requires std::is_trivially_copyable_v<T> && (sizeof(T) % sizeof(std::uint32_t) == 0)
class Ring {
  static_assert(std::has_single_bit(Capacity), "capacity must be a power of two");
  static_assert(Capacity >= 2 && Capacity <= (std::size_t{1} << 30U),
                "wrap-safe distances need capacity well below 2^31");

  using words_type = std::array<std::uint32_t, sizeof(T) / sizeof(std::uint32_t)>;

  struct alignas(std::max(alignof(T), alignof(words_type))) Slot {
    words_type words{};
  };

  static constexpr sequence_t index_mask = static_cast<sequence_t>(Capacity - 1U);

public:
  using value_type = T;

  [[nodiscard]] static consteval auto capacity() noexcept -> std::size_t { return Capacity; }

  /// `initial` lets tests start just below the 2^32 wrap point.
  constexpr explicit Ring(sequence_t initial = 0) noexcept : cursor_{initial} {}

  Ring(Ring const&) = delete;
  auto operator=(Ring const&) -> Ring& = delete;

  /// Producer only. `gating` is the slowest gating consumer's sequence.
  /// Returns false, and writes nothing, when the ring is full.
  [[nodiscard]] auto try_publish(T const& value, sequence_t gating) noexcept -> bool {
    auto const next = cursor_.owned();
    if (distance(gating, next) >= Capacity) [[unlikely]] {
      return false;
    }
    // Orders the previous cursor store before the slot writes below. A lossy
    // reader whose copy observes any of these writes therefore observes a
    // cursor of at least `next` after its acquire fence, and discards the copy.
    std::atomic_thread_fence(std::memory_order_release);

    auto& slot = slots_[next & index_mask];
    auto const words = std::bit_cast<words_type>(value);
    std::ranges::for_each(std::views::zip(slot.words, words), [](auto&& pair) noexcept {
      auto&& [destination, source] = pair;
      std::atomic_ref<std::uint32_t>{destination}.store(source, std::memory_order_relaxed);
    });
    Memory::after_write(&slot, sizeof(Slot));
    cursor_.store(next + 1U);
    return true;
  }

  /// Any consumer: one past the newest published sequence (acquire).
  [[nodiscard]] auto cursor() const noexcept -> sequence_t { return cursor_.load(); }

  /// Lossy readers re-check the cursor after an acquire fence; the fence
  /// supplies the ordering, so this load may be relaxed.
  [[nodiscard]] auto cursor_after_fence() const noexcept -> sequence_t {
    return cursor_.owned();
  }

  /// Copies slot `sequence`. Only gating consumers are guaranteed an intact
  /// value; lossy readers must validate with cursor_after_fence().
  [[nodiscard]] auto read(sequence_t sequence) const noexcept -> T {
    auto& slot = slots_[sequence & index_mask];
    Memory::before_read(&slot, sizeof(Slot));
    words_type words{};
    std::ranges::transform(slot.words, words.begin(), [](std::uint32_t& word) noexcept {
      return std::atomic_ref<std::uint32_t>{word}.load(std::memory_order_relaxed);
    });
    return std::bit_cast<T>(words);
  }

private:
  // Mutable: atomic_ref needs a non-const referent even for loads.
  mutable std::array<Slot, Capacity> slots_{};
  Sequence cursor_;
};

}  // namespace hft::disruptor
