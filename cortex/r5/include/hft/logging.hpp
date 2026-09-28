#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <iterator>
#include <string_view>
#include <utility>

#include <fmt/format.h>

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

template <typename Sink, std::size_t BufferSize = 256> class Logger {
public:
  constexpr explicit Logger(Sink& sink) noexcept : sink_(sink) {}

  template <typename... Args>
  // fmt validates the format string at compile time and writes into fixed
  // storage; embedded builds disable exceptions globally.
  // NOLINTNEXTLINE(bugprone-exception-escape)
  auto write(LogLevel level, fmt::format_string<Args...> format,
             Args&&... args) noexcept -> void {
    std::array<char, BufferSize> buffer{};
    auto const prefix = level_prefix(level);
    auto output = std::copy(prefix.begin(), prefix.end(), buffer.begin());
    auto const remaining =
        static_cast<std::size_t>(std::distance(output, buffer.end()));
    auto result =
        fmt::format_to_n(output, remaining, format, std::forward<Args>(args)...);
    auto const payload_size =
        std::min(prefix.size() + result.size, buffer.size());
    sink_.write(std::string_view{buffer.data(), payload_size});
  }

private:
  [[nodiscard]] static constexpr auto level_prefix(LogLevel level) noexcept
      -> std::string_view {
    switch (level) {
    case LogLevel::debug:
      return "DEBUG ";
    case LogLevel::info:
      return "INFO ";
    case LogLevel::warning:
      return "WARN ";
    case LogLevel::error:
      return "ERROR ";
    }
    return "";
  }

  Sink& sink_;
};

}  // namespace hft
