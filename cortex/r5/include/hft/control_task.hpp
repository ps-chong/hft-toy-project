#pragma once

#include <array>
#include <coroutine>
#include <cstddef>
#include <utility>

namespace hft {

template <std::size_t FrameBytes = 512> class ControlTask {
public:
  struct promise_type {
    static inline std::array<std::byte, FrameBytes> frame_{};
    static inline bool frame_in_use_{};

    [[nodiscard]] static auto operator new(std::size_t size) noexcept -> void* {
      if (frame_in_use_ || size > frame_.size()) {
        return nullptr;
      }
      frame_in_use_ = true;
      return frame_.data();
    }

    static auto operator delete(void*, std::size_t) noexcept -> void {
      frame_in_use_ = false;
    }

    [[nodiscard]] static auto get_return_object_on_allocation_failure() noexcept
        -> ControlTask {
      return {};
    }

    [[nodiscard]] auto get_return_object() noexcept -> ControlTask {
      return ControlTask{
          std::coroutine_handle<promise_type>::from_promise(*this)};
    }

    [[nodiscard]] static constexpr auto initial_suspend() noexcept {
      return std::suspend_always{};
    }

    [[nodiscard]] static constexpr auto final_suspend() noexcept {
      return std::suspend_always{};
    }

    static constexpr auto return_void() noexcept -> void {}
    static constexpr auto unhandled_exception() noexcept -> void {}
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

}  // namespace hft
