#!/usr/bin/env bash
# [ENTRY-ANY-4X3 2026-09-25] 入口尺寸判据单测(纯 C,严格旗标)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/pwofficial-photo-size-rule.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror \
  "$ROOT/tests/pwofficial_photo_size_rule_test.c" -o "$BUILD_DIR/rule_c"
"$BUILD_DIR/rule_c"
# 同一头文件按 C++ 严格旗标再编一遍(载体 .mm 就是 C++ 语境)。
cp "$ROOT/tests/pwofficial_photo_size_rule_test.c" "$BUILD_DIR/rule_cxx.cc"
sed -i '' "s#\"../src/pwofficial_photo_size_rule.h\"#\"$ROOT/src/pwofficial_photo_size_rule.h\"#" "$BUILD_DIR/rule_cxx.cc"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -fno-exceptions -fno-rtti \
  "$BUILD_DIR/rule_cxx.cc" -o "$BUILD_DIR/rule_cxx"
"$BUILD_DIR/rule_cxx"
