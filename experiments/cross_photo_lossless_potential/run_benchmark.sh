#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d /private/tmp/pw-cross-photo-benchmark-build-XXXXXX)
trap 'find "$build_dir" -depth -delete' EXIT HUP INT TERM

tool_path="$build_dir/jpeg_coeff_tool"
clang++ \
  -std=c++17 \
  -O3 \
  -Wall \
  -Wextra \
  -Werror \
  $(pkg-config --cflags libjpeg) \
  "$script_dir/jpeg_coeff_tool.cpp" \
  $(pkg-config --libs libjpeg) \
  -o "$tool_path"

uv run --frozen python "$script_dir/run_benchmark.py" \
  --jpeg-coeff-tool "$tool_path"
