#include <string_view>

#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "hft/logging.hpp"

namespace {

class MockSink {
public:
  MOCK_METHOD(void, write, (std::string_view), (noexcept));
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
