#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <string_view>
#include <type_traits>

namespace hft {

inline constexpr std::uint16_t ipc_abi_version = 1;
inline constexpr std::size_t cache_line_size = 64;

enum class EventKind : std::uint8_t {
  none = 0,
  add = 'A',
  execute = 'E',
  cancel = 'X',
  erase = 'D',
  replace = 'U',
  trade = 'P',
};

enum class Side : std::uint8_t {
  unknown = 0,
  buy = 'B',
  sell = 'S',
};

enum class OrderAction : std::uint8_t {
  none = 0,
  enter = 'O',
  replace = 'U',
  cancel = 'X',
};

using Symbol = std::array<char, 8>;

[[nodiscard]] constexpr auto make_symbol(std::string_view value) noexcept -> Symbol {
  Symbol symbol{' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '};
  std::ranges::copy(value.substr(0, symbol.size()), symbol.begin());
  return symbol;
}

[[nodiscard]] constexpr auto symbol_view(Symbol const& symbol) noexcept -> std::string_view {
  auto end = symbol.size();
  while (end > 0 && symbol[end - 1] == ' ') {
    --end;
  }
  return {symbol.data(), end};
}

struct alignas(cache_line_size) MarketEvent {
  std::uint16_t abi_version{ipc_abi_version};
  EventKind kind{EventKind::none};
  Side side{Side::unknown};
  std::uint32_t flags{};
  std::uint64_t sequence{};
  std::uint64_t timestamp_ns{};
  std::uint64_t order_reference{};
  Symbol symbol{};
  std::uint64_t price{};
  std::uint32_t quantity{};
  std::array<std::byte, 12> reserved{};
};

struct alignas(cache_line_size) OrderIntent {
  std::uint16_t abi_version{ipc_abi_version};
  OrderAction action{OrderAction::none};
  Side side{Side::unknown};
  std::uint32_t user_ref{};
  std::uint64_t source_sequence{};
  std::uint64_t decision_timestamp_ns{};
  Symbol symbol{};
  std::uint64_t price{};
  std::uint32_t quantity{};
  std::uint32_t risk_revision{};
  std::array<std::byte, 16> reserved{};
};

static_assert(sizeof(MarketEvent) == cache_line_size);
static_assert(sizeof(OrderIntent) == cache_line_size);
static_assert(std::is_trivially_copyable_v<MarketEvent>);
static_assert(std::is_trivially_copyable_v<OrderIntent>);

}  // namespace hft
