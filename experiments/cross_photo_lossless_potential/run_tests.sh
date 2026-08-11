#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d /private/tmp/pw-cross-photo-tests-XXXXXX)
trap 'find "$build_dir" -depth -delete' EXIT HUP INT TERM

tool_path="$build_dir/jpeg_coeff_tool"
if test -f "$script_dir/jpeg_coeff_tool.cpp"; then
  clang++ \
    -std=c++17 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    $(pkg-config --cflags libjpeg) \
    "$script_dir/jpeg_coeff_tool.cpp" \
    $(pkg-config --libs libjpeg) \
    -o "$tool_path"
fi

PW_JPEG_COEFF_TOOL="$tool_path" \
  uv run --frozen python -m unittest discover -s "$script_dir/tests" -v
