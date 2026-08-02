#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alp_source=${PW_ALP_SOURCE:-/private/tmp/pw_worldpack_upstreams.8vBT0j/alp}
build_dir=$(mktemp -d /private/tmp/pw-worldpack-alp-build.XXXXXX)
run_dir=$(mktemp -d /private/tmp/pw-worldpack-alp-run.XXXXXX)
adapter_bin_dir=${PW_ALP_ADAPTER_BIN_DIR:-/private/tmp/pw_worldpack_alp_adapter_bin.31ca0ed}
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  find "$run_dir" -mindepth 1 -delete
  rmdir "$build_dir" "$run_dir"
}
trap cleanup EXIT HUP INT TERM

test "$(git -C "$alp_source" rev-parse HEAD)" = "31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce"
test -z "$(git -C "$alp_source" status --porcelain)"
mkdir -p "$adapter_bin_dir"

common_flags="-std=c++17 -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -Wno-unused-parameter"
for source in \
  "$alp_source/src/fastlanes_generated_unffor.cpp" \
  "$alp_source/src/fastlanes_generated_ffor.cpp" \
  "$alp_source/src/fastlanes_ffor.cpp" \
  "$alp_source/src/fastlanes_unffor.cpp"; do
  object="$build_dir/$(basename "$source" .cpp).o"
  xcrun clang++ $common_flags -I"$alp_source/include" -c "$source" -o "$object"
done
xcrun clang++ $common_flags -I"$alp_source/include" -I"$repo_root/tool" \
  -c "$repo_root/tool/worldpack_alp_adapter.cpp" -o "$build_dir/adapter.o"
xcrun clang++ $common_flags -I"$repo_root/tool" \
  -c "$repo_root/tool/worldpack_alp_adapter_test.cpp" -o "$build_dir/test.o"
xcrun clang++ $common_flags -I"$repo_root/tool" \
  -c "$repo_root/tool/worldpack_alp_adapter_main.cpp" -o "$build_dir/main.o"

xcrun clang++ "$build_dir/adapter.o" "$build_dir/test.o" \
  "$build_dir/fastlanes_generated_unffor.o" \
  "$build_dir/fastlanes_generated_ffor.o" \
  "$build_dir/fastlanes_ffor.o" "$build_dir/fastlanes_unffor.o" \
  -o "$build_dir/worldpack_alp_adapter_test"
xcrun clang++ "$build_dir/adapter.o" "$build_dir/main.o" \
  "$build_dir/fastlanes_generated_unffor.o" \
  "$build_dir/fastlanes_generated_ffor.o" \
  "$build_dir/fastlanes_ffor.o" "$build_dir/fastlanes_unffor.o" \
  -o "$adapter_bin_dir/worldpack_alp_adapter"

"$build_dir/worldpack_alp_adapter_test" "$run_dir"
echo "$adapter_bin_dir/worldpack_alp_adapter"
