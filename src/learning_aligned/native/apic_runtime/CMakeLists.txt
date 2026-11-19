cmake_minimum_required(VERSION 3.24)
project(moonrobo_apic_runtime LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CUDA_DRIVER_INCLUDE_DIR "" CACHE PATH "Real pinned CUDA 13.0 include directory")
set(WARP_NATIVE_INCLUDE_DIR "" CACHE PATH "Real pinned Warp 1.17 native include directory")
set(WARP_NATIVE_LIBRARY "" CACHE FILEPATH "Exact installed Warp 1.17 warp.so")
if(NOT EXISTS "${CUDA_DRIVER_INCLUDE_DIR}/cuda.h" OR
   NOT EXISTS "${WARP_NATIVE_INCLUDE_DIR}/apic.h" OR
   NOT EXISTS "${WARP_NATIVE_INCLUDE_DIR}/apic_types.h" OR
   NOT EXISTS "${WARP_NATIVE_INCLUDE_DIR}/version.h" OR
   NOT EXISTS "${WARP_NATIVE_LIBRARY}")
  message(FATAL_ERROR "Real CUDA/Warp headers and Warp native library are required; no substitutes or downloads")
endif()
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "This standalone replay build targets Linux and its injected libcuda.so.1")
endif()
file(READ "${WARP_NATIVE_INCLUDE_DIR}/version.h" WARP_VERSION_HEADER)
if(NOT WARP_VERSION_HEADER MATCHES "#define WP_VERSION_STRING \"1\\.17\\.0\"")
  message(FATAL_ERROR "Warp header version must be exactly 1.17.0")
endif()
file(SHA256 "${CUDA_DRIVER_INCLUDE_DIR}/cuda.h" CUDA_HEADER_SHA)
if(NOT CUDA_HEADER_SHA STREQUAL "64025f81a9d6d2b10e9e11654f3523e5b046d01b883f0b9ca474e463274b80d4")
  message(FATAL_ERROR "cuda.h differs from the locked NVIDIA nvidia-cuda-runtime 13.0.96 aarch64 wheel")
endif()
file(SHA256 "${WARP_NATIVE_INCLUDE_DIR}/apic.h" WARP_HEADER_SHA)
file(SHA256 "${WARP_NATIVE_INCLUDE_DIR}/apic_types.h" WARP_TYPES_SHA)
file(SHA256 "${WARP_NATIVE_LIBRARY}" WARP_LIBRARY_SHA)
file(WRITE "${CMAKE_BINARY_DIR}/dependencies.sha256"
  "${CUDA_HEADER_SHA}  ${CUDA_DRIVER_INCLUDE_DIR}/cuda.h\n${WARP_HEADER_SHA}  ${WARP_NATIVE_INCLUDE_DIR}/apic.h\n${WARP_TYPES_SHA}  ${WARP_NATIVE_INCLUDE_DIR}/apic_types.h\n${WARP_LIBRARY_SHA}  ${WARP_NATIVE_LIBRARY}\n")
get_filename_component(WARP_LIBRARY_DIR "${WARP_NATIVE_LIBRARY}" DIRECTORY)
get_filename_component(WARP_LIBRARY_FILENAME "${WARP_NATIVE_LIBRARY}" NAME)
add_library(moonrobo_aligned_apic SHARED ../aot_solver.cpp)
target_compile_definitions(moonrobo_aligned_apic PRIVATE MOONROBO_APIC_DYNAMIC_CUDA=1)
target_include_directories(moonrobo_aligned_apic PRIVATE "${CUDA_DRIVER_INCLUDE_DIR}" "${WARP_NATIVE_INCLUDE_DIR}")
# The genuine wheel binary is named warp.so and has no SONAME. CMake's usual
# shared-library conversion can turn its full path into -lwarp, which wrongly
# searches for libwarp.so. GNU ld's exact-file form preserves the actual name;
# the recorded RUNPATH resolves the same pinned binary at runtime.
target_link_directories(moonrobo_aligned_apic PRIVATE "${WARP_LIBRARY_DIR}")
target_link_libraries(moonrobo_aligned_apic PRIVATE "-Wl,-l:${WARP_LIBRARY_FILENAME}" ${CMAKE_DL_LIBS})
target_link_options(moonrobo_aligned_apic PRIVATE -Wl,-z,defs)
set_target_properties(moonrobo_aligned_apic PROPERTIES
  BUILD_RPATH "${WARP_LIBRARY_DIR}" INSTALL_RPATH "${WARP_LIBRARY_DIR}"
  CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
