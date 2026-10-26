#pragma once

// Trading strategies, owned and mutated only by the trading task.
//
// Strategies are plain value types held in a std::variant. The active one is
// selected at a safe point from risk_config.strategy_id, mirroring a runtime
// strategy-select register: dispatch is a jump table, with no heap and no
// vtable.

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <type_traits>
#include <variant>

#include <boost/mp11/algorithm.hpp>
#include <boost/mp11/list.hpp>

#include "hft/concepts.hpp"
#include "hft/types.hpp"

namespace hft {

[[nodiscard]] constexpr auto is_tradable_add(MarketEvent const& event) noexcept -> bool {
  return event.kind == EventKind::add && event.quantity != 0U &&
         (event.side == Side::buy || event.side == Side::sell);
}

[[nodiscard]] constexpr auto opposite(Side side) noexcept -> Side {
  return side == Side::buy ? Side::sell : Side::buy;
}

/// Takes the other side of every displayed add, capped at order_quantity.
struct MirrorStrategy {
  std::uint32_t order_quantity{1};

  [[nodiscard]] constexpr auto evaluate(MarketEvent const& event) noexcept
      -> std::optional<OrderIntent> {
    if (!is_tradable_add(event)) {
      return std::nullopt;
    }
    return OrderIntent{
        .action = OrderAction::enter,
        .side = opposite(event.side),
        .source_sequence = event.sequence,
        .symbol = event.symbol,
        .price = event.price,
        .quantity = std::min(order_quantity, event.quantity),
    };
  }
};

/// Accumulates displayed add volume per side over a fixed event window. When
/// one side outweighs the other by `ratio`, it trades with the pressure: it
/// lifts an incoming offer under buy pressure and hits an incoming bid under
/// sell pressure.
struct ImbalanceStrategy {
  std::uint32_t ratio{2};
  std::uint32_t order_quantity{1};
  std::uint32_t window_events{64};
  std::uint64_t buy_volume{};
  std::uint64_t sell_volume{};
  std::uint32_t events_in_window{};

  [[nodiscard]] constexpr auto evaluate(MarketEvent const& event) noexcept
      -> std::optional<OrderIntent> {
    if (!is_tradable_add(event)) {
      return std::nullopt;
    }
    roll_window();
    (event.side == Side::buy ? buy_volume : sell_volume) += event.quantity;

    auto const buy_pressure = buy_volume > sell_volume * ratio;
    auto const sell_pressure = sell_volume > buy_volume * ratio;
    auto const aligned = (buy_pressure && event.side == Side::sell) ||
                         (sell_pressure && event.side == Side::buy);
    if (!aligned) {
      return std::nullopt;
    }
    return OrderIntent{
        .action = OrderAction::enter,
        .side = opposite(event.side),
        .source_sequence = event.sequence,
        .symbol = event.symbol,
        .price = event.price,
        .quantity = std::min(order_quantity, event.quantity),
    };
  }

private:
  constexpr auto roll_window() noexcept -> void {
    if (++events_in_window > window_events) {
      buy_volume = 0;
      sell_volume = 0;
      events_in_window = 1;
    }
  }
};

/// Index order is the wire value of risk_config.strategy_id.
using StrategySet = std::variant<MirrorStrategy, ImbalanceStrategy>;

static_assert(StrategyPolicy<MirrorStrategy>);
static_assert(StrategyPolicy<ImbalanceStrategy>);

// Every alternative is nothrow-constructible and nothrow-copyable, so the
// variant can never become valueless_by_exception. std::visit therefore
// cannot throw bad_variant_access, and emplace cannot throw at all.
template <typename T>
using is_nothrow_strategy =
    std::bool_constant<std::is_nothrow_default_constructible_v<T> &&
                       std::is_nothrow_copy_constructible_v<T>>;
static_assert(boost::mp11::mp_all_of<boost::mp11::mp_rename<StrategySet, boost::mp11::mp_list>,
                                     is_nothrow_strategy>::value);

class StrategySelector {
public:
  static constexpr std::size_t count = std::variant_size_v<StrategySet>;

  /// Re-creates the strategy (resetting its state) only when the id changes.
  /// Unknown ids are refused and leave the active strategy untouched.
  [[nodiscard]] constexpr auto select(std::uint8_t id) noexcept -> bool {
    if (id >= count) {
      return false;
    }
    if (id != active_.index()) {
      // NOLINTNEXTLINE(bugprone-exception-escape): nothrow alternatives (see above)
      boost::mp11::mp_with_index<count>(id, [this](auto index) noexcept {
        active_.template emplace<decltype(index)::value>();
      });
    }
    return true;
  }

  // NOLINTNEXTLINE(bugprone-exception-escape): the variant is never valueless
  [[nodiscard]] constexpr auto evaluate(MarketEvent const& event) noexcept
      -> std::optional<OrderIntent> {
    return std::visit([&event](auto& strategy) noexcept { return strategy.evaluate(event); },
                      active_);
  }

  [[nodiscard]] constexpr auto active_id() const noexcept -> std::uint8_t {
    return static_cast<std::uint8_t>(active_.index());
  }

private:
  StrategySet active_{};
};

}  // namespace hft
