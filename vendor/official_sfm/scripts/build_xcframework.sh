#!/bin/sh
set -eu

# PWOFFICIAL_P3_CANDIDATE_BUILD_V1
# PWOFFICIAL_PATH_SCOPE_V1
: "${PWOFFICIAL_TASK_ROOT:?real /private/tmp task root is required}"
: "${PWOFFICIAL_GPU_CARRIER:?absolute candidate carrier is required}"
: "${PWOFFICIAL_XCFRAMEWORK_OUT:?absolute candidate xcframework output is required}"
: "${PWOFFICIAL_DAWN_ARCHIVE:?absolute pinned Dawn archive is required}"
: "${PWOFFICIAL_DAWN_SHA256:?expected Dawn archive SHA-256 is required}"
: "${PWOFFICIAL_LINK_MAP:?absolute retained device link-map path is required}"
: "${PWOFFICIAL_CERES_ARCHIVE:?absolute Ceres archive is required}"
: "${PWOFFICIAL_CERES_SHA256:?expected Ceres archive SHA-256 is required}"
: "${PWOFFICIAL_GLOG_ARCHIVE:?absolute glog archive is required}"
: "${PWOFFICIAL_GLOG_SHA256:?expected glog archive SHA-256 is required}"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d /private/tmp/pwofficial-framework.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

python3 - \
  "$PWOFFICIAL_TASK_ROOT" \
  "$PWOFFICIAL_GPU_CARRIER" \
  "$PWOFFICIAL_XCFRAMEWORK_OUT" \
  "$PWOFFICIAL_LINK_MAP" \
  "$PWOFFICIAL_DAWN_ARCHIVE" \
  "$PWOFFICIAL_CERES_ARCHIVE" \
  "$PWOFFICIAL_GLOG_ARCHIVE" \
  "$ROOT" <<'PY'
from pathlib import Path
import sys

(
    task_text,
    carrier_text,
    output_text,
    link_map_text,
    dawn_text,
    ceres_text,
    glog_text,
    product_text,
) = sys.argv[1:]
private_tmp = Path("/private/tmp").resolve(strict=True)
product = Path(product_text).resolve(strict=True)

def canonical_existing(text: str, label: str) -> Path:
    lexical = Path(text)
    if not lexical.is_absolute():
        raise SystemExit(f"FAIL: {label} must be absolute")
    resolved = lexical.resolve(strict=True)
    if lexical != resolved:
        raise SystemExit(f"FAIL: {label} must not use traversal or symlink aliases")
    return resolved

task = canonical_existing(task_text, "task root")
if task == private_tmp or private_tmp not in task.parents:
    raise SystemExit("FAIL: task root must be a child of real /private/tmp")
if task == product or product in task.parents or task in product.parents:
    raise SystemExit("FAIL: task root must be outside the product root")

carrier = canonical_existing(carrier_text, "candidate carrier")
dawn = canonical_existing(dawn_text, "Dawn archive")
ceres = canonical_existing(ceres_text, "Ceres archive")
glog = canonical_existing(glog_text, "glog archive")
if task not in carrier.parents:
    raise SystemExit("FAIL: candidate carrier escapes the task root")

for text, label in ((output_text, "candidate output"), (link_map_text, "link map")):
    lexical = Path(text)
    if not lexical.is_absolute():
        raise SystemExit(f"FAIL: {label} must be absolute")
    parent = lexical.parent.resolve(strict=True)
    canonical = parent / lexical.name
    if lexical != canonical:
        raise SystemExit(f"FAIL: {label} must not use traversal or symlink aliases")
    if task not in canonical.parents:
        raise SystemExit(f"FAIL: {label} escapes the task root")

for dependency, label in (
    (dawn, "Dawn"),
    (ceres, "Ceres"),
    (glog, "glog"),
):
    if product == dependency or product in dependency.parents:
        raise SystemExit(f"FAIL: {label} archive unexpectedly resolves inside product")
PY

[ -f "$PWOFFICIAL_GPU_CARRIER" ] || {
  echo "FAIL: missing candidate carrier: $PWOFFICIAL_GPU_CARRIER" >&2
  exit 66
}
[ -f "$PWOFFICIAL_DAWN_ARCHIVE" ] || {
  echo "FAIL: missing pinned Dawn archive: $PWOFFICIAL_DAWN_ARCHIVE" >&2
  exit 66
}
[ ! -e "$PWOFFICIAL_XCFRAMEWORK_OUT" ] || {
  echo "FAIL: refusing existing output: $PWOFFICIAL_XCFRAMEWORK_OUT" >&2
  exit 67
}
[ ! -e "$PWOFFICIAL_LINK_MAP" ] || {
  echo "FAIL: refusing existing output link map: $PWOFFICIAL_LINK_MAP" >&2
  exit 67
}

actual_dawn_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_DAWN_ARCHIVE" | awk '{print $1}')
[ "$actual_dawn_sha" = "$PWOFFICIAL_DAWN_SHA256" ] || {
  echo "FAIL: Dawn archive SHA-256 mismatch before link" >&2
  exit 68
}
actual_ceres_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_CERES_ARCHIVE" | awk '{print $1}')
[ "$actual_ceres_sha" = "$PWOFFICIAL_CERES_SHA256" ] || {
  echo "FAIL: Ceres archive SHA-256 mismatch before link" >&2
  exit 68
}
actual_glog_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_GLOG_ARCHIVE" | awk '{print $1}')
[ "$actual_glog_sha" = "$PWOFFICIAL_GLOG_SHA256" ] || {
  echo "FAIL: glog archive SHA-256 mismatch before link" >&2
  exit 68
}

mkdir -p "$(dirname "$PWOFFICIAL_XCFRAMEWORK_OUT")" \
  "$(dirname "$PWOFFICIAL_LINK_MAP")"

# [MATCHER-DAWN 2026-09-03] Header roots for the cross-platform Dawn matcher
# TU (src/pwofficial_gpu_match_dawn.cc). Derived from the pinned Dawn archive
# path (…/build-ios-device-dawn/third_party/dawn/src/dawn/native/<cfg>/libwebgpu_dawn.a)
# so the iOS-generated headers always match the archive that is force-loaded
# below; overridable for out-of-tree layouts.
PWOFFICIAL_DAWN_GEN_INCLUDE=${PWOFFICIAL_DAWN_GEN_INCLUDE:-"$(CDPATH= cd -- "$(dirname -- "$PWOFFICIAL_DAWN_ARCHIVE")/../../../../gen/include" && pwd)"}
PWOFFICIAL_DAWN_SRC_INCLUDE=${PWOFFICIAL_DAWN_SRC_INCLUDE:-"$(CDPATH= cd -- "$(dirname -- "$PWOFFICIAL_DAWN_ARCHIVE")/../../../../../../../third_party/dawn/include" && pwd)"}
[ -f "$PWOFFICIAL_DAWN_GEN_INCLUDE/dawn/webgpu_cpp.h" ] || {
  echo "FAIL: missing iOS Dawn generated headers: $PWOFFICIAL_DAWN_GEN_INCLUDE" >&2
  exit 66
}
[ -f "$PWOFFICIAL_DAWN_SRC_INCLUDE/webgpu/webgpu_cpp.h" ] || {
  echo "FAIL: missing Dawn source headers: $PWOFFICIAL_DAWN_SRC_INCLUDE" >&2
  exit 66
}

DEVICE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CLANG=$(xcrun --find clang)
CLANGXX=$(xcrun --find clang++)
DEVICE_FRAMEWORK="$BUILD/device/PWOfficialSfm.framework"
SIM_ARM_FRAMEWORK="$BUILD/simulator-arm64/PWOfficialSfm.framework"
SIM_X86_FRAMEWORK="$BUILD/simulator-x86_64/PWOfficialSfm.framework"
SIM_FRAMEWORK="$BUILD/simulator/PWOfficialSfm.framework"
OUT=$PWOFFICIAL_XCFRAMEWORK_OUT
EXPORTS="$BUILD/exports.txt"

sed 's/^/_/' "$ROOT/pwofficial_abi_symbols.txt" > "$EXPORTS"
sed 's/^/_/' "$ROOT/pwofficial_io_abi_symbols.txt" >> "$EXPORTS"

prepare_framework() {
  framework=$1
  object_dir=$2
  mkdir -p "$framework/Headers" "$object_dir"
  cp "$ROOT/Info.plist" "$framework/Info.plist"
  cp "$ROOT/include/aether_sfm_c.h" "$framework/Headers/aether_sfm_c.h"
  cp "$ROOT/include/official_sfm_c.h" "$framework/Headers/official_sfm_c.h"
  cp "$ROOT/include/official_sfm_io_c.h" "$framework/Headers/official_sfm_io_c.h"
}

compile_common_objects() {
  sdk=$1
  target=$2
  framework=$3
  object_dir=$4
  prepare_framework "$framework" "$object_dir"
  "$CLANG" -target "$target" -isysroot "$sdk" -miphoneos-version-min=14.0 \
    -fPIC -fvisibility=hidden -O3 -I"$ROOT/include" \
    -c "$ROOT/src/pwofficial_export_shim.c" -o "$object_dir/export_shim.o"
  "$CLANGXX" -target "$target" -isysroot "$sdk" -miphoneos-version-min=14.0 \
    -fPIC -fvisibility=hidden -O3 -std=c++17 -fobjc-arc \
    -c "$ROOT/src/pwofficial_telemetry.mm" -o "$object_dir/telemetry.o"
  "$CLANGXX" -target "$target" -isysroot "$sdk" -miphoneos-version-min=14.0 \
    -fPIC -fvisibility=hidden -O3 -std=c++17 -fobjc-arc -I"$ROOT/include" \
    -c "$ROOT/src/pwofficial_jpeg_decode.mm" -o "$object_dir/jpeg_decode.o"
}

build_device_framework() {
  target=arm64-apple-ios14.0
  object_dir="$DEVICE_FRAMEWORK.objects"
  compile_common_objects "$DEVICE_SDK" "$target" "$DEVICE_FRAMEWORK" "$object_dir"
  # [MATCHER-DAWN 2026-09-03] The shipped Metal TU is compiled with its
  # exports renamed to pwmetal_* (source byte-identical; -include only), the
  # public aether_gpu_match_* ABI is owned by the dispatch TU, and the
  # cross-platform Dawn TU + Apple thermal hook join the link. Default
  # backend stays Metal (OFFICIAL_AETHER_MATCH_BACKEND unset); "dawn" flips.
  "$CLANGXX" -target "$target" -isysroot "$DEVICE_SDK" \
    -miphoneos-version-min=14.0 -fPIC -fvisibility=hidden -O3 -std=c++17 \
    -fobjc-arc -include "$ROOT/src/pwofficial_gpu_match_metal_rename.h" \
    -c "$ROOT/src/pwofficial_gpu_match.mm" \
    -o "$object_dir/gpu_match.o"
  "$CLANGXX" -target "$target" -isysroot "$DEVICE_SDK" \
    -miphoneos-version-min=14.0 -fPIC -fvisibility=hidden -O3 -std=c++17 \
    -c "$ROOT/src/pwofficial_gpu_match_dispatch.cc" \
    -o "$object_dir/gpu_match_dispatch.o"
  "$CLANGXX" -target "$target" -isysroot "$DEVICE_SDK" \
    -miphoneos-version-min=14.0 -fPIC -fvisibility=hidden -O3 -std=c++17 \
    -DPWOFFICIAL_DAWN_OBSERVABLES_EXTERN=1 \
    -I"$PWOFFICIAL_DAWN_SRC_INCLUDE" -I"$PWOFFICIAL_DAWN_GEN_INCLUDE" \
    -I"$ROOT/include" \
    -c "$ROOT/src/pwofficial_gpu_match_dawn.cc" \
    -o "$object_dir/gpu_match_dawn.o"
  "$CLANGXX" -target "$target" -isysroot "$DEVICE_SDK" \
    -miphoneos-version-min=14.0 -fPIC -fvisibility=hidden -O3 -std=c++17 \
    -fobjc-arc -c "$ROOT/src/pwofficial_gpu_match_thermal_apple.mm" \
    -o "$object_dir/gpu_match_thermal_apple.o"

  "$CLANGXX" -target "$target" -isysroot "$DEVICE_SDK" \
    -miphoneos-version-min=14.0 -dynamiclib -fPIC \
    -Wl,-dead_strip -Wl,-no_adhoc_codesign \
    -Wl,-install_name,@rpath/PWOfficialSfm.framework/PWOfficialSfm \
    -Wl,-exported_symbols_list,"$EXPORTS" \
    -Wl,-map,"$PWOFFICIAL_LINK_MAP" \
    "$object_dir/export_shim.o" "$object_dir/telemetry.o" \
    "$object_dir/jpeg_decode.o" "$object_dir/gpu_match.o" \
    "$object_dir/gpu_match_dispatch.o" "$object_dir/gpu_match_dawn.o" \
    "$object_dir/gpu_match_thermal_apple.o" \
    -Wl,-force_load,"$PWOFFICIAL_GPU_CARRIER" \
    -Wl,-force_load,"$ROOT/libs/ios-arm64/libpwofficial_core.a" \
    -Wl,-force_load,"$PWOFFICIAL_DAWN_ARCHIVE" \
    "$PWOFFICIAL_CERES_ARCHIVE" "$PWOFFICIAL_GLOG_ARCHIVE" \
    -lsqlite3 -lc++ -lz \
    -framework Foundation -framework Metal -framework CoreVideo \
    -framework IOSurface -framework QuartzCore -framework Accelerate \
    -framework CoreGraphics -framework ImageIO \
    -o "$DEVICE_FRAMEWORK/PWOfficialSfm"
}

build_simulator_framework() {
  target=$1
  framework=$2
  object_dir="$framework.objects"
  compile_common_objects "$SIM_SDK" "$target" "$framework" "$object_dir"
  "$CLANG" -target "$target" -isysroot "$SIM_SDK" \
    -miphoneos-version-min=14.0 -fPIC -fvisibility=hidden -O3 \
    -I"$ROOT/include" -c "$ROOT/src/pwofficial_sim_backend.c" \
    -o "$object_dir/sim_backend.o"
  "$CLANGXX" -target "$target" -isysroot "$SIM_SDK" \
    -miphoneos-version-min=14.0 -dynamiclib -fPIC \
    -Wl,-dead_strip -Wl,-no_adhoc_codesign \
    -Wl,-install_name,@rpath/PWOfficialSfm.framework/PWOfficialSfm \
    -Wl,-exported_symbols_list,"$EXPORTS" \
    "$object_dir/export_shim.o" "$object_dir/telemetry.o" \
    "$object_dir/jpeg_decode.o" "$object_dir/sim_backend.o" \
    -lc++ -framework Foundation -framework Metal -framework CoreVideo \
    -framework IOSurface -framework QuartzCore -framework Accelerate \
    -framework CoreGraphics -framework ImageIO \
    -o "$framework/PWOfficialSfm"
}

build_device_framework
build_simulator_framework arm64-apple-ios14.0-simulator "$SIM_ARM_FRAMEWORK"
build_simulator_framework x86_64-apple-ios14.0-simulator "$SIM_X86_FRAMEWORK"

mkdir -p "$SIM_FRAMEWORK/Headers"
cp "$ROOT/Info.plist" "$SIM_FRAMEWORK/Info.plist"
cp "$ROOT/include/aether_sfm_c.h" "$SIM_FRAMEWORK/Headers/aether_sfm_c.h"
cp "$ROOT/include/official_sfm_c.h" "$SIM_FRAMEWORK/Headers/official_sfm_c.h"
cp "$ROOT/include/official_sfm_io_c.h" "$SIM_FRAMEWORK/Headers/official_sfm_io_c.h"
lipo -create \
  "$SIM_ARM_FRAMEWORK/PWOfficialSfm" \
  "$SIM_X86_FRAMEWORK/PWOfficialSfm" \
  -output "$SIM_FRAMEWORK/PWOfficialSfm"

xcodebuild -create-xcframework \
  -framework "$DEVICE_FRAMEWORK" \
  -framework "$SIM_FRAMEWORK" \
  -output "$OUT"

"$ROOT/scripts/verify_boundary.sh" \
  "$OUT/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm"

after_dawn_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_DAWN_ARCHIVE" | awk '{print $1}')
[ "$after_dawn_sha" = "$PWOFFICIAL_DAWN_SHA256" ] || {
  echo "FAIL: Dawn archive changed during link" >&2
  exit 69
}
after_ceres_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_CERES_ARCHIVE" | awk '{print $1}')
[ "$after_ceres_sha" = "$PWOFFICIAL_CERES_SHA256" ] || {
  echo "FAIL: Ceres archive changed during link" >&2
  exit 69
}
after_glog_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_GLOG_ARCHIVE" | awk '{print $1}')
[ "$after_glog_sha" = "$PWOFFICIAL_GLOG_SHA256" ] || {
  echo "FAIL: glog archive changed during link" >&2
  exit 69
}
[ -s "$PWOFFICIAL_LINK_MAP" ] || {
  echo "FAIL: device link map was not retained" >&2
  exit 70
}
grep -Fq -- "$PWOFFICIAL_CERES_ARCHIVE" "$PWOFFICIAL_LINK_MAP" || {
  echo "FAIL: retained link map does not name the exact Ceres archive" >&2
  exit 70
}
grep -Fq -- "$PWOFFICIAL_GLOG_ARCHIVE" "$PWOFFICIAL_LINK_MAP" || {
  echo "FAIL: retained link map does not name the exact glog archive" >&2
  exit 70
}

/usr/bin/shasum -a 256 \
  "$OUT/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm" \
  "$OUT/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/PWOfficialSfm" \
  "$PWOFFICIAL_GPU_CARRIER" \
  "$PWOFFICIAL_DAWN_ARCHIVE" \
  "$PWOFFICIAL_CERES_ARCHIVE" \
  "$PWOFFICIAL_GLOG_ARCHIVE" \
  "$PWOFFICIAL_LINK_MAP"
