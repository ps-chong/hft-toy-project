#pragma once

// Deferred, allocation-free diagnostics.
//
// Hot paths never format or perform I/O. Each producing context owns a
// DeferredLog that pushes a fixed-size LogRecord into that context's own SPSC
// ring. One low-priority drain task formats records into a stack buffer and is
// the only caller of the platform log hook, so RPMsg sends never interleave.

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <iterator>
#include <string_view>
#include <utility>

#include <boost/lockfree/policies.hpp>
#include <boost/lockfree/spsc_queue.hpp>
#include <fmt/format.h>

#include "hft/concepts.hpp"

#if defined(HFT_HAS_CIB)
#include <log/log.hpp>
#define HFT_CIB_INFO(...) CIB_INFO(__VA_ARGS__)
#define HFT_CIB_WARN(...) CIB_WARN(__VA_ARGS__)
#else
#define HFT_CIB_INFO(...) ((void)0)
#define HFT_CIB_WARN(...) ((void)0)
#endif

namespace hft {

enum class LogLevel : std::uint8_t { debug, info, warning, error };

/// Catalog of every message the firmware can emit; arguments travel as
/// integers and are formatted only in the drain task.
enum class LogMessage : std::uint8_t {
  market_ring_overflow,
  intent_ring_overflow,
  config_applied,
  config_rejected,
  kill_cleared,
  kill_clear_refused,
};

struct LogRecord {
  LogLevel level{};
  LogMessage message{};
  std::array<std::uint64_t, 2> args{};
};

template <std::size_t Capacity>
using LogRing = boost::lockfree::spsc_queue<LogRecord, boost::lockfree::capacity<Capacity>>;

/// Producer-side handle for one context's ring.
template <typename Ring>
class DeferredLog {
public:
  constexpr explicit DeferredLog(Ring& ring) noexcept : ring_(ring) {}

  /// Never blocks; a full ring increments the drop counter instead.
  auto log(LogLevel level, LogMessage message, std::uint64_t first = 0,
           std::uint64_t second = 0) noexcept -> void {
    if (!ring_.push(LogRecord{.level = level, .message = message, .args = {first, second}}))
        [[unlikely]] {
      // Relaxed: a diagnostic count with no ordering obligations.
      dropped_.fetch_add(1U, std::memory_order_relaxed);
    }
  }

  [[nodiscard]] auto dropped() const noexcept -> std::uint32_t {
    return dropped_.load(std::memory_order_relaxed);
  }

private:
  Ring& ring_;
  std::atomic<std::uint32_t> dropped_{};
};

/// Formats into fixed storage and hands complete lines to the sink.
template <LogSink Sink, std::size_t BufferSize = 256>
class Logger {
public:
  constexpr explicit Logger(Sink& sink) noexcept : sink_(sink) {}

  /// Formats into fixed storage. fmt::format_string rejects a malformed
  /// format at compile time; format_to_n into a char buffer never allocates.
  /// Embedded builds disable exceptions, so nothing can escape there.
  template <typename... Args>
  // NOLINTNEXTLINE(bugprone-exception-escape): see above
  auto write(LogLevel level, fmt::format_string<Args...> format, Args&&... args) noexcept
      -> void {
    std::array<char, BufferSize> buffer{};
    auto const prefix = level_prefix(level);
    auto const prefix_size = std::min(prefix.size(), buffer.size());
    std::ranges::copy(prefix.substr(0, prefix_size), buffer.begin());
    auto const written = fmt::format_to_n(buffer.data() + prefix_size,
                                          buffer.size() - prefix_size, format,
                                          std::forward<Args>(args)...)
                             .size;
    sink_.write(std::string_view{buffer.data(), std::min(prefix_size + written, buffer.size())});
  }

  /// Renders one deferred record. Each branch passes a literal format string,
  /// so every message in the catalog is checked when the firmware compiles.
  auto write(LogRecord const& record) noexcept -> void {
    auto const [first, second] = record.args;
    switch (record.message) {
    case LogMessage::market_ring_overflow:
      write(record.level, "market ring overflow; trading killed");
      break;
    case LogMessage::intent_ring_overflow:
      write(record.level, "intent queue overflow; trading killed");
      break;
    case LogMessage::config_applied:
      write(record.level, "risk config revision {} applied (strategy {})", first, second);
      break;
    case LogMessage::config_rejected:
      write(record.level, "risk config revision {} rejected (reason {})", first, second);
      break;
    case LogMessage::kill_cleared:
      write(record.level, "kill switch cleared by revision {}", first);
      break;
    case LogMessage::kill_clear_refused:
      write(record.level, "kill clear refused for revision {} (reasons {:#x})", first, second);
      break;
    }
  }

private:
  [[nodiscard]] static constexpr auto level_prefix(LogLevel level) noexcept
      -> std::string_view {
    constexpr std::array<std::string_view, 4> prefixes{"DEBUG ", "INFO ", "WARN ", "ERROR "};
    return prefixes[std::to_underlying(level) & 0x3U];
  }

  Sink& sink_;
};

/// Drain task: formats up to `budget` records from each ring, in ring order.
template <typename LoggerT, typename... Rings>
auto drain_logs(LoggerT& logger, std::size_t budget, Rings&... rings) noexcept
    -> std::size_t {
  auto const drain_one = [&logger, budget](auto& ring) noexcept {
    std::size_t drained{};
    while (drained < budget &&
           ring.consume_one([&logger](LogRecord const& record) { logger.write(record); })) {
      ++drained;
    }
    return drained;
  };
  return (std::size_t{} + ... + drain_one(rings));
}

}  // namespace hft
