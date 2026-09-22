# pw_af 的 C++ 单测。
#
# 照 vendor/xrslam/transport/tests/CMakeLists.txt 的现成做法:没有引入任何测试
# 框架(gtest/catch 都没有),用 assert 式的 CHECK 宏 + 失败即 std::exit(1),
# 由 ctest 收结果。保持与既有先例一致,不给工程多引一个依赖。
#
# 跑法:
#   cmake -S vendor/pw_af/tests -B <build-dir> -DCMAKE_BUILD_TYPE=Release
#   cmake --build <build-dir>
#   ctest --test-dir <build-dir> --output-on-failure
#
# 耗时用例(focus_measure_test 的最后一段)要在 Release / -O2 下跑才有意义;
# Debug 下的数字不代表上机表现。

cmake_minimum_required(VERSION 3.16)
project(pw_af_tests LANGUAGES CXX)

enable_testing()

set(PW_AF_WARNINGS
  -Wall
  -Wextra
  -Werror
  -ffp-contract=off
  -fno-fast-math
)

add_executable(pw_af_scan_test
  af_scan_test.cpp
  ../af_scan.cpp
)
target_compile_features(pw_af_scan_test PRIVATE cxx_std_17)
target_include_directories(pw_af_scan_test PRIVATE ..)
target_compile_options(pw_af_scan_test PRIVATE ${PW_AF_WARNINGS})
add_test(NAME pw_af_scan_test COMMAND pw_af_scan_test)

add_executable(pw_af_focus_measure_test
  focus_measure_test.cpp
  ../focus_measure.cpp
)
target_compile_features(pw_af_focus_measure_test PRIVATE cxx_std_17)
target_include_directories(pw_af_focus_measure_test PRIVATE ..)
target_compile_options(pw_af_focus_measure_test PRIVATE ${PW_AF_WARNINGS})
add_test(NAME pw_af_focus_measure_test COMMAND pw_af_focus_measure_test)

add_executable(pw_af_lens_scale_test
  lens_scale_test.cpp
  ../lens_scale.cpp
)
target_compile_features(pw_af_lens_scale_test PRIVATE cxx_std_17)
target_include_directories(pw_af_lens_scale_test PRIVATE ..)
target_compile_options(pw_af_lens_scale_test PRIVATE ${PW_AF_WARNINGS})
add_test(NAME pw_af_lens_scale_test COMMAND pw_af_lens_scale_test)
