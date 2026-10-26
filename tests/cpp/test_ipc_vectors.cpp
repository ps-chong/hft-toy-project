// Cross-language contract check: the generator's golden IPC images must
// decode into the hand-written C++ structs field by field. The Rust crate
// runs the same check against the same files.

#include <algorithm>
#include <array>
#include <cstddef>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "hft/types.hpp"

namespace {

template <hft::IpcRecord Record>
auto load(std::string const& name) -> Record {
  std::ifstream input{std::string{HFT_VECTOR_DIR} + "/" + name, std::ios::binary};
  std::vector<char> const bytes{std::istreambuf_iterator<char>{input}, {}};
  EXPECT_EQ(bytes.size(), HFT_IPC_RECORD_SIZE) << name;
  hft_ipc_record raw{};
  std::copy_n(bytes.begin(), std::min(bytes.size(), sizeof(raw.bytes)), raw.bytes);
  return hft::from_ipc<Record>(raw);
}

}  // namespace

TEST(IpcVectors, NormalizedEventMatchesSchemaImage) {
  auto const event = load<hft::MarketEvent>("ipc_normalized_event.bin");
  EXPECT_EQ(event.abi_version, hft::ipc_abi_version);
  EXPECT_EQ(event.kind, hft::EventKind::add);
  EXPECT_EQ(event.side, hft::Side::buy);
  EXPECT_EQ(event.sequence, 1U);
  EXPECT_EQ(event.order_reference, 0x0102'0304'0506'0708U);
  EXPECT_EQ(hft::symbol_view(event.symbol), "ACME");
  EXPECT_EQ(event.price, 1'234'500U);
  EXPECT_EQ(event.quantity, 100U);
  EXPECT_EQ(event.stock_locate, 1U);
}

TEST(IpcVectors, OrderIntentMatchesSchemaImage) {
  auto const intent = load<hft::OrderIntent>("ipc_order_intent.bin");
  EXPECT_EQ(intent.action, hft::OrderAction::enter);
  EXPECT_EQ(intent.side, hft::Side::sell);
  EXPECT_EQ(intent.user_ref, 7U);
  EXPECT_EQ(intent.quantity, 5U);
  EXPECT_EQ(intent.risk_revision, 3U);
  EXPECT_EQ(intent.stock_locate, 1U);
}

TEST(IpcVectors, RiskConfigMatchesSchemaImage) {
  auto const config = load<hft::RiskConfigRecord>("ipc_risk_config.bin");
  EXPECT_TRUE(hft::has_flag(config.flags, hft::ConfigFlag::armed));
  EXPECT_FALSE(hft::has_flag(config.flags, hft::ConfigFlag::kill));
  EXPECT_TRUE(hft::has_flag(config.flags, hft::ConfigFlag::clear_kill));
  EXPECT_EQ(config.revision, 4U);
  EXPECT_EQ(config.price_ceiling, 1'000'000'000U);
  EXPECT_EQ(config.strategy_id, 1U);
  EXPECT_EQ(config.allowed_locate_count, 2U);
  EXPECT_EQ(config.allowed_locates[1], 7U);
}
