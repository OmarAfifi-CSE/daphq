cmake_minimum_required(VERSION 3.14)
project(daphq_direct_win LANGUAGES CXX)

add_library(daphq_direct_win STATIC
  "daphq_direct_win.h"
  "daphq_direct_win.cpp"
)

# Deliberately avoid Flutter's apply_standard_settings() here because runner enforces
# _HAS_EXCEPTIONS=0, whereas C++/WinRT requires full standard exception handling (/EHsc).
target_compile_features(daphq_direct_win PUBLIC cxx_std_17)
target_compile_options(daphq_direct_win PRIVATE /EHsc /bigobj /W3)
target_compile_definitions(daphq_direct_win PRIVATE
  "WIN32_LEAN_AND_MEAN"
  "NOMINMAX"
  "UNICODE"
  "_UNICODE"
)

target_include_directories(daphq_direct_win PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

target_link_libraries(daphq_direct_win PRIVATE
  "windowsapp.lib"
  "wlanapi.lib"
  "iphlpapi.lib"
  "ws2_32.lib"
  "ole32.lib"
  "bcrypt.lib"
)
