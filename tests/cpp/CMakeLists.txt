add_executable(
  hft_r5_tests
  test_app.cpp
  test_control_task.cpp
  test_disruptor.cpp
  test_ipc_vectors.cpp
  test_kill_switch.cpp
  test_logging.cpp
  test_raii.cpp
  test_risk_engine.cpp
  test_strategy.cpp
  test_triple_buffer.cpp)

target_link_libraries(hft_r5_tests PRIVATE hft::r5_core GTest::gmock
                                          GTest::gtest_main)
target_compile_definitions(
  hft_r5_tests PRIVATE HFT_VECTOR_DIR="${PROJECT_SOURCE_DIR}/protocol/vectors")

include(GoogleTest)
gtest_discover_tests(hft_r5_tests DISCOVERY_TIMEOUT 30)
