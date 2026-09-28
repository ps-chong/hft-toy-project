#include <cstdio>
#include <string_view>

#include "hft/app.hpp"

namespace {

struct HostClock {
  std::uint64_t value{};
  [[nodiscard]] auto now_ns() noexcept -> std::uint64_t { return ++value; }
};

struct StdoutSink {
  auto write(std::string_view message) noexcept -> void {
    std::fwrite(message.data(), sizeof(char), message.size(), stdout);
    std::fputc('\n', stdout);
  }
};

}  // namespace

auto main() -> int {
  HostClock clock;
  StdoutSink sink;
  hft::RiskConfig config{
      .armed = true,
      .killed = false,
      .allowed_symbols = {hft::make_symbol("ACME")},
      .allowed_symbol_count = 1,
  };
  hft::FirmwareApp app{clock, sink, config};

  auto event = hft::MarketEvent{
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
  static_cast<void>(app.run_once());
  auto intent = app.next_intent();
  if (!intent) {
    return 2;
  }
  std::printf("intent ref=%u qty=%u price=%llu\n", intent->user_ref,
              intent->quantity,
              static_cast<unsigned long long>(intent->price));
  return 0;
}
