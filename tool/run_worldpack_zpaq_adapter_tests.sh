#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d /private/tmp/pw-worldpack-zpaq-build.XXXXXX)
run_dir=$(mktemp -d /private/tmp/pw-worldpack-zpaq-run.XXXXXX)
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  find "$run_dir" -mindepth 1 -delete
  rmdir "$build_dir" "$run_dir"
}
trap cleanup EXIT HUP INT TERM

common_flags="-std=c++17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-null-pointer-subtraction -Dunix -DNOJIT"
xcrun clang++ $common_flags \
  -I"$repo_root/tool" \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  -c "$repo_root/tool/worldpack_zpaq_adapter.cpp" \
  -o "$build_dir/adapter.o"
xcrun clang++ $common_flags \
  -I"$repo_root/tool" \
  -c "$repo_root/tool/worldpack_zpaq_adapter_test.cpp" \
  -o "$build_dir/test.o"
xcrun clang++ $common_flags \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  -c "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -o "$build_dir/libzpaq.o"
xcrun clang++ \
  "$build_dir/adapter.o" \
  "$build_dir/test.o" \
  "$build_dir/libzpaq.o" \
  -framework Security \
  -o "$build_dir/worldpack_zpaq_adapter_test"

"$build_dir/worldpack_zpaq_adapter_test" "$run_dir"
