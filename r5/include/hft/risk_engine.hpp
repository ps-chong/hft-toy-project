#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

#include <boost/mp11/algorithm.hpp>
#include <boost/mp11/list.hpp>
#include <boost/outcome/basic_result.hpp>

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
};

struct RiskState {
  std::uint64_t last_sequence{};
  std::uint64_t window_started_ns{};
  std::uint32_t orders_in_window{};
  std::uint32_t open_orders{};
};

template <typename Derived> struct Rule {
  [[nodiscard]] static constexpr auto evaluate(OrderIntent const& intent,
                                                RiskConfig const& config,
                                                RiskState const& state) noexcept
      -> std::optional<RiskError> {
    return Derived::evaluate_impl(intent, config, state);
  }
};

struct AbiRule : Rule<AbiRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const&,
                                                     RiskState const&) noexcept
      -> std::optional<RiskError> {
    return intent.abi_version == ipc_abi_version
               ? std::nullopt
               : std::optional{RiskError::abi_mismatch};
  }
};

struct TradingStateRule : Rule<TradingStateRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const&,
                                                     RiskConfig const& config,
                                                     RiskState const&) noexcept
      -> std::optional<RiskError> {
    return config.armed && !config.killed ? std::nullopt
                                          : std::optional{RiskError::killed};
  }
};

struct SideRule : Rule<SideRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const&,
                                                     RiskState const&) noexcept
      -> std::optional<RiskError> {
    return intent.side == Side::buy || intent.side == Side::sell
               ? std::nullopt
               : std::optional{RiskError::invalid_side};
  }
};

struct QuantityRule : Rule<QuantityRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const& config,
                                                     RiskState const&) noexcept
      -> std::optional<RiskError> {
    if (intent.quantity == 0) {
      return RiskError::zero_quantity;
    }
    if (intent.quantity > config.max_quantity) {
      return RiskError::quantity_limit;
    }
    return std::nullopt;
  }
};

struct PriceRule : Rule<PriceRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const& config,
                                                     RiskState const&) noexcept
      -> std::optional<RiskError> {
    return intent.price >= config.price_floor && intent.price <= config.price_ceiling
               ? std::nullopt
               : std::optional{RiskError::price_collar};
  }
};

struct SymbolRule : Rule<SymbolRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const& config,
                                                     RiskState const&) noexcept
      -> std::optional<RiskError> {
    auto enabled = config.allowed_symbol_count == 0 ||
                   std::ranges::find(
                       config.allowed_symbols.begin(),
                       config.allowed_symbols.begin() +
                           static_cast<std::ptrdiff_t>(config.allowed_symbol_count),
                       intent.symbol) !=
                       config.allowed_symbols.begin() +
                           static_cast<std::ptrdiff_t>(config.allowed_symbol_count);
    return enabled ? std::nullopt : std::optional{RiskError::symbol_disabled};
  }
};

struct SequenceRule : Rule<SequenceRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const&,
                                                     RiskState const& state) noexcept
      -> std::optional<RiskError> {
    return intent.source_sequence > state.last_sequence
               ? std::nullopt
               : std::optional{RiskError::stale_sequence};
  }
};

struct RateRule : Rule<RateRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const& intent,
                                                     RiskConfig const& config,
                                                     RiskState const& state) noexcept
      -> std::optional<RiskError> {
    auto const inside_window =
        intent.decision_timestamp_ns - state.window_started_ns < config.rate_window_ns;
    return inside_window && state.orders_in_window >= config.max_orders_per_window
               ? std::optional{RiskError::rate_limit}
               : std::nullopt;
  }
};

struct OpenOrderRule : Rule<OpenOrderRule> {
  [[nodiscard]] static constexpr auto evaluate_impl(OrderIntent const&,
                                                     RiskConfig const& config,
                                                     RiskState const& state) noexcept
      -> std::optional<RiskError> {
    return state.open_orders < config.max_open_orders
               ? std::nullopt
               : std::optional{RiskError::open_order_limit};
  }
};

using DefaultRiskRules =
    boost::mp11::mp_list<AbiRule, TradingStateRule, SideRule, QuantityRule, PriceRule,
                         SymbolRule, SequenceRule, RateRule, OpenOrderRule>;

template <typename RuleList = DefaultRiskRules> class RiskEngine {
public:
  using result_type =
      boost::outcome_v2::basic_result<OrderIntent, RiskError,
                                      boost::outcome_v2::policy::all_narrow>;

  constexpr explicit RiskEngine(RiskConfig config = {}) noexcept : config_(config) {}

  constexpr auto update_config(RiskConfig config) noexcept -> void { config_ = config; }

  [[nodiscard]] constexpr auto config() const noexcept -> RiskConfig const& {
    return config_;
  }

  [[nodiscard]] constexpr auto state() const noexcept -> RiskState const& { return state_; }

  [[nodiscard]] constexpr auto check(OrderIntent intent) noexcept -> result_type {
    std::optional<RiskError> failure;
    boost::mp11::mp_for_each<RuleList>([&](auto rule) {
      if (!failure) {
        failure = decltype(rule)::evaluate(intent, config_, state_);
      }
    });
    if (failure) {
      return boost::outcome_v2::failure(*failure);
    }

    intent.risk_revision = config_.revision;
    update_state(intent);
    return intent;
  }

  constexpr auto on_order_closed() noexcept -> void {
    if (state_.open_orders > 0) {
      --state_.open_orders;
    }
  }

private:
  constexpr auto update_state(OrderIntent const& intent) noexcept -> void {
    state_.last_sequence = intent.source_sequence;
    if (intent.decision_timestamp_ns - state_.window_started_ns >=
        config_.rate_window_ns) {
      state_.window_started_ns = intent.decision_timestamp_ns;
      state_.orders_in_window = 0;
    }
    ++state_.orders_in_window;
    ++state_.open_orders;
  }

  RiskConfig config_{};
  RiskState state_{};
};

}  // namespace hft
