#!/usr/bin/env bash
# pwofficial_gpu_match_dawn_host_build.sh — builds the host gate binaries for
# the production Dawn matcher TU into $1:
#   fair_match_portable_arm   = pwofficial_gpu_match_dawn_host_arm (drives the
#                               PRODUCTION TU pwofficial_gpu_match_dawn.cc via
#                               its C ABI; same argv/output contract as the H2
#                               harness arm so fair_match_parity_suite.sh and
#                               run_fullgate.sh work unchanged)
#   fair_match_native_arm     = H2 native Metal arm linking the shipped Metal
#                               TU verbatim (reference)
#   fair_match_gen_fixture / fair_match_extract_fixture = H2 fixture tools
#   pwofficial_gpu_match_guided_compare = Metal-v1 vs Dawn guided comparator
# Records source + binary SHA-256 into $OUT/build_identity.txt.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"                       # vendor/official_sfm
AETHER="${AETHER_ROOT:-$HOME/Developer/Aether3D-cross}"
TOOLS="$AETHER/aether_cpp/experiments/portable_frontend_pareto/tools"
OUT="${1:-/private/tmp/pwofficial-dawn-host/build}"
mkdir -p "$OUT"

DAWN_INC="$AETHER/aether_cpp/third_party/dawn/include"
DAWN_GEN="$AETHER/aether_cpp/build/third_party/dawn/gen/include"
DAWN_LIB="$AETHER/aether_cpp/build/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
METAL_TU="$ROOT/src/pwofficial_gpu_match.mm"
DAWN_TU="$ROOT/src/pwofficial_gpu_match_dawn.cc"
DAWN_FRAMEWORKS="-framework CoreFoundation -framework Foundation -framework IOSurface -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal"

CXX="xcrun clang++ -O2 -std=c++17 -arch arm64"

$CXX -std=c++20 "$TOOLS/fair_match_extract_fixture.cc" -lsqlite3 \
  -o "$OUT/fair_match_extract_fixture"
$CXX -std=c++20 "$TOOLS/fair_match_gen_fixture.cc" -o "$OUT/fair_match_gen_fixture"

# Native reference arm: the shipped Metal TU, source untouched.
$CXX -std=c++20 -I"$ROOT/include" -fobjc-arc \
  "$TOOLS/fair_match_native_arm.mm" "$METAL_TU" \
  -framework Metal -framework Foundation \
  -o "$OUT/fair_match_native_arm"

# Production Dawn TU (host test build: debug hooks on, observables defined
# here because no Metal TU is linked).
$CXX -fvisibility=hidden -DPWOFFICIAL_DAWN_HOST_TEST=1 \
  -I"$DAWN_INC" -I"$DAWN_GEN" -I"$ROOT/include" \
  -c "$DAWN_TU" -o "$OUT/pwofficial_gpu_match_dawn.host.o"
$CXX -fobjc-arc -c "$ROOT/src/pwofficial_gpu_match_thermal_apple.mm" \
  -o "$OUT/pwofficial_gpu_match_thermal_apple.o"
$CXX -I"$TOOLS" "$here/pwofficial_gpu_match_dawn_host_arm.cc" \
  "$OUT/pwofficial_gpu_match_dawn.host.o" "$OUT/pwofficial_gpu_match_thermal_apple.o" \
  "$DAWN_LIB" $DAWN_FRAMEWORKS \
  -o "$OUT/fair_match_portable_arm"

# Guided comparator: Metal TU (as shipped, exports aether_gpu_match_*) +
# Dawn TU (pwdawn_*, observables extern = the iOS configuration).
$CXX -fvisibility=hidden -DPWOFFICIAL_DAWN_HOST_TEST=1 \
  -DPWOFFICIAL_DAWN_OBSERVABLES_EXTERN=1 \
  -I"$DAWN_INC" -I"$DAWN_GEN" -I"$ROOT/include" \
  -c "$DAWN_TU" -o "$OUT/pwofficial_gpu_match_dawn.hostx.o"
$CXX -I"$TOOLS" -I"$ROOT/include" -fobjc-arc \
  "$here/pwofficial_gpu_match_guided_compare.mm" "$METAL_TU" \
  "$OUT/pwofficial_gpu_match_dawn.hostx.o" "$OUT/pwofficial_gpu_match_thermal_apple.o" \
  "$DAWN_LIB" $DAWN_FRAMEWORKS \
  -o "$OUT/pwofficial_gpu_match_guided_compare"

{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "clang: $(xcrun clang++ --version | head -1)"
  echo "== sources =="
  shasum -a 256 "$DAWN_TU" "$METAL_TU" "$ROOT/src/pwofficial_gpu_match_dispatch.cc" \
    "$ROOT/src/pwofficial_gpu_match_metal_rename.h" \
    "$here/pwofficial_gpu_match_dawn_host_arm.cc" \
    "$here/pwofficial_gpu_match_guided_compare.mm" \
    "$TOOLS/fair_match_common.h" "$TOOLS/fair_match_native_arm.mm" \
    "$TOOLS/fair_match_gen_fixture.cc" "$TOOLS/fair_match_extract_fixture.cc"
  echo "== dawn =="
  shasum -a 256 "$DAWN_LIB" | awk '{print $1"  libwebgpu_dawn.a (host)"}'
  echo "== binaries =="
  shasum -a 256 "$OUT/fair_match_extract_fixture" "$OUT/fair_match_gen_fixture" \
    "$OUT/fair_match_native_arm" "$OUT/fair_match_portable_arm" \
    "$OUT/pwofficial_gpu_match_guided_compare"
} > "$OUT/build_identity.txt"
cat "$OUT/build_identity.txt"
echo "BUILD_OK $OUT"
