#include <gtest/gtest.h>

#include "hft/config_snapshot.hpp"
#include "hft/risk_engine.hpp"

TEST(ConfigSnapshot, PublishesWholeVersionAtSafePoint) {
  hft::RiskConfig initial{.armed = false, .killed = true, .revision = 1};
  hft::ConfigSnapshot snapshot{initial};

  auto observed = snapshot.load();
  EXPECT_FALSE(observed.armed);
  EXPECT_TRUE(observed.killed);
  EXPECT_EQ(observed.revision, 1);

  auto next = initial;
  next.armed = true;
  next.killed = false;
  next.revision = 2;
  next.allowed_symbols[0] = hft::make_symbol("ACME");
  next.allowed_symbol_count = 1;
  snapshot.publish(next);

  observed = snapshot.load();
  EXPECT_TRUE(observed.armed);
  EXPECT_FALSE(observed.killed);
  EXPECT_EQ(observed.revision, 2);
  EXPECT_EQ(observed.allowed_symbols[0], hft::make_symbol("ACME"));
}
