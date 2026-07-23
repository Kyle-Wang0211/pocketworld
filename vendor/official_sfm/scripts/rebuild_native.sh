#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEV_ROOT=$(CDPATH= cd -- "$ROOT/../.." && pwd)
AETHER_ROOT=${AETHER_ROOT:-"$DEV_ROOT/../Aether3D-cross"}

"$AETHER_ROOT/aether_cpp/official_pipeline/build_ios_core.sh"
cp "$AETHER_ROOT/aether_cpp/official_pipeline/build-ios-device/libpwofficial_core.a" \
  "$ROOT/libs/ios-arm64/libpwofficial_core.a"

"$ROOT/scripts/generate_official_header.py"
"$ROOT/scripts/verify_abi_signatures.py"
"$ROOT/scripts/build_xcframework.sh"
"$ROOT/scripts/verify_boundary.sh"
"$ROOT/scripts/verify_source_parity.py"
