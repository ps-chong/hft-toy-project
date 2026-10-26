#pragma once

// Composition root of the R5 trading firmware.
//
// FirmwareApp owns every piece of firmware state and wires it by reference
// (dependency injection, no globals). Each public member belongs to exactly
// one execution context:
//
//   producer (PL adapter, ISR, host feeder)  publish_market_event
//   trading task (highest app priority)     run_trading, drain_intents, warm_up
//   control task                            deliver_config, publish_config
//   journal task                            poll_journal
//   log drain task                          drain_logs
//   any task                                stats (single reader), kill_switch
//
// Cross-context state is limited to the Disruptor ring and its sequences, the
// TripleBuffers, the KillSwitch, the per-context SPSC log rings, and one
// relaxed overflow counter.

#include <algorithm>
#include <atomic>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <ranges>
#include <utility>

#include <boost/lockfree/policies.hpp>
#include <boost/lockfree/spsc_queue.hpp>

#include "hft/concepts.hpp"
#include "hft/control_task.hpp"
#include "hft/disruptor/lossy_reader.hpp"
#include "hft/disruptor/pipeline.hpp"
#include "hft/disruptor/ring.hpp"
#include "hft/kill_switch.hpp"
#include "hft/logging.hpp"
#include "hft/order_manager.hpp"
#include "hft/risk_engine.hpp"
#include "hft/stages.hpp"
#include "hft/strategy.hpp"
#include "hft/triple_buffer.hpp"
#include "hft/types.hpp"

namespace hft {

template <MonotonicClock Clock, disruptor::MemoryPolicy Memory = disruptor::HostMemory>
class FirmwareApp {
public:
  static constexpr std::size_t event_capacity = protocol::ring_pl_to_r5_depth;
  static constexpr std::size_t intent_capacity = protocol::ring_r5_to_a53_depth;
  static constexpr std::size_t log_capacity = 64;
  static constexpr std::size_t control_frame_bytes = 1024;

  using event_ring = disruptor::Ring<MarketEvent, event_capacity, Memory>;
  using intent_queue =
      boost::lockfree::spsc_queue<OrderIntent, boost::lockfree::capacity<intent_capacity>>;
  using log_ring = LogRing<log_capacity>;
  using manager_type = OrderManager<Clock>;

  explicit FirmwareApp(Clock& clock, RiskConfig const& initial = {}) noexcept
      : configs_(initial),
        risk_(initial),
        manager_(clock, risk_),
        applied_revision_(initial.revision),
        book_(manager_, kill_, applied_revision_, counters_),
        strategy_risk_(manager_, strategies_, counters_),
        publisher_(intents_, kill_, applied_revision_, counters_),
        pipeline_(ring_, book_, strategy_risk_, publisher_),
        journal_(ring_),
        control_(control_actor(control_arena_, mailbox_, configs_, kill_, control_log_,
                               initial.revision)) {
    static_cast<void>(strategies_.select(initial.strategy_id));
    // Run the actor to its first co_await so the first delivery resumes it.
    static_cast<void>(control_.resume());
    stats_.publish(snapshot());
    HFT_CIB_INFO("R5 firmware application composed");
  }

  FirmwareApp(FirmwareApp const&) = delete;
  auto operator=(FirmwareApp const&) -> FirmwareApp& = delete;

  // --- producer context ------------------------------------------------------

  /// Publishes one event, or trips the kill switch when the ring is full.
  [[nodiscard]] auto publish_market_event(MarketEvent const& event) noexcept -> bool {
    if (ring_.try_publish(event, pipeline_.gating_sequence())) [[likely]] {
      return true;
    }
    // Relaxed: a monotonically increasing diagnostic count read by snapshot().
    market_overflows_.fetch_add(1U, std::memory_order_relaxed);
    kill_.trip(KillReason::market_ring_overflow,
               applied_revision_.load(std::memory_order_relaxed));
    producer_log_.log(LogLevel::error, LogMessage::market_ring_overflow);
    return false;
  }

  [[nodiscard]] auto ring_free() const noexcept -> std::size_t {
    return event_capacity - disruptor::distance(pipeline_.gating_sequence(), ring_.cursor());
  }

  // --- trading task -----------------------------------------------------------

  /// One cooperative scheduling quantum: apply any new configuration at this
  /// safe point, run every stage over at most `budget` events, then publish
  /// the statistics snapshot.
  [[nodiscard]] auto run_trading(std::size_t budget = 32) noexcept -> std::size_t {
    apply_pending_config();
    auto const overflows_before = counters_.output_overflows;
    auto const completed = pipeline_.run(budget);
    if (counters_.output_overflows != overflows_before) [[unlikely]] {
      trading_log_.log(LogLevel::error, LogMessage::intent_ring_overflow);
    }
    ++counters_.batches;
    stats_.publish(snapshot());
    return completed;
  }

  /// Offers queued intents to `publish` in order. An intent leaves the queue
  /// only after `publish` accepts it; a refusal stops the drain and is counted.
  template <std::predicate<OrderIntent const&> Publish>
  auto drain_intents(Publish&& publish, std::size_t budget = intent_capacity) noexcept
      -> std::size_t {
    auto const attempts = std::min(budget, intents_.read_available());
    auto const offers = std::views::iota(std::size_t{0}, attempts);
    auto const refused = std::ranges::find_if_not(offers, [&](std::size_t) {
      if (!std::invoke(publish, std::as_const(intents_.front()))) {
        ++counters_.publish_failures;
        return false;
      }
      intents_.pop();
      return true;
    });
    return static_cast<std::size_t>(std::ranges::distance(offers.begin(), refused));
  }

  /// Exercises the decision code on synthetic data under a killed config so
  /// the instruction cache and branch predictors are warm before the first
  /// live event. Touches only scratch copies; live state is unchanged.
  auto warm_up(std::size_t iterations) noexcept -> void {
    auto scratch_config = risk_.config();
    scratch_config.killed = true;
    RiskEngine<> scratch_risk{scratch_config};
    auto scratch_strategies = strategies_;
    MarketEvent const probe{.kind = EventKind::add,
                            .side = Side::sell,
                            .sequence = 1,
                            .symbol = make_symbol("WARMUP"),
                            .price = scratch_config.price_floor,
                            .quantity = 1};
    std::ranges::for_each(std::views::iota(std::size_t{0}, iterations),
                          [&](std::size_t round) noexcept {
                            auto event = probe;
                            event.sequence += round;
                            if (auto candidate = scratch_strategies.evaluate(event)) {
                              warm_sink_ += scratch_risk.check(*candidate).has_value() ? 1U : 0U;
                            }
                          });
  }

  // --- control task -----------------------------------------------------------

  /// Hands a risk_config record to the control actor; false means "busy".
  [[nodiscard]] auto deliver_config(RiskConfigRecord const& record) noexcept -> bool {
    return mailbox_.deliver(record);
  }

  /// Direct publication for host tools and tests that bypass record decoding.
  auto publish_config(RiskConfig const& config) noexcept -> void { configs_.publish(config); }

  // --- journal task -----------------------------------------------------------

  template <std::invocable<MarketEvent const&, disruptor::sequence_t> Deliver>
  auto poll_journal(std::size_t budget, Deliver&& deliver) noexcept -> std::size_t {
    return journal_.poll(budget, std::forward<Deliver>(deliver));
  }

  [[nodiscard]] auto journal_dropped() const noexcept -> std::uint64_t {
    return journal_.dropped();
  }

  // --- log drain task ---------------------------------------------------------

  template <LogSink Sink>
  auto drain_logs(Sink& sink, std::size_t budget = log_capacity) noexcept -> std::size_t {
    Logger<Sink> logger{sink};
    return hft::drain_logs(logger, budget, producer_log_ring_, trading_log_ring_,
                           control_log_ring_);
  }

  // --- observers ------------------------------------------------------------

  /// Latest per-batch snapshot. TripleBuffer allows one reader context.
  [[nodiscard]] auto stats() noexcept -> PipelineStats const& { return stats_.acquire(); }

  [[nodiscard]] auto kill_switch() noexcept -> KillSwitch& { return kill_; }

  [[nodiscard]] auto risk_rejections() const noexcept { return risk_.rejections(); }

private:
  auto apply_pending_config() noexcept -> void {
    auto const kill_version = kill_.version();
    if (!configs_.has_fresh() && kill_version == applied_kill_version_) [[likely]] {
      return;
    }
    auto effective = configs_.acquire();
    // A latched kill overrides whatever the control plane last published;
    // only KillSwitch::clear() can lift it.
    effective.killed = effective.killed || kill_.latched();
    risk_.update_config(effective);
    static_cast<void>(strategies_.select(effective.strategy_id));
    // Relaxed: the revision is only a label recorded by kill-switch trips.
    applied_revision_.store(effective.revision, std::memory_order_relaxed);
    applied_kill_version_ = kill_version;
  }

  [[nodiscard]] auto snapshot() const noexcept -> PipelineStats {
    return {
        .counters = counters_,
        .market_overflows = market_overflows_.load(std::memory_order_relaxed),
        .applied_revision = applied_revision_.load(std::memory_order_relaxed),
        .kill_reasons = kill_.reasons(),
        .strategy_id = strategies_.active_id(),
    };
  }

  // Cross-context hand-off points.
  event_ring ring_{};
  intent_queue intents_{};
  KillSwitch kill_{};
  TripleBuffer<RiskConfig> configs_;
  TripleBuffer<PipelineStats> stats_{};
  log_ring producer_log_ring_{};
  log_ring trading_log_ring_{};
  log_ring control_log_ring_{};
  DeferredLog<log_ring> producer_log_{producer_log_ring_};
  DeferredLog<log_ring> trading_log_{trading_log_ring_};
  DeferredLog<log_ring> control_log_{control_log_ring_};
  std::atomic<std::uint64_t> market_overflows_{};

  // Trading-task state.
  RiskEngine<> risk_;
  StrategySelector strategies_{};
  manager_type manager_;
  PipelineCounters counters_{};
  std::atomic<std::uint32_t> applied_revision_;
  std::uint32_t applied_kill_version_{};
  std::uint32_t warm_sink_{};
  BookStage<manager_type> book_;
  StrategyRiskStage<manager_type> strategy_risk_;
  IntentPublishStage<intent_queue> publisher_;
  disruptor::Pipeline<event_ring, Decision, BookStage<manager_type>,
                      StrategyRiskStage<manager_type>, IntentPublishStage<intent_queue>>
      pipeline_;

  // Journal-task state.
  disruptor::LossyReader<event_ring> journal_;

  // Control-task state. The arena must outlive the task that uses it.
  FrameArena<control_frame_bytes> control_arena_{};
  ControlMailbox mailbox_{};
  ControlTask control_;
};

}  // namespace hft
