#pragma once

// Value types shared by the PL, R5, and A53. Every struct here is a 64-byte
// IPC image whose field offsets are pinned to protocol/schema/ipc.yaml by the
// generated hft_protocol_layout.hpp static_asserts at the end of this file.

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <type_traits>
#include <utility>

#include "hft/platform.h"
#include "hft_protocol.hpp"

namespace hft {

inline constexpr std::uint16_t ipc_abi_version = protocol::abi_version;
inline constexpr std::size_t cache_line_size = 64;

// The IPC schema is little-endian and both Cortex-R5 and Cortex-A53 run
// little-endian, so records convert with std::bit_cast instead of field-wise
// serialization.
static_assert(std::endian::native == std::endian::little);

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
  std::string_view const padded{symbol.data(), symbol.size()};
  auto const last = padded.find_last_not_of(' ');
  return last == std::string_view::npos ? padded.substr(0, 0) : padded.substr(0, last + 1);
}

// ITCH symbols are 8 space-padded bytes, so one 64-bit compare replaces an
// 8-iteration character compare on the risk path.
[[nodiscard]] constexpr auto symbol_key(Symbol const& symbol) noexcept -> std::uint64_t {
  return std::bit_cast<std::uint64_t>(symbol);
}

/// MarketEvent::flags bits (normalized_event.flags in ipc.yaml). The PL sets
/// feed_gap on the first event after a MoldUDP64 sequence gap.
inline constexpr std::uint32_t event_flag_feed_gap = 1U
                                                     << protocol::normalized_event_flag::feed_gap;
inline constexpr std::uint32_t event_flag_stale = 1U << protocol::normalized_event_flag::stale;

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
  std::uint16_t stock_locate{};
  std::array<std::byte, 2> reserved{};
  std::uint64_t new_order_reference{};
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
  std::uint16_t stock_locate{};
  std::array<std::byte, 14> reserved{};
};

enum class ConfigFlag : std::uint8_t {
  armed = 1U << 0U,
  kill = 1U << 1U,
  clear_kill = 1U << 2U,
};

static_assert(std::to_underlying(ConfigFlag::armed) == 1U << protocol::risk_config_flag::armed);
static_assert(std::to_underlying(ConfigFlag::kill) == 1U << protocol::risk_config_flag::kill);
static_assert(std::to_underlying(ConfigFlag::clear_kill) ==
              1U << protocol::risk_config_flag::clear_kill);

[[nodiscard]] constexpr auto has_flag(std::uint16_t flags, ConfigFlag flag) noexcept -> bool {
  return (flags & std::to_underlying(flag)) != 0U;
}

// A53 -> R5 control-plane snapshot (risk_config in ipc.yaml).
struct alignas(cache_line_size) RiskConfigRecord {
  std::uint16_t abi_version{ipc_abi_version};
  std::uint16_t flags{};
  std::uint32_t revision{};
  std::uint32_t max_quantity{};
  std::uint32_t max_orders_per_window{};
  std::uint64_t price_floor{};
  std::uint64_t price_ceiling{};
  std::uint64_t rate_window_ns{};
  std::uint32_t max_open_orders{};
  std::uint8_t strategy_id{};
  std::uint8_t allowed_locate_count{};
  std::array<std::byte, 2> reserved{};
  std::array<std::uint16_t, 8> allowed_locates{};
};

template <typename Record>
concept IpcRecord = std::is_trivially_copyable_v<Record> &&
                    sizeof(Record) == HFT_IPC_RECORD_SIZE;

template <IpcRecord Record>
[[nodiscard]] constexpr auto to_ipc(Record const& record) noexcept -> hft_ipc_record {
  return std::bit_cast<hft_ipc_record>(record);
}

template <IpcRecord Record>
[[nodiscard]] constexpr auto from_ipc(hft_ipc_record const& raw) noexcept -> Record {
  return std::bit_cast<Record>(raw);
}

static_assert(IpcRecord<MarketEvent>);
static_assert(IpcRecord<OrderIntent>);
static_assert(IpcRecord<RiskConfigRecord>);
static_assert(sizeof(hft_ipc_record) == protocol::ipc_record_size);

}  // namespace hft

#include "hft_protocol_layout.hpp"
