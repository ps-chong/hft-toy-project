// Bounded logging: formatting never allocates, deferred records are formatted
// only when drained, and a full ring drops instead of blocking.

#include <string>
#include <string_view>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "hft/logging.hpp"

namespace {

class MockSink {
public:
  MOCK_METHOD(void, write, (std::string_view), (noexcept));
};

struct VectorSink {
  std::vector<std::string> lines;
  auto write(std::string_view line) noexcept -> void { lines.emplace_back(line); }
};

}  // namespace

TEST(Logger, FormatsIntoBoundedSink) {
  MockSink sink;
  hft::Logger<MockSink, 64> logger{sink};
  EXPECT_CALL(sink, write("INFO order 42 accepted"));
  logger.write(hft::LogLevel::info, "order {} accepted", 42);
}

TEST(Logger, TruncatesWithoutAllocatingPastBuffer) {
  MockSink sink;
  hft::Logger<MockSink, 12> logger{sink};
  EXPECT_CALL(sink, write(testing::Truly(
                        [](std::string_view value) { return value.size() == 12; })));
  logger.write(hft::LogLevel::warning, "{}", "a very long diagnostic");
}

TEST(Logger, EmitsStableLevelPrefixes) {
  MockSink sink;
  hft::Logger<MockSink, 64> logger{sink};
  testing::InSequence sequence;
  EXPECT_CALL(sink, write("DEBUG debug"));
  EXPECT_CALL(sink, write("WARN warning"));
  EXPECT_CALL(sink, write("ERROR error"));
  logger.write(hft::LogLevel::debug, "debug");
  logger.write(hft::LogLevel::warning, "warning");
  logger.write(hft::LogLevel::error, "error");
}

TEST(DeferredLog, RecordsAreFormattedOnlyWhenDrained) {
  hft::LogRing<4> ring;
  hft::DeferredLog log{ring};
  log.log(hft::LogLevel::info, hft::LogMessage::config_applied, 7, 1);
  log.log(hft::LogLevel::warning, hft::LogMessage::kill_clear_refused, 8, 0x6);

  VectorSink sink;
  hft::Logger<VectorSink> logger{sink};
  EXPECT_EQ(hft::drain_logs(logger, 8, ring), 2U);
  EXPECT_THAT(sink.lines,
              testing::ElementsAre("INFO risk config revision 7 applied (strategy 1)",
                                   "WARN kill clear refused for revision 8 (reasons 0x6)"));
}

TEST(DeferredLog, FullRingCountsDropsInsteadOfBlocking) {
  hft::LogRing<2> ring;
  hft::DeferredLog log{ring};
  for (int index = 0; index < 5; ++index) {
    log.log(hft::LogLevel::error, hft::LogMessage::market_ring_overflow);
  }
  EXPECT_EQ(log.dropped(), 3U);
  VectorSink sink;
  hft::Logger<VectorSink> logger{sink};
  EXPECT_EQ(hft::drain_logs(logger, 1, ring), 1U) << "the drain budget is honoured";
}
