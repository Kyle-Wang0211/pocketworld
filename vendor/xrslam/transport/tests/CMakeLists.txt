cmake_minimum_required(VERSION 3.16)
project(pw_xrslam_transport_tests LANGUAGES CXX)

enable_testing()

add_executable(pw_xrslam_transport_core_test
  fake_xrslam.cpp
  transport_core_test.cpp
  ../PwXrslamTransportCore.cpp
)
target_compile_features(pw_xrslam_transport_core_test PRIVATE cxx_std_17)
target_include_directories(pw_xrslam_transport_core_test PRIVATE
  ..
  ../../include
)
target_compile_options(pw_xrslam_transport_core_test PRIVATE
  -Wall
  -Wextra
  -Werror
  -ffp-contract=off
  -fno-fast-math
)

add_test(NAME pw_xrslam_transport_core_test
  COMMAND pw_xrslam_transport_core_test)
