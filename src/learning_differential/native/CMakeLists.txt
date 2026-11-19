cmake_minimum_required(VERSION 3.20)
project(moonrobo_independent_learning_oracle LANGUAGES CXX)

# Explicit, standalone differential-test plugin. Nothing in the default MoonBit
# production build invokes CMake, links LibTorch or builds/loads this library.
# The fixture runner must be given the completed library path explicitly.
find_package(Torch REQUIRED)
find_package(Threads REQUIRED)

add_library(moonrobo_diff_oracle SHARED
  adapter.cpp
  learning_oracle.cpp
  mathematical_oracle.cpp
)
target_compile_features(moonrobo_diff_oracle PRIVATE cxx_std_17)
target_include_directories(moonrobo_diff_oracle PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  ${TORCH_INCLUDE_DIRS}
)
separate_arguments(MOONROBO_TORCH_COMPILE_FLAGS NATIVE_COMMAND "${TORCH_CXX_FLAGS}")
target_compile_options(moonrobo_diff_oracle PRIVATE ${MOONROBO_TORCH_COMPILE_FLAGS})
target_link_libraries(moonrobo_diff_oracle PRIVATE ${TORCH_LIBRARIES} Threads::Threads)
set_target_properties(moonrobo_diff_oracle PROPERTIES
  OUTPUT_NAME moonrobo_diff_oracle
  POSITION_INDEPENDENT_CODE ON
)

# No executable, CTest registration, fixture producer or forward call is part
# of configuration/build. This change was validated with clang++ -fsyntax-only
# against the installed Torch headers; the shared library was not built or run.
