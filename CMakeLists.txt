cmake_minimum_required(VERSION 3.28)

project(
  hft_toy_project
  VERSION 0.1.0
  DESCRIPTION "MYD-CZU5EV-V2 ITCH/OUCH high-frequency trading reference design"
  LANGUAGES C CXX)

option(HFT_BUILD_TESTS "Build host-side unit tests" ON)
option(HFT_ENABLE_CIB "Enable compile-time-init-build integration" OFF)
option(HFT_ENABLE_BOOST "Fetch and use the pinned Boost release" ON)
option(HFT_WARNINGS_AS_ERRORS "Treat compiler warnings as errors" ON)
option(HFT_ENABLE_COVERAGE "Instrument host tests for source coverage" OFF)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(ProjectOptions)
include(Dependencies)

add_subdirectory(cortex/r5 ${CMAKE_CURRENT_BINARY_DIR}/r5)

if(HFT_BUILD_TESTS)
  include(CTest)
  enable_testing()
  add_subdirectory(tests/cpp)
endif()
