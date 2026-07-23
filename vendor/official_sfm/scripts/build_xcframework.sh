#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEV_ROOT=$(CDPATH= cd -- "$ROOT/../.." && pwd)
AETHER_ROOT=${AETHER_ROOT:-"$DEV_ROOT/../Aether3D-cross"}
DIST_ROOT=${DIST_ROOT:-"$DEV_ROOT/../dist"}
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/pwofficial-build.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

DEVICE_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CLANG=$(xcrun --find clang)
CLANGXX=$(xcrun --find clang++)
DEVICE_FRAMEWORK="$BUILD/device/PWOfficialSfm.framework"
SIM_ARM_FRAMEWORK="$BUILD/simulator-arm64/PWOfficialSfm.framework"
SIM_X86_FRAMEWORK="$BUILD/simulator-x86_64/PWOfficialSfm.framework"
SIM_FRAMEWORK="$BUILD/simulator/PWOfficialSfm.framework"
OUT="$ROOT/Frameworks/PWOfficialSfm.xcframework"
EXPORTS="$BUILD/exports.txt"

sed 's/^/_/' "$ROOT/pwofficial_abi_symbols.txt" > "$EXPORTS"
sed 's/^/_/' "$ROOT/pwofficial_io_abi_symbols.txt" >> "$EXPORTS"

build_framework() {
  SDK=$1
  TARGET=$2
  FRAMEWORK=$3
  ARCHIVE=$4
  WITH_GPU=$5
  OBJDIR="$FRAMEWORK.objects"

  mkdir -p "$FRAMEWORK/Headers" "$OBJDIR"
  cp "$ROOT/Info.plist" "$FRAMEWORK/Info.plist"
  cp "$ROOT/include/aether_sfm_c.h" "$FRAMEWORK/Headers/aether_sfm_c.h"
  cp "$ROOT/include/official_sfm_c.h" "$FRAMEWORK/Headers/official_sfm_c.h"
  cp "$ROOT/include/official_sfm_io_c.h" "$FRAMEWORK/Headers/official_sfm_io_c.h"

  "$CLANG" -target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -fPIC -fvisibility=hidden -O3 -I"$ROOT/include" \
    -c "$ROOT/src/pwofficial_export_shim.c" -o "$OBJDIR/export_shim.o"
  "$CLANGXX" -target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -fPIC -fvisibility=hidden -O3 -std=c++17 -fobjc-arc \
    -c "$ROOT/src/pwofficial_telemetry.mm" -o "$OBJDIR/telemetry.o"
  "$CLANGXX" -target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -fPIC -fvisibility=hidden -O3 -std=c++17 -fobjc-arc -I"$ROOT/include" \
    -c "$ROOT/src/pwofficial_jpeg_decode.mm" -o "$OBJDIR/jpeg_decode.o"

  GPU_OBJECT=
  GPU_LDFLAGS=
  CORE_LDFLAGS=
  DEP_LDFLAGS=
  if [ "$WITH_GPU" = yes ]; then
    "$CLANGXX" -target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=14.0 \
      -fPIC -fvisibility=hidden -O3 -std=c++17 -fobjc-arc \
      -c "$ROOT/src/pwofficial_gpu_match.mm" -o "$OBJDIR/gpu_match.o"
    GPU_OBJECT="$OBJDIR/gpu_match.o"
    GPU_LDFLAGS="-Wl,-force_load,$ROOT/libs/ios-arm64/libpwofficial_gpu_extract.a -Wl,-force_load,$AETHER_ROOT/aether_cpp/build-ios-device-dawn/third_party/dawn/src/dawn/native/Debug-iphoneos/libwebgpu_dawn.a"
    CORE_LDFLAGS="-Wl,-force_load,$ARCHIVE"
    DEP_LDFLAGS="-L$DIST_ROOT/libs/ios-arm64/sfm -lceres -lglog -lsqlite3 -lc++ -lz"
  else
    "$CLANG" -target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=14.0 \
      -fPIC -fvisibility=hidden -O3 -I"$ROOT/include" \
      -c "$ROOT/src/pwofficial_sim_backend.c" -o "$OBJDIR/sim_backend.o"
    GPU_OBJECT="$OBJDIR/sim_backend.o"
    DEP_LDFLAGS="-lc++"
  fi

  # shellcheck disable=SC2086
  "$CLANGXX" -target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=14.0 \
    -dynamiclib -fPIC -Wl,-dead_strip -Wl,-no_adhoc_codesign \
    -Wl,-install_name,@rpath/PWOfficialSfm.framework/PWOfficialSfm \
    -Wl,-exported_symbols_list,"$EXPORTS" \
    "$OBJDIR/export_shim.o" "$OBJDIR/telemetry.o" "$OBJDIR/jpeg_decode.o" $GPU_OBJECT \
    $CORE_LDFLAGS $GPU_LDFLAGS $DEP_LDFLAGS \
    -framework Foundation -framework Metal -framework CoreVideo \
    -framework IOSurface -framework QuartzCore -framework Accelerate \
    -framework CoreGraphics -framework ImageIO \
    -o "$FRAMEWORK/PWOfficialSfm"
}

build_framework "$DEVICE_SDK" arm64-apple-ios14.0 "$DEVICE_FRAMEWORK" \
  "$ROOT/libs/ios-arm64/libpwofficial_core.a" yes

build_framework "$SIM_SDK" arm64-apple-ios14.0-simulator "$SIM_ARM_FRAMEWORK" - no
build_framework "$SIM_SDK" x86_64-apple-ios14.0-simulator "$SIM_X86_FRAMEWORK" - no

mkdir -p "$SIM_FRAMEWORK/Headers"
cp "$ROOT/Info.plist" "$SIM_FRAMEWORK/Info.plist"
cp "$ROOT/include/aether_sfm_c.h" "$SIM_FRAMEWORK/Headers/aether_sfm_c.h"
cp "$ROOT/include/official_sfm_c.h" "$SIM_FRAMEWORK/Headers/official_sfm_c.h"
cp "$ROOT/include/official_sfm_io_c.h" "$SIM_FRAMEWORK/Headers/official_sfm_io_c.h"
lipo -create \
  "$SIM_ARM_FRAMEWORK/PWOfficialSfm" \
  "$SIM_X86_FRAMEWORK/PWOfficialSfm" \
  -output "$SIM_FRAMEWORK/PWOfficialSfm"

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -framework "$DEVICE_FRAMEWORK" \
  -framework "$SIM_FRAMEWORK" \
  -output "$OUT"

"$ROOT/scripts/verify_boundary.sh" \
  "$OUT/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm"

shasum -a 256 "$OUT/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm" \
  "$OUT/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/PWOfficialSfm"
