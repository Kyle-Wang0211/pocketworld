#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d /private/tmp/pw-descriptor-similarity-test.XXXXXX)
cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT HUP INT TERM

faiss_prefix=/opt/homebrew/opt/faiss
if [ ! -f "$faiss_prefix/lib/libfaiss.dylib" ]; then
  echo "pinned local Faiss library is unavailable" >&2
  exit 2
fi

xcrun clang++ \
  -std=c++17 \
  -O2 \
  -I"$repo_root/tool" \
  -I"$faiss_prefix/include" \
  "$repo_root/tool/descriptor_similarity_forest_test.cpp" \
  "$repo_root/tool/descriptor_similarity_forest.cpp" \
  -L"$faiss_prefix/lib" \
  -Wl,-rpath,"$faiss_prefix/lib" \
  -lfaiss \
  -o "$build_dir/descriptor_similarity_forest_test"

OMP_NUM_THREADS=1 "$build_dir/descriptor_similarity_forest_test"
