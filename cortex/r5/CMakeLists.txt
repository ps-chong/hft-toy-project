add_library(hft_r5_core INTERFACE)
add_library(hft::r5_core ALIAS hft_r5_core)

target_include_directories(
  hft_r5_core
  INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${PROJECT_SOURCE_DIR}/protocol/generated/cpp")
target_link_libraries(hft_r5_core INTERFACE hft::project_options
                                            fmt::fmt-header-only)

if(NOT HFT_ENABLE_BOOST)
  message(FATAL_ERROR "The R5 core requires the pinned Boost.MP11, Lockfree, and Scope headers")
endif()
if(CMAKE_CROSSCOMPILING)
  # Boost::lockfree also links Boost.Atomic's compiled lock pool, which needs
  # pthreads. The SPSC queue itself uses std::atomic (BOOST_LOCKFREE_FORCE_BOOST_ATOMIC
  # stays undefined), so the bare-metal build takes the headers only.
  add_library(hft_boost_lockfree_headers INTERFACE)
  target_include_directories(
    hft_boost_lockfree_headers SYSTEM
    INTERFACE $<TARGET_PROPERTY:boost_lockfree,INTERFACE_INCLUDE_DIRECTORIES>)
  target_link_libraries(
    hft_boost_lockfree_headers
    INTERFACE Boost::align Boost::assert Boost::config Boost::core
              Boost::parameter Boost::predef Boost::utility)
  set(hft_lockfree_target hft_boost_lockfree_headers)
else()
  set(hft_lockfree_target Boost::lockfree)
endif()
target_link_libraries(hft_r5_core INTERFACE Boost::mp11 ${hft_lockfree_target} Boost::scope)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(hft_r5_core INTERFACE -Wno-error=undef)
endif()

if(CMAKE_CROSSCOMPILING)
  # Vendor headers intentionally probe undefined feature macros and contain
  # implementation casts. Keep project warnings strict without promoting those
  # third-party diagnostics to cross-build failures.
  target_compile_options(
    hft_r5_core
    INTERFACE -Wno-error=cast-align -Wno-error=sign-conversion)
endif()

if(HFT_ENABLE_CIB)
  if(TARGET cib)
    target_link_libraries(hft_r5_core INTERFACE cib)
    target_compile_definitions(hft_r5_core INTERFACE HFT_HAS_CIB=1)
  else()
    message(FATAL_ERROR "HFT_ENABLE_CIB is ON but the cib target is unavailable")
  endif()
endif()

if(CMAKE_CROSSCOMPILING)
  add_executable(hft_r5_firmware src/firmware_main.cpp src/boost_no_exceptions.cpp)
  target_link_libraries(hft_r5_firmware PRIVATE hft::r5_core)
  target_link_options(hft_r5_firmware PRIVATE
                      --specs=nosys.specs
                      "-Wl,-Map=${CMAKE_CURRENT_BINARY_DIR}/hft_r5_firmware.map")
  set_target_properties(hft_r5_firmware PROPERTIES SUFFIX ".elf")
else()
  add_executable(hft_r5_host_demo src/host_demo.cpp)
  target_link_libraries(hft_r5_host_demo PRIVATE hft::r5_core)

  # Socket-driven R5 model for the Docker Compose demo (POSIX hosts only).
  if(UNIX)
    add_executable(hft_r5_sim src/host_platform.cpp)
    target_link_libraries(hft_r5_sim PRIVATE hft::r5_core)
  endif()
endif()
