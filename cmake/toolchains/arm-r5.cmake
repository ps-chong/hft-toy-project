set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR cortex-r5)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

if(NOT DEFINED ENV{ARM_GNU_TOOLCHAIN_ROOT})
  message(FATAL_ERROR "ARM_GNU_TOOLCHAIN_ROOT must point to Arm GNU 13.3.Rel1")
endif()

file(TO_CMAKE_PATH "$ENV{ARM_GNU_TOOLCHAIN_ROOT}" ARM_GNU_TOOLCHAIN_ROOT)
set(TOOLCHAIN_BIN "${ARM_GNU_TOOLCHAIN_ROOT}/bin")

set(CMAKE_C_COMPILER "${TOOLCHAIN_BIN}/arm-none-eabi-gcc")
set(CMAKE_CXX_COMPILER "${TOOLCHAIN_BIN}/arm-none-eabi-g++")
set(CMAKE_ASM_COMPILER "${TOOLCHAIN_BIN}/arm-none-eabi-gcc")
set(CMAKE_AR "${TOOLCHAIN_BIN}/arm-none-eabi-ar")
set(CMAKE_OBJCOPY "${TOOLCHAIN_BIN}/arm-none-eabi-objcopy")
set(CMAKE_SIZE "${TOOLCHAIN_BIN}/arm-none-eabi-size")

set(HFT_R5_CPU_FLAGS
    "-mcpu=cortex-r5 -mthumb -mfpu=vfpv3-d16 -mfloat-abi=hard")
set(CMAKE_C_FLAGS_INIT
    "${HFT_R5_CPU_FLAGS} -ffunction-sections -fdata-sections")
set(CMAKE_CXX_FLAGS_INIT
    "${HFT_R5_CPU_FLAGS} -ffunction-sections -fdata-sections -fno-exceptions -fno-rtti -fno-threadsafe-statics")
set(CMAKE_EXE_LINKER_FLAGS_INIT
    "${HFT_R5_CPU_FLAGS} -Wl,--gc-sections -Wl,--print-memory-usage")

set(CMAKE_FIND_ROOT_PATH "${ARM_GNU_TOOLCHAIN_ROOT}/arm-none-eabi")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
