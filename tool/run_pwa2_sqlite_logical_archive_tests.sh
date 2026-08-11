#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/pw_pwa2_logical_tests.XXXXXX)"
trap 'find "$build_dir" -mindepth 1 -delete; rmdir "$build_dir"' EXIT

clang++ \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$repo_root/tool" \
  "$repo_root/tool/pwa2_sqlite_logical_archive_test.cpp" \
  "$repo_root/tool/pwa2_sqlite_logical_archive.cpp" \
  -lsqlite3 \
  -o "$build_dir/pwa2_sqlite_logical_archive_test"

"$build_dir/pwa2_sqlite_logical_archive_test"
