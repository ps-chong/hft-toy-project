add_executable(
  hft_r5_tests
  test_config_snapshot.cpp
  test_control_task.cpp
  test_executor.cpp
  test_logging.cpp
  test_raii.cpp
  test_risk_engine.cpp
  test_spsc_ring.cpp)

target_link_libraries(hft_r5_tests PRIVATE hft::r5_core GTest::gmock
                                          GTest::gtest_main)

include(GoogleTest)
gtest_discover_tests(hft_r5_tests DISCOVERY_TIMEOUT 30)
