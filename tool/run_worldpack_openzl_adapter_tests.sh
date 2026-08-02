#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
openzl_source=${PW_OPENZL_SOURCE:-/private/tmp/pw_worldpack_upstreams.8vBT0j/openzl}
openzl_build=${PW_OPENZL_BUILD:-/private/tmp/pw_worldpack_openzl_build_make.v020}
adapter_bin_dir=${PW_OPENZL_ADAPTER_BIN_DIR:-/private/tmp/pw_worldpack_openzl_adapter_bin.v020}
expected_revision=3dceb64867840201fb8f57a29d179995f700c9b8

test "$(git -C "$openzl_source" rev-parse HEAD)" = "$expected_revision"
test -z "$(git -C "$openzl_source" status --porcelain)"

if test ! -f "$openzl_build/Makefile"; then
  cmake -S "$openzl_source" -B "$openzl_build" -G "Unix Makefiles" \
    -DOPENZL_BUILD_MODE=opt \
    -DOPENZL_BUILD_TESTS=OFF \
    -DOPENZL_BUILD_BENCHMARKS=OFF \
    -DOPENZL_BUILD_PARQUET_TOOLS=OFF \
    -DOPENZL_BUILD_PYTHON_EXT=OFF \
    -DOPENZL_BUILD_PYTHON_DEMO=OFF \
    -DOPENZL_BUILD_CLI=OFF \
    -DOPENZL_BUILD_EXAMPLES=ON \
    -DOPENZL_BUILD_LOGGER=ON \
    -DOPENZL_INSTALL=OFF
fi
cmake --build "$openzl_build" --target training -j 8

compile_dir=$(mktemp -d /private/tmp/pw-worldpack-openzl-compile.XXXXXX)
run_dir=$(mktemp -d /private/tmp/pw-worldpack-openzl-test.XXXXXX)
cleanup() {
  find "$compile_dir" -mindepth 1 -delete
  find "$run_dir" -mindepth 1 -delete
  rmdir "$compile_dir" "$run_dir"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$adapter_bin_dir"

common_flags="-std=gnu++17 -O3 -DNDEBUG -DDMLC_LOG_STACK_TRACE=0 -arch arm64"
includes="-I$repo_root/tool -I$openzl_source -I$openzl_build/include -I$openzl_source/include -I$openzl_source/src -I$openzl_source/deps/lz4/lib -I$openzl_source/deps/zstd/lib -I$openzl_build/cpp/include -I$openzl_source/cpp/include -I$openzl_build/tools/ml_selector/xgboost-install/include"

/usr/bin/c++ $common_flags $includes \
  -c "$repo_root/tool/worldpack_openzl_adapter.cpp" \
  -o "$compile_dir/adapter.o"
/usr/bin/c++ $common_flags -I"$repo_root/tool" \
  -c "$repo_root/tool/worldpack_openzl_adapter_test.cpp" \
  -o "$compile_dir/test.o"
/usr/bin/c++ $common_flags -I"$repo_root/tool" \
  -c "$repo_root/tool/worldpack_openzl_adapter_main.cpp" \
  -o "$compile_dir/main.o"

link_openzl() {
  output=$1
  shift
  /usr/bin/c++ $common_flags "$@" \
    "$openzl_build/libopenzl.a" \
    "$openzl_build/cpp/libopenzl_cpp.a" \
    "$openzl_build/tools/fileio/libfileio.a" \
    "$openzl_build/tools/io/libtools_io.a" \
    "$openzl_build/tools/training/libtools_training.a" \
    "$openzl_build/custom_parsers/shared_components/libshared_components.a" \
    "$openzl_build/tools/io/libtools_io.a" \
    "$openzl_build/tools/logger/liblogger.a" \
    "$openzl_build/tools/ml_selector/libml_selector.a" \
    "$openzl_build/tools/ml_selector/xgboost-install/lib/libxgboost.a" \
    "$openzl_build/tools/ml_selector/xgboost-install/lib/libdmlc.a" \
    "$openzl_build/cpp/libopenzl_cpp.a" \
    "$openzl_build/libopenzl.a" \
    "$openzl_build/zstd_build/lib/libzstd.a" \
    "$openzl_build/lz4_build/liblz4.a" \
    -lm \
    -o "$output"
}

link_openzl "$compile_dir/worldpack_openzl_adapter_test" \
  "$compile_dir/adapter.o" "$compile_dir/test.o"
link_openzl "$adapter_bin_dir/worldpack_openzl_adapter" \
  "$compile_dir/adapter.o" "$compile_dir/main.o"

"$compile_dir/worldpack_openzl_adapter_test" "$run_dir"
echo "PW_WORLDPACK_OPENZL_ADAPTER_TESTS_OK"
echo "$adapter_bin_dir/worldpack_openzl_adapter"
