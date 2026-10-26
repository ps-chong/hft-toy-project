// hft_r5_sim: the real R5 firmware code driven by a POSIX host adapter.
//
// The adapter implements the hft/platform.h C ABI over two Unix stream
// sockets and runs every firmware context in one cooperative loop, the way
// the R5's FreeRTOS tasks share one core:
//
//   --events PATH  hft-plsim connects; 64-byte normalized_event records in
//   --rpmsg  PATH  hftd connects;      order_intent out, risk_config in
//
// The C hooks carry no context argument, so the adapter state is one
// function-local static object: this file is the C-API boundary the coding
// standard allows to hold it. Every hook runs on the loop's single thread.

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <optional>
#include <ranges>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include <boost/scope/unique_fd.hpp>
#include <fmt/format.h>

#include "hft/app.hpp"
#include "hft/platform.h"

namespace {

using Clock = std::chrono::steady_clock;
using boost::scope::unique_fd;

[[nodiscard]] auto monotonic_ns() noexcept -> std::uint64_t {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch())
          .count());
}

/// Non-blocking byte stream carrying fixed 64-byte IPC records.
class RecordStream {
public:
  explicit RecordStream(unique_fd fd) noexcept : fd_(std::move(fd)) {}

  [[nodiscard]] auto fd() const noexcept -> int { return fd_.get(); }

  /// Reads everything available. False once the peer has closed.
  [[nodiscard]] auto pump() -> bool {
    std::array<std::byte, 4096> chunk{};
    for (;;) {
      auto const received = ::read(fd_.get(), chunk.data(), chunk.size());
      if (received > 0) {
        partial_.insert(partial_.end(), chunk.begin(), chunk.begin() + received);
        continue;
      }
      if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        break;
      }
      return false;
    }
    auto const complete = partial_.size() / HFT_IPC_RECORD_SIZE * HFT_IPC_RECORD_SIZE;
    for (std::size_t offset = 0; offset < complete; offset += HFT_IPC_RECORD_SIZE) {
      hft_ipc_record record{};
      std::memcpy(record.bytes, partial_.data() + offset, HFT_IPC_RECORD_SIZE);
      inbox_.push_back(record);
    }
    partial_.erase(partial_.begin(), partial_.begin() + static_cast<std::ptrdiff_t>(complete));
    return true;
  }

  [[nodiscard]] auto pop() -> std::optional<hft_ipc_record> {
    if (inbox_.empty()) {
      return std::nullopt;
    }
    auto const record = inbox_.front();
    inbox_.pop_front();
    return record;
  }

  /// Queues one record; false (record not taken) while earlier bytes are
  /// still waiting for socket space, which surfaces as backpressure.
  [[nodiscard]] auto send(hft_ipc_record const& record) -> bool {
    flush();
    if (!outbox_.empty()) {
      return false;
    }
    auto const bytes = std::as_bytes(std::span{record.bytes});
    outbox_.insert(outbox_.end(), bytes.begin(), bytes.end());
    flush();
    return true;
  }

  auto flush() -> void {
    while (!outbox_.empty()) {
      auto const sent = ::send(fd_.get(), outbox_.data(), outbox_.size(), MSG_NOSIGNAL);
      if (sent <= 0) {
        return;
      }
      outbox_.erase(outbox_.begin(), outbox_.begin() + sent);
    }
  }

private:
  unique_fd fd_;
  std::vector<std::byte> partial_;
  std::deque<hft_ipc_record> inbox_;
  std::vector<std::byte> outbox_;
};

[[nodiscard]] auto listen_unix(std::string const& path) -> unique_fd {
  unique_fd fd{::socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)};
  if (!fd) {
    return fd;
  }
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::ranges::copy(std::string_view{path}.substr(0, sizeof(address.sun_path) - 1),
                    address.sun_path);
  ::unlink(path.c_str());
  if (::bind(fd.get(), reinterpret_cast<sockaddr const*>(&address), sizeof(address)) != 0 ||
      ::listen(fd.get(), 4) != 0) {
    return unique_fd{};
  }
  return fd;
}

/// Latency samples: intake time of each event, keyed by feed sequence.
class LatencyProbe {
public:
  auto on_intake(std::uint64_t sequence) noexcept -> void {
    intake_[sequence % intake_.size()] = {.sequence = sequence, .at_ns = monotonic_ns()};
  }

  auto on_intent(std::uint64_t source_sequence) -> void {
    auto const& entry = intake_[source_sequence % intake_.size()];
    if (entry.sequence == source_sequence) {
      samples_.push_back(monotonic_ns() - entry.at_ns);
    }
  }

  auto flush_to(std::FILE* output) -> void {
    if (output == nullptr) {
      samples_.clear();
      return;
    }
    std::ranges::for_each(samples_, [output](std::uint64_t sample) {
      fmt::println(output, R"({{"tick_to_intent_ns": {}}})", sample);
    });
    std::fflush(output);
    samples_.clear();
  }

private:
  struct Entry {
    std::uint64_t sequence{};
    std::uint64_t at_ns{};
  };
  std::array<Entry, 4096> intake_{};
  std::vector<std::uint64_t> samples_;
};

/// All adapter state. Reached by the C hooks through adapter().
struct Adapter {
  std::optional<RecordStream> events;
  std::optional<RecordStream> rpmsg;
  LatencyProbe latency;
  std::uint64_t journal_records{};
  std::uint64_t intents_refused{};
};

auto adapter() -> Adapter& {
  static Adapter instance;
  return instance;
}

// Written from the signal handler, read by the loop: lock-free atomic.
std::atomic<bool> stop_requested{false};

auto on_signal(int) -> void { stop_requested.store(true, std::memory_order_relaxed); }

}  // namespace

// ----------------------------------------------------------- platform.h hooks

extern "C" {

auto hft_platform_now_ns() noexcept -> std::uint64_t { return monotonic_ns(); }

auto hft_platform_poll_event(hft_ipc_record* out) noexcept -> bool {
  auto& state = adapter();
  if (!state.events) {
    return false;
  }
  auto const record = state.events->pop();
  if (!record) {
    return false;
  }
  *out = *record;
  state.latency.on_intake(hft::from_ipc<hft::MarketEvent>(*record).sequence);
  return true;
}

auto hft_platform_publish_intent(hft_ipc_record const* intent) noexcept -> bool {
  auto& state = adapter();
  if (!state.rpmsg || !state.rpmsg->send(*intent)) {
    ++state.intents_refused;
    return false;
  }
  state.latency.on_intent(hft::from_ipc<hft::OrderIntent>(*intent).source_sequence);
  return true;
}

auto hft_platform_poll_config(hft_ipc_record* out) noexcept -> bool {
  auto& state = adapter();
  if (!state.rpmsg) {
    return false;
  }
  auto const record = state.rpmsg->pop();
  if (!record) {
    return false;
  }
  *out = *record;
  return true;
}

auto hft_platform_publish_log(char const* text, std::size_t length) noexcept -> bool {
  // Raw stdio: this hook is noexcept, and fmt's stream writes may throw.
  std::fwrite(text, sizeof(char), length, stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
  return true;
}

auto hft_platform_publish_journal(hft_ipc_record const*) noexcept -> bool {
  ++adapter().journal_records;
  return true;
}

auto hft_platform_dcache_invalidate(void const*, std::size_t) noexcept -> void {}

auto hft_platform_dcache_clean(void const*, std::size_t) noexcept -> void {}

}  // extern "C"

namespace {

struct PlatformClock {
  [[nodiscard]] auto now_ns() noexcept -> std::uint64_t { return hft_platform_now_ns(); }
};

struct StdoutSink {
  auto write(std::string_view line) noexcept -> void {
    static_cast<void>(hft_platform_publish_log(line.data(), line.size()));
  }
};

using App = hft::FirmwareApp<PlatformClock>;

struct Options {
  std::string events_path{"/run/hft/events.sock"};
  std::string rpmsg_path{"/run/hft/rpmsg.sock"};
  std::string latency_path;
  std::chrono::milliseconds stats_interval{1000};
};

[[nodiscard]] auto parse(std::span<char*> arguments) -> Options {
  Options options;
  for (std::size_t index = 1; index + 1 < arguments.size(); index += 2) {
    std::string_view const flag{arguments[index]};
    std::string const value{arguments[index + 1]};
    if (flag == "--events") {
      options.events_path = value;
    } else if (flag == "--rpmsg") {
      options.rpmsg_path = value;
    } else if (flag == "--latency-out") {
      options.latency_path = value;
    } else if (flag == "--stats-interval-ms") {
      options.stats_interval = std::chrono::milliseconds{std::stoll(value)};
    }
  }
  return options;
}

auto accept_into(int listener, std::optional<RecordStream>& slot, std::string_view role) -> void {
  unique_fd peer{::accept4(listener, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC)};
  if (peer) {
    slot.emplace(std::move(peer));
    fmt::println(R"({{"type":"r5_connected","role":"{}"}})", role);
    std::fflush(stdout);
  }
}

auto run_contexts(App& app, StdoutSink& sink) -> void {
  // Trading task: bounded intake, pipeline quantum, consume-if intent drain.
  auto const intake = std::min<std::size_t>(app.ring_free(), 64);
  static_cast<void>(std::ranges::find_if_not(std::views::iota(std::size_t{0}, intake),
                                             [&app](std::size_t) {
                                               hft_ipc_record raw{};
                                               if (!hft_platform_poll_event(&raw)) {
                                                 return false;
                                               }
                                               static_cast<void>(app.publish_market_event(
                                                   hft::from_ipc<hft::MarketEvent>(raw)));
                                               return true;
                                             }));
  static_cast<void>(app.run_trading(64));
  static_cast<void>(app.drain_intents([](hft::OrderIntent const& intent) noexcept {
    auto const raw = hft::to_ipc(intent);
    return hft_platform_publish_intent(&raw);
  }));
  // Control task.
  hft_ipc_record raw{};
  if (hft_platform_poll_config(&raw)) {
    static_cast<void>(app.deliver_config(hft::from_ipc<hft::RiskConfigRecord>(raw)));
  }
  // Journal and log drain tasks.
  static_cast<void>(app.poll_journal(64, [](hft::MarketEvent const& event, auto) noexcept {
    auto const record = hft::to_ipc(event);
    static_cast<void>(hft_platform_publish_journal(&record));
  }));
  static_cast<void>(app.drain_logs(sink));
}

auto print_stats(App& app) -> void {
  auto const& stats = app.stats();
  auto const& state = adapter();
  fmt::println(
      R"({{"type":"r5_stats","events":{},"intents":{},"rejected":{},"ignored":{},)"
      R"("suppressed":{},"publish_failures":{},"market_overflows":{},"kill_reasons":{},)"
      R"("revision":{},"strategy":{},"journal":{},"journal_dropped":{}}})",
      stats.counters.events, stats.counters.intents, stats.counters.rejected,
      stats.counters.ignored, stats.counters.suppressed, stats.counters.publish_failures,
      stats.market_overflows, stats.kill_reasons, stats.applied_revision, stats.strategy_id,
      state.journal_records, app.journal_dropped());
  std::fflush(stdout);
}

struct FileCloser {
  auto operator()(std::FILE* file) const noexcept -> void {
    std::fclose(file);  // NOLINT(cppcoreguidelines-owning-memory): the deleter is the owner
  }
};
using UniqueFile = std::unique_ptr<std::FILE, FileCloser>;

}  // namespace

// Host tool: an exception (bad argument, allocation failure) terminates the
// model, which is the fail-closed outcome the demo expects.
// NOLINTNEXTLINE(bugprone-exception-escape)
auto main(int argc, char** argv) -> int {
  auto const options = parse(std::span{argv, static_cast<std::size_t>(argc)});
  std::signal(SIGINT, on_signal);
  std::signal(SIGTERM, on_signal);

  auto events_listener = listen_unix(options.events_path);
  auto rpmsg_listener = listen_unix(options.rpmsg_path);
  if (!events_listener || !rpmsg_listener) {
    fmt::println(stderr, "hft_r5_sim: cannot listen on {} / {}", options.events_path,
                 options.rpmsg_path);
    return 1;
  }
  UniqueFile latency_output;
  if (!options.latency_path.empty()) {
    // NOLINTNEXTLINE(cppcoreguidelines-owning-memory): ownership moves into UniqueFile
    latency_output.reset(std::fopen(options.latency_path.c_str(), "w"));
  }

  PlatformClock clock;
  StdoutSink sink;
  // Fail closed until hftd delivers an armed risk_config record.
  App app{clock, hft::RiskConfig{.armed = false, .killed = true}};
  app.warm_up(64);
  fmt::println(R"({{"type":"r5_ready","events":"{}","rpmsg":"{}"}})", options.events_path,
               options.rpmsg_path);
  std::fflush(stdout);

  auto& state = adapter();
  auto next_stats = Clock::now() + options.stats_interval;
  while (!stop_requested.load(std::memory_order_relaxed)) {
    std::array<pollfd, 4> fds{{
        {.fd = events_listener.get(), .events = POLLIN, .revents = 0},
        {.fd = rpmsg_listener.get(), .events = POLLIN, .revents = 0},
        {.fd = state.events ? state.events->fd() : -1, .events = POLLIN, .revents = 0},
        {.fd = state.rpmsg ? state.rpmsg->fd() : -1, .events = POLLIN, .revents = 0},
    }};
    static_cast<void>(::poll(fds.data(), fds.size(), 1));
    if ((fds[0].revents & POLLIN) != 0) {
      accept_into(events_listener.get(), state.events, "events");
    }
    if ((fds[1].revents & POLLIN) != 0) {
      accept_into(rpmsg_listener.get(), state.rpmsg, "rpmsg");
    }
    if (state.events && !state.events->pump()) {
      state.events.reset();
    }
    if (state.rpmsg) {
      state.rpmsg->flush();
      if (!state.rpmsg->pump()) {
        state.rpmsg.reset();
      }
    }
    run_contexts(app, sink);
    if (Clock::now() >= next_stats) {
      print_stats(app);
      state.latency.flush_to(latency_output.get());
      next_stats += options.stats_interval;
    }
  }
  print_stats(app);
  state.latency.flush_to(latency_output.get());
  ::unlink(options.events_path.c_str());
  ::unlink(options.rpmsg_path.c_str());
  return 0;
}
