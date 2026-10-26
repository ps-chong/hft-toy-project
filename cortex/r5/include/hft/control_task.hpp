#pragma once

// Cooperative control actor for the low-priority R5 control task.
//
// The actor is a C++20 coroutine whose frame lives in a caller-supplied
// FrameArena (no heap after startup, no hidden static storage). It suspends on
// its mailbox until the platform delivers a risk_config record, validates it,
// releases or keeps the kill switch, and publishes the resulting RiskConfig
// to the trading task through the TripleBuffer. Everything it touches is
// either owned by the control task or designed for cross-task use
// (TripleBuffer, KillSwitch, the control log ring).

#include <array>
#include <coroutine>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <expected>
#include <optional>
#include <utility>

#include "hft/kill_switch.hpp"
#include "hft/logging.hpp"
#include "hft/risk_engine.hpp"
#include "hft/strategy.hpp"
#include "hft/triple_buffer.hpp"
#include "hft/types.hpp"

namespace hft {

/// Single-frame bump arena. One live coroutine frame per arena.
template <std::size_t Bytes>
class FrameArena {
public:
  static constexpr std::size_t alignment = __STDCPP_DEFAULT_NEW_ALIGNMENT__;

  [[nodiscard]] auto allocate(std::size_t size) noexcept -> void* {
    if (in_use_ || size > Bytes) {
      return nullptr;
    }
    in_use_ = true;
    return storage_.data();
  }

  auto release() noexcept -> void { in_use_ = false; }

  [[nodiscard]] auto in_use() const noexcept -> bool { return in_use_; }

  [[nodiscard]] auto address() const noexcept -> void const* { return storage_.data(); }

private:
  // Coroutine frames hold pointers and the promise; they require the default
  // operator-new alignment, which a plain std::byte array does not provide.
  alignas(alignment) std::array<std::byte, Bytes> storage_{};
  bool in_use_{};
};

class ControlTask {
public:
  struct promise_type {
    /// Records which arena to return the frame to; operator delete cannot
    /// receive the arena argument, so it reads this header instead.
    struct FrameHeader {
      void (*release)(void* arena) noexcept;
      void* arena;
    };

    static constexpr std::size_t header_size =
        (sizeof(FrameHeader) + __STDCPP_DEFAULT_NEW_ALIGNMENT__ - 1U) /
        __STDCPP_DEFAULT_NEW_ALIGNMENT__ * __STDCPP_DEFAULT_NEW_ALIGNMENT__;

    /// Leading-allocator convention: the coroutine's first parameter selects
    /// the arena that holds its frame.
    template <std::size_t Bytes, typename... Args>
    [[nodiscard]] static auto operator new(std::size_t size, FrameArena<Bytes>& arena,
                                           Args const&...) noexcept -> void* {
      auto* const raw = static_cast<std::byte*>(arena.allocate(size + header_size));
      if (raw == nullptr) {
        return nullptr;
      }
      // The header is trivially copyable: copy its bytes in, so no pointer
      // cast or alignment assumption is needed.
      FrameHeader const header{&release_arena<Bytes>, &arena};
      std::memcpy(raw, &header, sizeof(header));
      return raw + header_size;
    }

    static auto operator delete(void* frame, std::size_t) noexcept -> void {
      auto const* const raw = static_cast<std::byte const*>(frame) - header_size;
      FrameHeader header{};
      std::memcpy(&header, raw, sizeof(header));
      header.release(header.arena);
    }

    [[nodiscard]] static auto get_return_object_on_allocation_failure() noexcept
        -> ControlTask {
      return {};
    }

    [[nodiscard]] auto get_return_object() noexcept -> ControlTask {
      return ControlTask{std::coroutine_handle<promise_type>::from_promise(*this)};
    }

    [[nodiscard]] static constexpr auto initial_suspend() noexcept { return std::suspend_always{}; }
    [[nodiscard]] static constexpr auto final_suspend() noexcept { return std::suspend_always{}; }
    static constexpr auto return_void() noexcept -> void {}
    static constexpr auto unhandled_exception() noexcept -> void {}

  private:
    template <std::size_t Bytes>
    static auto release_arena(void* arena) noexcept -> void {
      static_cast<FrameArena<Bytes>*>(arena)->release();
    }
  };

  constexpr ControlTask() noexcept = default;
  explicit constexpr ControlTask(std::coroutine_handle<promise_type> handle) noexcept
      : handle_(handle) {}

  ~ControlTask() {
    if (handle_) {
      handle_.destroy();
    }
  }

  ControlTask(ControlTask const&) = delete;
  auto operator=(ControlTask const&) -> ControlTask& = delete;

  constexpr ControlTask(ControlTask&& other) noexcept
      : handle_(std::exchange(other.handle_, {})) {}

  auto operator=(ControlTask&& other) noexcept -> ControlTask& {
    if (this != &other) {
      if (handle_) {
        handle_.destroy();
      }
      handle_ = std::exchange(other.handle_, {});
    }
    return *this;
  }

  [[nodiscard]] constexpr explicit operator bool() const noexcept {
    return static_cast<bool>(handle_);
  }

  /// Runs the coroutine to its next suspension point; false once finished.
  [[nodiscard]] auto resume() noexcept -> bool {
    if (!handle_ || handle_.done()) {
      return false;
    }
    handle_.resume();
    return !handle_.done();
  }

private:
  std::coroutine_handle<promise_type> handle_{};
};

/// One-slot hand-off from the control task's platform poll to the actor.
/// Owned entirely by the control task, so it needs no synchronization.
class ControlMailbox {
public:
  /// Returns false if a record is still pending (the caller retries later).
  [[nodiscard]] auto deliver(RiskConfigRecord const& record) noexcept -> bool {
    if (pending_) {
      return false;
    }
    pending_ = record;
    if (auto waiter = std::exchange(waiter_, {})) {
      waiter.resume();
    }
    return true;
  }

  [[nodiscard]] auto next() noexcept {
    struct Awaiter {
      ControlMailbox& mailbox;
      [[nodiscard]] auto await_ready() const noexcept -> bool {
        return mailbox.pending_.has_value();
      }
      auto await_suspend(std::coroutine_handle<> handle) noexcept -> void {
        mailbox.waiter_ = handle;
      }
      // Resumed only after deliver() filled the slot; the default record
      // (revision 0) would be rejected as stale if that ever failed to hold.
      [[nodiscard]] auto await_resume() noexcept -> RiskConfigRecord {
        return std::exchange(mailbox.pending_, std::nullopt).value_or(RiskConfigRecord{});
      }
    };
    return Awaiter{*this};
  }

private:
  std::optional<RiskConfigRecord> pending_;
  std::coroutine_handle<> waiter_{};
};

enum class ConfigError : std::uint8_t {
  abi_mismatch = 1,
  stale_revision,
  invalid_collar,
  invalid_limits,
  invalid_locates,
  unknown_strategy,
};

/// Pure validation of one control record against the last applied revision.
[[nodiscard]] constexpr auto decode_risk_config(RiskConfigRecord const& record,
                                                std::uint32_t last_revision) noexcept
    -> std::expected<RiskConfig, ConfigError> {
  if (record.abi_version != ipc_abi_version) {
    return std::unexpected(ConfigError::abi_mismatch);
  }
  if (record.revision <= last_revision) {
    return std::unexpected(ConfigError::stale_revision);
  }
  if (record.price_floor > record.price_ceiling) {
    return std::unexpected(ConfigError::invalid_collar);
  }
  if (record.max_quantity == 0U || record.max_orders_per_window == 0U ||
      record.rate_window_ns == 0U) {
    return std::unexpected(ConfigError::invalid_limits);
  }
  if (record.allowed_locate_count > record.allowed_locates.size()) {
    return std::unexpected(ConfigError::invalid_locates);
  }
  if (record.strategy_id >= StrategySelector::count) {
    return std::unexpected(ConfigError::unknown_strategy);
  }
  return RiskConfig{
      .armed = has_flag(record.flags, ConfigFlag::armed),
      .killed = has_flag(record.flags, ConfigFlag::kill),
      .revision = record.revision,
      .max_quantity = record.max_quantity,
      .price_floor = record.price_floor,
      .price_ceiling = record.price_ceiling,
      .max_orders_per_window = record.max_orders_per_window,
      .rate_window_ns = record.rate_window_ns,
      .max_open_orders = record.max_open_orders,
      .allowed_locates = record.allowed_locates,
      .allowed_locate_count = record.allowed_locate_count,
      .strategy_id = record.strategy_id,
  };
}

// GCC's -Wmismatched-new-delete pairs a coroutine's leading-allocator
// operator new with the promise's usual operator delete and reports a false
// positive; the header written in operator new makes the pair consistent.
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmismatched-new-delete"
#endif

/// The control actor. The arena parameter places the frame (see promise_type).
template <std::size_t ArenaBytes, typename Log>
auto control_actor(FrameArena<ArenaBytes>& /*arena*/, ControlMailbox& mailbox,
                   TripleBuffer<RiskConfig>& configs, KillSwitch& kill, Log& log,
                   std::uint32_t initial_revision) -> ControlTask {
  auto last_revision = initial_revision;
  for (;;) {
    auto const record = co_await mailbox.next();
    auto const decoded = decode_risk_config(record, last_revision);
    if (!decoded) {
      log.log(LogLevel::error, LogMessage::config_rejected, record.revision,
              std::to_underlying(decoded.error()));
      // A corrupt or replayed control record means the A53 side is
      // misbehaving: fail closed. A stale record alone is harmless.
      if (decoded.error() != ConfigError::stale_revision) {
        kill.trip(KillReason::invalid_config, last_revision);
      }
      continue;
    }
    if (has_flag(record.flags, ConfigFlag::clear_kill) && kill.latched()) {
      auto const reasons = kill.reasons();
      if (kill.clear(record.revision)) {
        log.log(LogLevel::info, LogMessage::kill_cleared, record.revision);
      } else {
        log.log(LogLevel::warning, LogMessage::kill_clear_refused, record.revision, reasons);
      }
    }
    last_revision = record.revision;
    configs.publish(*decoded);
    log.log(LogLevel::info, LogMessage::config_applied, record.revision, record.strategy_id);
  }
}

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif

}  // namespace hft
