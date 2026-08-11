#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d /private/tmp/pw-sqlite-descriptor-test.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun clang++ \
  -std=c++17 \
  -DPW_SQLITE_EXACT_TRANSFORM_V2_BENCH=1 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$repo_root/ios/Runner" \
  "$repo_root/ios/RunnerTests/PWSqliteDescriptorTransformSmoke.cpp" \
  "$repo_root/ios/Runner/pw_sqlite_descriptor_transform.cpp" \
  -lsqlite3 \
  -o "$build_dir/pw_sqlite_descriptor_transform_tests"

"$build_dir/pw_sqlite_descriptor_transform_tests"
