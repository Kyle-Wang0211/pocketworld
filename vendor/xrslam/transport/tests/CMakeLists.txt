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

# The fixture pins PWXrslamTransportScaleIntrinsicsForBoxNxN to the offline
# converter's output (regenerate with make_rescale_fixture.py).
add_test(NAME pw_xrslam_transport_core_test
  COMMAND pw_xrslam_transport_core_test
    ${CMAKE_CURRENT_SOURCE_DIR}/fixtures/pwvi_to_euroc_rescale_6e2d4b99_d3.csv)

# Optional: the fork engine's own per-frame-K consumption rule
# (xrslam-interface/src/XRSLAMImageExt.h at fork commit 04c0e83) against the
# struct this transport pushes. -DPW_XRSLAM_FORK_SRC=<fork tree>.
set(PW_XRSLAM_FORK_SRC "" CACHE PATH "XRSLAM fork source tree (optional)")
if(PW_XRSLAM_FORK_SRC)
  if(NOT EXISTS "${PW_XRSLAM_FORK_SRC}/xrslam-interface/src/XRSLAMImageExt.h")
    message(FATAL_ERROR "PW_XRSLAM_FORK_SRC has no xrslam-interface/src/XRSLAMImageExt.h")
  endif()
  add_executable(pw_xrslam_fork_contract_test
    fork_contract_test.cpp
    ../PwXrslamTransportCore.cpp
  )
  target_compile_features(pw_xrslam_fork_contract_test PRIVATE cxx_std_17)
  # Mirror header first, so the fork header's `#include <XRSLAM.h>` resolves to
  # vendor/xrslam/include/XRSLAM.h and its static_asserts check the mirror.
  target_include_directories(pw_xrslam_fork_contract_test PRIVATE
    ..
    ../../include
    "${PW_XRSLAM_FORK_SRC}/xrslam-interface/src"
  )
  target_compile_options(pw_xrslam_fork_contract_test PRIVATE
    -Wall -Wextra -Werror -ffp-contract=off -fno-fast-math)
  add_test(NAME pw_xrslam_fork_contract_test COMMAND pw_xrslam_fork_contract_test)
endif()
