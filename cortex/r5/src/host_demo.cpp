// Minimal host walkthrough of the R5 firmware: one market event through the
// Disruptor stages to one approved intent. Single-threaded; see
// cortex/r5/src/host_platform.cpp for the socket-driven demo binary.

#include <cstdint>
#include <cstdio>
#include <optional>
#include <string_view>

#include <fmt/format.h>

#include "hft/app.hpp"

namespace {

struct HostClock {
  std::uint64_t value{};
  [[nodiscard]] auto now_ns() noexcept -> std::uint64_t { return ++value; }
};

/// noexcept sink: raw stdio writes cannot throw.
struct StdoutSink {
  auto write(std::string_view line) noexcept -> void {
    std::fwrite(line.data(), sizeof(char), line.size(), stdout);
    std::fputc('\n', stdout);
  }
};

}  // namespace

// Host tool: an exception from fmt's stdout write terminates the demo.
// NOLINTNEXTLINE(bugprone-exception-escape)
auto main() -> int {
  HostClock clock;
  StdoutSink sink;
  hft::RiskConfig const config{
      .armed = true,
      .killed = false,
      .allowed_symbols = {hft::make_symbol("ACME")},
      .allowed_symbol_count = 1,
  };
  hft::FirmwareApp app{clock, config};

  auto const event = hft::MarketEvent{
      .kind = hft::EventKind::add,
      .side = hft::Side::sell,
      .sequence = 1,
      .timestamp_ns = 100,
      .order_reference = 42,
      .symbol = hft::make_symbol("ACME"),
      .price = 12'345,
      .quantity = 10,
  };

  if (!app.publish_market_event(event)) {
    return 1;
  }
  static_cast<void>(app.run_trading());
  std::optional<hft::OrderIntent> approved;
  static_cast<void>(app.drain_intents([&approved](hft::OrderIntent const& intent) noexcept {
    approved = intent;
    return true;
  }));
  static_cast<void>(app.drain_logs(sink));
  if (!approved) {
    return 2;
  }
  fmt::println("intent ref={} side={:c} qty={} price={}", approved->user_ref,
               static_cast<char>(approved->side), approved->quantity, approved->price);
  return 0;
}
