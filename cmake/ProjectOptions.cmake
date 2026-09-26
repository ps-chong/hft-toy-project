add_library(hft_project_options INTERFACE)
add_library(hft::project_options ALIAS hft_project_options)

target_compile_features(hft_project_options INTERFACE cxx_std_23)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(
    hft_project_options
    INTERFACE
      -Wall
      -Wextra
      -Wpedantic
      -Wconversion
      -Wsign-conversion
      -Wshadow
      -Wcast-align
      -Wformat=2
      -Wundef
      -Wdouble-promotion
      -Wnull-dereference)

  if(HFT_WARNINGS_AS_ERRORS)
    target_compile_options(hft_project_options INTERFACE -Werror)
  endif()

  if(HFT_ENABLE_COVERAGE AND NOT CMAKE_CROSSCOMPILING)
    target_compile_options(hft_project_options INTERFACE --coverage -O0 -g)
    target_link_options(hft_project_options INTERFACE --coverage)
  endif()
endif()

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND NOT CMAKE_CROSSCOMPILING)
  option(HFT_ENABLE_SANITIZERS "Enable Address/Undefined sanitizers" OFF)
  if(HFT_ENABLE_SANITIZERS)
    target_compile_options(
      hft_project_options INTERFACE -fsanitize=address,undefined
                                    -fno-omit-frame-pointer)
    target_link_options(hft_project_options INTERFACE
                        -fsanitize=address,undefined)
  endif()
endif()
