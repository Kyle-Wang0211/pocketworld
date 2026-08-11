#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${PW_OFFICIAL_CODEC_SOURCE_ROOT:?set PW_OFFICIAL_CODEC_SOURCE_ROOT to the pinned source checkout root}"
source_root="$PW_OFFICIAL_CODEC_SOURCE_ROOT"
blosc_build="${PW_BLOSC2_BUILD_DIR:-$source_root/c-blosc2-build}"
openzl_build="${PW_OPENZL_BUILD_DIR:-$source_root/openzl-build-default}"
build_dir="$(mktemp -d /private/tmp/pw-codec-test-build.XXXXXX)"
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  rmdir "$build_dir"
}
trap cleanup EXIT HUP INT TERM

xcrun clang++ \
  -std=c++17 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$repo_root/tool" \
  -I"$source_root/pcodec/pco_c/include" \
  -I"$source_root/c-blosc2/include" \
  -I"$source_root/openzl/include" \
  -I"$openzl_build/include" \
  "$repo_root/tool/pwa2_official_codec_backend_test.cpp" \
  "$repo_root/tool/pwa2_official_codec_backend.cpp" \
  "$source_root/pcodec/target/release/libcpcodec.dylib" \
  "$blosc_build/blosc/libblosc2.a" \
  "$openzl_build/libopenzl.a" \
  "$openzl_build/zstd_build/lib/libzstd.a" \
  "$openzl_build/lz4_build/liblz4.a" \
  "$blosc_build/_deps/zfp-build/lib/libzfp.a" \
  -lm \
  -o "$build_dir/pwa2_official_codec_backend_test"

"$build_dir/pwa2_official_codec_backend_test"
