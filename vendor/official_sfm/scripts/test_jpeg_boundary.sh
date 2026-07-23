#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/pwofficial-jpeg-boundary.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcrun clang++ \
  -std=c++17 \
  "$ROOT/tests/pwofficial_jpeg_decode_test.mm" \
  "$ROOT/src/pwofficial_jpeg_decode.mm" \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework ImageIO \
  -o "$BUILD_DIR/pwofficial_jpeg_decode_test"

"$BUILD_DIR/pwofficial_jpeg_decode_test"
