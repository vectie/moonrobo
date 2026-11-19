cmake_minimum_required(VERSION 3.24)
project(moonrobo_apic_authoring LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# This library is loaded ONLY by the offline authoring command. The deployed
# replay adapter has no dependency on it or on CPython.
find_package(Python3 3.12 EXACT REQUIRED COMPONENTS Development.Embed)
add_library(moonrobo_apic_authoring SHARED python_objects.cpp)
target_link_libraries(moonrobo_apic_authoring PRIVATE Python3::Python)
set_target_properties(moonrobo_apic_authoring PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
