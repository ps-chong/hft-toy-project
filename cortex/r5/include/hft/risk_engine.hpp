#pragma once

// Pre-trade risk checks. Owned and mutated only by the trading task.
//
// Each rule is an independent predicate. The engine evaluates every rule of a
// compile-time MP11 list into one violation bitmask, without data-dependent
// branches, and reports the highest-priority (lowest-index) failure. The same
// mask feeds per-rule rejection counters, so diagnostics see every rule that
// failed, not only the first.

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>
#include <type_traits>
#include <utility>

#include <boost/mp11/algorithm.hpp>
#include <boost/mp11/list.hpp>

#include "hft/types.hpp"

namespace hft {

enum class RiskError : std::uint8_t {
  abi_mismatch,
  killed,
  invalid_side,
  zero_quantity,
  quantity_limit,
  price_collar,
  symbol_disabled,
  locate_disabled,
  stale_sequence,
  rate_limit,
  open_order_limit,
};

struct RiskConfig {
  bool armed{};
  bool killed{true};
  std::uint32_t revision{1};
  std::uint32_t max_quantity{1'000};
  std::uint64_t price_floor{1};
  std::uint64_t price_ceiling{1'000'000'000};
  std::uint32_t max_orders_per_window{100};
  std::uint64_t rate_window_ns{1'000'000};
  std::uint32_t max_open_orders{128};
  std::array<Symbol, 8> allowed_symbols{};
  std::size_t allowed_symbol_count{};
  std::array<std::uint16_t, 8> allowed_locates{};
  std::size_t allowed_locate_count{};
  std::uint8_t strategy_id{};
};

struct RiskState {
  std::uint64_t last_sequence{};
  std::uint64_t window_started_ns{};
  std::uint32_t orders_in_window{};
  std::uint32_t open_orders{};
};

template <typename R>
concept RiskRule = requires(OrderIntent const& intent, RiskConfig const& config,
                            RiskState const& state) {
  { R::violated(intent, config, state) } noexcept -> std::same_as<bool>;
  requires std::same_as<std::remove_cv_t<decltype(R::error)>, RiskError>;
};

struct AbiRule {
  static constexpr RiskError error = RiskError::abi_mismatch;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent, RiskConfig const&,
                                               RiskState const&) noexcept -> bool {
    return intent.abi_version != ipc_abi_version;
  }
};

struct TradingStateRule {
  static constexpr RiskError error = RiskError::killed;
  [[nodiscard]] static constexpr auto violated(OrderIntent const&, RiskConfig const& config,
                                               RiskState const&) noexcept -> bool {
    return !config.armed || config.killed;
  }
};

struct SideRule {
  static constexpr RiskError error = RiskError::invalid_side;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent, RiskConfig const&,
                                               RiskState const&) noexcept -> bool {
    return intent.side != Side::buy && intent.side != Side::sell;
  }
};

struct ZeroQuantityRule {
  static constexpr RiskError error = RiskError::zero_quantity;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent, RiskConfig const&,
                                               RiskState const&) noexcept -> bool {
    return intent.quantity == 0U;
  }
};

struct QuantityLimitRule {
  static constexpr RiskError error = RiskError::quantity_limit;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent,
                                               RiskConfig const& config,
                                               RiskState const&) noexcept -> bool {
    return intent.quantity > config.max_quantity;
  }
};

struct PriceCollarRule {
  static constexpr RiskError error = RiskError::price_collar;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent,
                                               RiskConfig const& config,
                                               RiskState const&) noexcept -> bool {
    return intent.price < config.price_floor || intent.price > config.price_ceiling;
  }
};

struct SymbolRule {
  static constexpr RiskError error = RiskError::symbol_disabled;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent,
                                               RiskConfig const& config,
                                               RiskState const&) noexcept -> bool {
    auto const allowed = std::span{config.allowed_symbols}.first(
        std::min(config.allowed_symbol_count, config.allowed_symbols.size()));
    auto const key = symbol_key(intent.symbol);
    return !allowed.empty() && std::ranges::none_of(allowed, [key](Symbol const& symbol) {
      return symbol_key(symbol) == key;
    });
  }
};

struct LocateRule {
  static constexpr RiskError error = RiskError::locate_disabled;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent,
                                               RiskConfig const& config,
                                               RiskState const&) noexcept -> bool {
    auto const allowed = std::span{config.allowed_locates}.first(
        std::min(config.allowed_locate_count, config.allowed_locates.size()));
    return !allowed.empty() && std::ranges::find(allowed, intent.stock_locate) == allowed.end();
  }
};

struct SequenceRule {
  static constexpr RiskError error = RiskError::stale_sequence;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent, RiskConfig const&,
                                               RiskState const& state) noexcept -> bool {
    return intent.source_sequence <= state.last_sequence;
  }
};

// A decision timestamp before the window start means the clock regressed;
// treat it as inside the window so a regression can only tighten the limit.
[[nodiscard]] constexpr auto inside_rate_window(std::uint64_t timestamp_ns,
                                                RiskConfig const& config,
                                                RiskState const& state) noexcept -> bool {
  return timestamp_ns < state.window_started_ns ||
         timestamp_ns - state.window_started_ns < config.rate_window_ns;
}

struct RateRule {
  static constexpr RiskError error = RiskError::rate_limit;
  [[nodiscard]] static constexpr auto violated(OrderIntent const& intent,
                                               RiskConfig const& config,
                                               RiskState const& state) noexcept -> bool {
    return inside_rate_window(intent.decision_timestamp_ns, config, state) &&
           state.orders_in_window >= config.max_orders_per_window;
  }
};

struct OpenOrderRule {
  static constexpr RiskError error = RiskError::open_order_limit;
  [[nodiscard]] static constexpr auto violated(OrderIntent const&, RiskConfig const& config,
                                               RiskState const& state) noexcept -> bool {
    return state.open_orders >= config.max_open_orders;
  }
};

/// Priority order: earlier rules win when several fail.
using DefaultRiskRules =
    boost::mp11::mp_list<AbiRule, TradingStateRule, SideRule, ZeroQuantityRule,
                         QuantityLimitRule, PriceCollarRule, SymbolRule, LocateRule,
                         SequenceRule, RateRule, OpenOrderRule>;

template <typename R>
using is_risk_rule = std::bool_constant<RiskRule<R>>;

/// Static view of one rule list: its error table and the folded evaluator.
template <RiskRule... Rules>
struct RuleTable {
  static constexpr std::size_t size = sizeof...(Rules);
  static_assert(size > 0 && size <= 32, "the violation mask is 32 bits wide");

  static constexpr std::array<RiskError, size> errors{Rules::error...};

  /// Bit I is set iff rule I fails. Every rule is evaluated: the predicates
  /// are cheap compares, and a fixed instruction path keeps latency flat.
  [[nodiscard]] static constexpr auto evaluate(OrderIntent const& intent,
                                               RiskConfig const& config,
                                               RiskState const& state) noexcept
      -> std::uint32_t {
    return [&]<std::size_t... I>(std::index_sequence<I...>) {
      return ((static_cast<std::uint32_t>(Rules::violated(intent, config, state)) << I) | ... |
              0U);
    }(std::index_sequence_for<Rules...>{});
  }

  [[nodiscard]] static constexpr auto first_error(std::uint32_t mask) noexcept -> RiskError {
    return errors[static_cast<std::size_t>(std::countr_zero(mask))];
  }
};

template <typename RuleList = DefaultRiskRules>
class RiskEngine {
  static_assert(boost::mp11::mp_all_of<RuleList, is_risk_rule>::value,
                "every entry of the rule list must model RiskRule");

public:
  using rules = boost::mp11::mp_apply<RuleTable, RuleList>;
  using result_type = std::expected<OrderIntent, RiskError>;

  constexpr explicit RiskEngine(RiskConfig config = {}) noexcept : config_(config) {}

  constexpr auto update_config(RiskConfig const& config) noexcept -> void { config_ = config; }

  [[nodiscard]] constexpr auto config() const noexcept -> RiskConfig const& { return config_; }
  [[nodiscard]] constexpr auto state() const noexcept -> RiskState const& { return state_; }

  /// Rejections per rule, indexed like RuleList.
  [[nodiscard]] constexpr auto rejections() const noexcept
      -> std::span<std::uint32_t const, rules::size> {
    return rejections_;
  }

  [[nodiscard]] constexpr auto check(OrderIntent intent) noexcept -> result_type {
    auto const mask = rules::evaluate(intent, config_, state_);
    if (mask != 0U) [[unlikely]] {
      count_rejections(mask);
      return std::unexpected(rules::first_error(mask));
    }
    intent.risk_revision = config_.revision;
    update_state(intent);
    return intent;
  }

  constexpr auto on_order_closed() noexcept -> void {
    state_.open_orders -= state_.open_orders > 0U ? 1U : 0U;
  }

private:
  constexpr auto count_rejections(std::uint32_t mask) noexcept -> void {
    // Visit set bits only: clear the lowest set bit each step.
    for (; mask != 0U; mask &= mask - 1U) {
      ++rejections_[static_cast<std::size_t>(std::countr_zero(mask))];
    }
  }

  constexpr auto update_state(OrderIntent const& intent) noexcept -> void {
    state_.last_sequence = intent.source_sequence;
    if (!inside_rate_window(intent.decision_timestamp_ns, config_, state_)) {
      state_.window_started_ns = intent.decision_timestamp_ns;
      state_.orders_in_window = 0;
    }
    ++state_.orders_in_window;
    ++state_.open_orders;
  }

  RiskConfig config_{};
  RiskState state_{};
  std::array<std::uint32_t, rules::size> rejections_{};
};

}  // namespace hft
