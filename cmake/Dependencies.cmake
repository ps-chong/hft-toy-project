include(FetchContent)

# Keep every revision immutable. Update intentionally and verify all host/cross builds.
set(HFT_BOOST_VERSION "1.92.0" CACHE STRING "Pinned Boost version")
set(HFT_FMT_VERSION "12.0.0" CACHE STRING "Pinned fmt version")
set(HFT_GTEST_VERSION "1.17.0" CACHE STRING "Pinned GoogleTest version")
set(HFT_CIB_REVISION
    "a0d79ca83ec31270ce59d4c485969e552be4dbda"
    CACHE STRING "Pinned compile-time-init-build revision")

FetchContent_Declare(
  fmt
  URL "https://github.com/fmtlib/fmt/archive/refs/tags/${HFT_FMT_VERSION}.tar.gz"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  EXCLUDE_FROM_ALL)
FetchContent_MakeAvailable(fmt)

if(HFT_ENABLE_BOOST)
  set(BOOST_INCLUDE_LIBRARIES mp11 static_string circular_buffer lockfree)
  set(BOOST_ENABLE_CMAKE ON)
  FetchContent_Declare(
    Boost
    URL
      "https://github.com/boostorg/boost/releases/download/boost-${HFT_BOOST_VERSION}/boost-${HFT_BOOST_VERSION}-cmake.tar.xz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    EXCLUDE_FROM_ALL)
  FetchContent_MakeAvailable(Boost)
endif()

if(HFT_ENABLE_CIB)
  FetchContent_Declare(
    cib
    GIT_REPOSITORY https://github.com/intel/compile-time-init-build.git
    GIT_TAG "${HFT_CIB_REVISION}"
    GIT_SHALLOW FALSE
    EXCLUDE_FROM_ALL)
  FetchContent_MakeAvailable(cib)
endif()

if(HFT_BUILD_TESTS)
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  FetchContent_Declare(
    googletest
    URL
      "https://github.com/google/googletest/archive/refs/tags/v${HFT_GTEST_VERSION}.tar.gz"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    EXCLUDE_FROM_ALL)
  FetchContent_MakeAvailable(googletest)
endif()
