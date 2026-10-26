#pragma once

// Gating consumer chain for one Disruptor ring.
//
// Stages are a compile-time list. Stage I processes only what stage I-1
// (stage 0: the producer cursor) has completed, so the last stage is always
// the slowest one, and its sequence gates the producer. Each stage reads its
// barrier once and publishes its own sequence once per batch: this is the
// Disruptor batching effect, one acquire and one release per stage per batch
// instead of per event.
//
// Every slot has an Annotation that earlier stages write and later stages
// read; the release/acquire hand-off on the stage sequences orders those
// writes, so the chain stays race-free even if stages later move to
// different tasks.

#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <ranges>
#include <tuple>
#include <utility>

#include "hft/disruptor/ring.hpp"

namespace hft::disruptor {

/// `halt` stops the stage before consuming the current event; the event is
/// offered again on the next run.
enum class StageControl : std::uint8_t {
  proceed,
  halt,
};

template <typename S, typename T, typename Annotation>
concept Stage = requires(S& stage, T const& event, Annotation& annotation, sequence_t sequence) {
  { stage.on_event(event, annotation, sequence) } noexcept -> std::same_as<StageControl>;
};

template <typename RingT, typename Annotation, typename... Stages>
  requires(sizeof...(Stages) >= 1 &&
           (Stage<Stages, typename RingT::value_type, Annotation> && ...))
class Pipeline {
public:
  static constexpr std::size_t stage_count = sizeof...(Stages);

  /// Stages are injected by reference; the composition root owns them.
  constexpr explicit Pipeline(RingT& ring, Stages&... stages) noexcept
      : ring_(ring), stages_(stages...) {
    auto const start = ring_.cursor();
    std::ranges::for_each(sequences_, [start](Sequence& sequence) noexcept {
      sequence.value.store(start, std::memory_order_relaxed);
    });
  }

  Pipeline(Pipeline const&) = delete;
  auto operator=(Pipeline const&) -> Pipeline& = delete;

  /// Runs every stage, oldest first, over at most `budget` events each.
  /// Returns how many events the final stage completed.
  auto run(std::size_t budget) noexcept -> std::size_t {
    return [this, budget]<std::size_t... I>(std::index_sequence<I...>) {
      std::size_t completed{};
      ((completed = this->template run_stage<I>(budget)), ...);
      return completed;
    }(std::index_sequence_for<Stages...>{});
  }

  /// The producer may reuse slots strictly behind this sequence.
  [[nodiscard]] auto gating_sequence() const noexcept -> sequence_t {
    return sequences_.back().load();
  }

  [[nodiscard]] auto stage_sequence(std::size_t index) const noexcept -> sequence_t {
    return sequences_[index].load();
  }

private:
  template <std::size_t I>
  auto run_stage(std::size_t budget) noexcept -> std::size_t {
    auto const barrier = [this]() noexcept {
      if constexpr (I == 0) {
        return ring_.cursor();
      } else {
        return sequences_[I - 1].load();
      }
    }();
    auto const start = sequences_[I].owned();
    auto const available =
        static_cast<sequence_t>(std::min<std::size_t>(distance(start, barrier), budget));

    auto& stage = std::get<I>(stages_);
    auto const offsets = std::views::iota(sequence_t{0}, available);
    auto const stop =
        std::ranges::find_if(offsets, [this, &stage, start](sequence_t offset) noexcept {
          auto const sequence = start + offset;
          auto const event = ring_.read(sequence);
          return stage.on_event(event, annotations_[sequence & mask], sequence) ==
                 StageControl::halt;
        });
    auto const consumed = static_cast<sequence_t>(std::ranges::distance(offsets.begin(), stop));
    if (consumed != 0U) {
      sequences_[I].store(start + consumed);
    }
    return consumed;
  }

  static constexpr sequence_t mask = static_cast<sequence_t>(RingT::capacity() - 1U);

  RingT& ring_;
  std::tuple<Stages&...> stages_;
  std::array<Sequence, stage_count> sequences_{};
  std::array<Annotation, RingT::capacity()> annotations_{};
};

}  // namespace hft::disruptor
