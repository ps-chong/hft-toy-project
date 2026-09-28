#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <ranges>
#include <utility>

namespace hft {

template <typename InterruptController> class ScopedInterrupt {
public:
  ScopedInterrupt(InterruptController& controller, std::uint32_t vector) noexcept
      : controller_(&controller), vector_(vector), registered_(controller.register_irq(vector)) {}

  ~ScopedInterrupt() {
    if (registered_) {
      controller_->unregister_irq(vector_);
    }
  }

  ScopedInterrupt(ScopedInterrupt const&) = delete;
  auto operator=(ScopedInterrupt const&) -> ScopedInterrupt& = delete;

  ScopedInterrupt(ScopedInterrupt&& other) noexcept
      : controller_(std::exchange(other.controller_, nullptr)),
        vector_(other.vector_),
        registered_(std::exchange(other.registered_, false)) {}

  auto operator=(ScopedInterrupt&& other) noexcept -> ScopedInterrupt& {
    if (this == &other) {
      return *this;
    }
    if (registered_) {
      controller_->unregister_irq(vector_);
    }
    controller_ = std::exchange(other.controller_, nullptr);
    vector_ = other.vector_;
    registered_ = std::exchange(other.registered_, false);
    return *this;
  }

  [[nodiscard]] constexpr explicit operator bool() const noexcept { return registered_; }

private:
  InterruptController* controller_{};
  std::uint32_t vector_{};
  bool registered_{};
};

template <typename T, std::size_t Capacity> class FixedPool {
public:
  class Deleter {
  public:
    constexpr Deleter() noexcept = default;
    constexpr explicit Deleter(FixedPool* owner) noexcept : owner_(owner) {}

    auto operator()(T* value) const noexcept -> void {
      if (owner_ != nullptr && value != nullptr) {
        owner_->release(value);
      }
    }

  private:
    FixedPool* owner_{};
  };

  using pointer = std::unique_ptr<T, Deleter>;

  template <typename... Args> [[nodiscard]] auto acquire(Args&&... args) -> pointer {
    for (auto& slot : slots_) {
      if (!slot) {
        slot.emplace(std::forward<Args>(args)...);
        return pointer{std::addressof(*slot), Deleter{this}};
      }
    }
    return pointer{nullptr, Deleter{this}};
  }

  [[nodiscard]] auto available() const noexcept -> std::size_t {
    return static_cast<std::size_t>(
        std::ranges::count_if(slots_, [](auto const& slot) { return !slot.has_value(); }));
  }

private:
  auto release(T* value) noexcept -> void {
    auto const slot = std::ranges::find_if(slots_, [value](auto& candidate) {
      return candidate && std::addressof(*candidate) == value;
    });
    if (slot != slots_.end()) {
      slot->reset();
    }
  }

  std::array<std::optional<T>, Capacity> slots_{};
};

}  // namespace hft
