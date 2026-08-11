#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d /private/tmp/pw-descriptor-chunk-archive-test.XXXXXX)
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  rmdir "$build_dir"
}
trap cleanup EXIT HUP INT TERM

xcrun clang++ \
  -std=c++17 \
  -O2 \
  -I"$repo_root/tool" \
  "$repo_root/tool/descriptor_chunk_archive_test.cpp" \
  "$repo_root/tool/descriptor_chunk_archive.cpp" \
  -framework Security \
  -o "$build_dir/descriptor_chunk_archive_test"

"$build_dir/descriptor_chunk_archive_test"
