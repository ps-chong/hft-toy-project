#pragma once

// Compile-time contracts for the R5 composition. Policies are injected as
// template parameters and checked here, so no interface base class or vtable
// exists on the trading path.

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <type_traits>

#include "hft/types.hpp"

namespace hft {

/// Monotonic nanosecond source used to stamp decisions.
template <typename C>
concept MonotonicClock = requires(C& clock) {
  { clock.now_ns() } noexcept -> std::same_as<std::uint64_t>;
};

/// Destination for one formatted diagnostic line. Must not block.
template <typename S>
concept LogSink = requires(S& sink, std::string_view line) {
  { sink.write(line) } noexcept;
};

/// Platform interrupt registration used by ScopedInterrupt.
template <typename C>
concept InterruptController = requires(C& controller, std::uint32_t vector) {
  { controller.register_irq(vector) } noexcept -> std::same_as<bool>;
  { controller.unregister_irq(vector) } noexcept;
};

/// A trading strategy proposes at most one order per market event.
template <typename S>
concept StrategyPolicy = std::is_nothrow_default_constructible_v<S> &&
                         requires(S& strategy, MarketEvent const& event) {
                           { strategy.evaluate(event) } noexcept
                               -> std::same_as<std::optional<OrderIntent>>;
                         };

}  // namespace hft
