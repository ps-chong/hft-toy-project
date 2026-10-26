#pragma once

// The three gating Disruptor stages of the R5 trading pipeline. All run in
// the trading task, in ring order, sharing one Decision annotation per slot:
//
//   BookStage         validates ABI and sequence, applies lifecycle events
//   StrategyRiskStage asks the active strategy, then risk, for entry candidates
//   IntentPublishStage moves approved intents to the outbound queue
//
// Counters are plain integers: only the trading task writes them, and other
// tasks read them through the per-batch PipelineStats snapshot.

#include <atomic>
#include <cstdint>
#include <optional>

#include "hft/disruptor/pipeline.hpp"
#include "hft/kill_switch.hpp"
#include "hft/order_manager.hpp"
#include "hft/strategy.hpp"
#include "hft/types.hpp"

namespace hft {

struct PipelineCounters {
  std::uint64_t events{};
  std::uint64_t intents{};
  std::uint64_t ignored{};
  std::uint64_t rejected{};
  std::uint64_t suppressed{};
  std::uint64_t output_overflows{};
  std::uint64_t publish_failures{};
  std::uint64_t batches{};
};

/// Cross-task view published once per batch (see FirmwareApp::stats()).
struct PipelineStats {
  PipelineCounters counters{};
  std::uint64_t market_overflows{};
  std::uint32_t applied_revision{};
  std::uint16_t kill_reasons{};
  std::uint8_t strategy_id{};
};

/// Per-slot hand-off between stages.
struct Decision {
  enum class Outcome : std::uint8_t {
    ignored,
    rejected,
    candidate,
    approved,
  };

  Outcome outcome{Outcome::ignored};
  ProcessingError error{};
  OrderIntent intent{};
};

template <typename Manager>
class BookStage {
public:
  constexpr BookStage(Manager& manager, KillSwitch& kill,
                      std::atomic<std::uint32_t> const& applied_revision,
                      PipelineCounters& counters) noexcept
      : manager_(manager), kill_(kill), applied_revision_(applied_revision), counters_(counters) {}

  auto on_event(MarketEvent const& event, Decision& decision, disruptor::sequence_t) noexcept
      -> disruptor::StageControl {
    ++counters_.events;
    // The PL flags the first event after a MoldUDP64 gap: the book may have
    // missed updates, so fail closed until the operator re-arms.
    if ((event.flags & event_flag_feed_gap) != 0U) [[unlikely]] {
      kill_.trip(KillReason::feed_gap, applied_revision_.load(std::memory_order_relaxed));
    }
    auto const admission = manager_.admit(event);
    if (!admission) [[unlikely]] {
      decision = {.outcome = Decision::Outcome::rejected, .error = admission.error()};
      ++counters_.rejected;
    } else if (*admission == Admission::entry_candidate) {
      decision.outcome = Decision::Outcome::candidate;
    } else {
      decision.outcome = Decision::Outcome::ignored;
      ++counters_.ignored;
    }
    return disruptor::StageControl::proceed;
  }

private:
  Manager& manager_;
  KillSwitch& kill_;
  std::atomic<std::uint32_t> const& applied_revision_;
  PipelineCounters& counters_;
};

template <typename Manager>
class StrategyRiskStage {
public:
  constexpr StrategyRiskStage(Manager& manager, StrategySelector& strategies,
                              PipelineCounters& counters) noexcept
      : manager_(manager), strategies_(strategies), counters_(counters) {}

  auto on_event(MarketEvent const& event, Decision& decision, disruptor::sequence_t) noexcept
      -> disruptor::StageControl {
    if (decision.outcome != Decision::Outcome::candidate) {
      return disruptor::StageControl::proceed;
    }
    auto const result = manager_.decide(event, strategies_);
    if (!result) {
      decision.outcome = Decision::Outcome::rejected;
      decision.error = result.error();
      ++counters_.rejected;
    } else if (auto const& proposal = *result) {
      decision.outcome = Decision::Outcome::approved;
      decision.intent = *proposal;
    } else {
      decision.outcome = Decision::Outcome::ignored;
      ++counters_.ignored;
    }
    return disruptor::StageControl::proceed;
  }

private:
  Manager& manager_;
  StrategySelector& strategies_;
  PipelineCounters& counters_;
};

/// The outbound queue is anything with a non-blocking `bool push(OrderIntent)`.
template <typename IntentQueue>
class IntentPublishStage {
public:
  constexpr IntentPublishStage(IntentQueue& queue, KillSwitch& kill,
                               std::atomic<std::uint32_t> const& applied_revision,
                               PipelineCounters& counters) noexcept
      : queue_(queue), kill_(kill), applied_revision_(applied_revision), counters_(counters) {}

  auto on_event(MarketEvent const&, Decision& decision, disruptor::sequence_t) noexcept
      -> disruptor::StageControl {
    if (decision.outcome != Decision::Outcome::approved) {
      return disruptor::StageControl::proceed;
    }
    // Re-check at publish time: another context may have tripped the switch
    // after this batch applied its configuration.
    if (kill_.latched()) [[unlikely]] {
      decision.outcome = Decision::Outcome::ignored;
      ++counters_.suppressed;
      return disruptor::StageControl::proceed;
    }
    if (!queue_.push(decision.intent)) [[unlikely]] {
      ++counters_.output_overflows;
      kill_.trip(KillReason::intent_ring_overflow,
                 applied_revision_.load(std::memory_order_relaxed));
      return disruptor::StageControl::halt;
    }
    ++counters_.intents;
    return disruptor::StageControl::proceed;
  }

private:
  IntentQueue& queue_;
  KillSwitch& kill_;
  std::atomic<std::uint32_t> const& applied_revision_;
  PipelineCounters& counters_;
};

}  // namespace hft
