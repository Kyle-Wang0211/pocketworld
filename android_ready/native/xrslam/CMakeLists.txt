cmake_minimum_required(VERSION 3.22)
project(pw_xrslam_generic_transport LANGUAGES C CXX)

# This target packages a receipt-bound core produced by build_generic_core.sh.
# These values configure the shared transport; the imported core's own build
# identity is proved by core_build_receipt.json plus its exact artifact hash.
set(XRSLAM_IOS OFF CACHE BOOL "Generic core excludes iOS algorithm branches")
set(XRSLAM_ENABLE_THREADING OFF CACHE BOOL "Official generic baseline")
set(PW_XRSLAM_CORE
  "${CMAKE_CURRENT_LIST_DIR}/libs/${ANDROID_ABI}/libxrslam_generic_4beb1a9.so")
set(PW_XRSLAM_CORE_SHA256
  "083220bb6ecbaa161c0f0bae9bf007da5c59ed010455cf6f2e3b600bb0eaf8f4")
file(SHA256 "${PW_XRSLAM_CORE}" PW_XRSLAM_CORE_ACTUAL_SHA256)
if(NOT PW_XRSLAM_CORE_ACTUAL_SHA256 STREQUAL PW_XRSLAM_CORE_SHA256)
  message(FATAL_ERROR "XRSLAM Android core hash does not match build receipt")
endif()
add_library(xrslam_generic SHARED IMPORTED GLOBAL)
set_target_properties(xrslam_generic PROPERTIES
  IMPORTED_LOCATION "${PW_XRSLAM_CORE}"
)

add_library(pw_xrslam_transport SHARED
  PwXrslamTransport.cpp
  "${CMAKE_CURRENT_LIST_DIR}/../../../vendor/xrslam/transport/PwXrslamTransportCore.cpp"
)
target_compile_features(pw_xrslam_transport PRIVATE cxx_std_17)
target_compile_options(pw_xrslam_transport PRIVATE
  -ffp-contract=off
  -fno-fast-math
  -fchar8_t
)
target_include_directories(pw_xrslam_transport PRIVATE
  "${CMAKE_CURRENT_LIST_DIR}/../../../vendor/xrslam/include"
  "${CMAKE_CURRENT_LIST_DIR}/../../../vendor/xrslam/transport"
)
target_link_libraries(pw_xrslam_transport PRIVATE xrslam_generic)
target_link_options(pw_xrslam_transport PRIVATE
  "LINKER:-z,max-page-size=16384"
  "LINKER:-z,common-page-size=16384"
)
