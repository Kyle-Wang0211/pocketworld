#!/usr/bin/env bash
# PWDense.xcframework (device: gated dense C++ + pwdense_* C ABI, linked with the product's OpenCV 4.0.1 archive,
# the pinned libjpeg-turbo iOS archive and the self-built ORT 1.29.0 (WebGPU) — simulator: pwdense_c_sim stub)
# + PWOnnxRuntime.xcframework (the ORT dylib re-homed as a framework so CocoaPods embeds it).
# Same recipe as vendor/official_sfm/scripts/build_xcframework.sh: -dynamiclib, @rpath install name, export list,
# xcodebuild -create-xcframework. -ffp-contract=off -fno-fast-math like every device OpenCV build.
set -euo pipefail
ROOT=$HOME/Developer/pw-dense-vendor
SRC=$HOME/Developer/Aether3D-cross/aether_cpp/src/dense
AC=$HOME/Developer/Aether3D-cross/aether_cpp
OCVS=$HOME/Developer/opencv-401-src; OCVB=$HOME/Developer/opencv-401-build-mac
OCV_A=$HOME/Developer/pocketworld/vendor/xrslam/libs/ios-arm64/libopencv_generic_4_0_1.a
JPEG_A=$AC/build-ios-device-dawn/third_party/libjpeg-turbo-build/libjpeg.a; JPEG_INC=$AC/third_party/libjpeg-turbo/src; JPEG_CFG=$AC/build-ios-device-dawn/third_party/libjpeg-turbo-build
ORT_DYLIB=$HOME/ort_ios_build/build_ios/Release/Release-iphoneos/libonnxruntime.1.29.0.dylib
ORT_INC=$HOME/ort_ios_build/onnxruntime/include/onnxruntime/core/session
MODEL_SRC=${PW_DENSE_MODEL:-/Users/kaidongwang/Documents/progecttwo/_artifacts/ios_bench_abep2/casdiffmvs_abep2.onnx}
BUILD=$ROOT/build; OUT=$ROOT/Frameworks; rm -rf "$BUILD" "$OUT"; mkdir -p "$BUILD" "$OUT"
DEVICE_SDK=$(xcrun --sdk iphoneos --show-sdk-path); SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
CLANGXX=$(xcrun --find clang++); CLANG=$(xcrun --find clang)
MINOS=26.2   # the shipped OpenCV archive carries minos 26.2
printf '_pwdense_abi_version\n_pwdense_available\n_pwdense_options_default\n_pwdense_default_model_path\n_pwdense_run\n_pwdense_run2\n' > "$BUILD/exports.txt"

# ---- PWOnnxRuntime.framework (device only; simulator gets no ORT — the sim slice of PWDense does not link it)
ORTFW=$BUILD/device/PWOnnxRuntime.framework; mkdir -p "$ORTFW"
cp "$ORT_DYLIB" "$ORTFW/PWOnnxRuntime"
install_name_tool -id @rpath/PWOnnxRuntime.framework/PWOnnxRuntime "$ORTFW/PWOnnxRuntime"
cat > "$ORTFW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PWOnnxRuntime</string>
  <key>CFBundleIdentifier</key><string>com.kyle.pocketworld.onnxruntime</string>
  <key>CFBundleName</key><string>PWOnnxRuntime</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.29.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>16.3</string>
</dict></plist>
PLIST

# ---- PWDense.framework device slice
FW=$BUILD/device/PWDense.framework; OBJ=$BUILD/device/objs; mkdir -p "$FW/Headers" "$OBJ"
CXX=(-target arm64-apple-ios$MINOS -isysroot "$DEVICE_SDK" -miphoneos-version-min=$MINOS -fPIC -fvisibility=hidden -O2 -std=c++20
     -ffp-contract=off -fno-fast-math -I"$SRC" -I"$ORT_INC" -I"$JPEG_INC" -I"$JPEG_CFG" -I"$OCVB" -I"$OCVS/include" -I"$OCVS/modules/core/include" -I"$OCVS/modules/imgproc/include")
OBJS=()
for f in dense_session dense_inputs dense_images dense_fuse dense_fuse_pack dense_runner dense_pipeline pwdense_c; do
  "$CLANGXX" "${CXX[@]}" -c "$SRC/$f.cc" -o "$OBJ/$f.o"; OBJS+=("$OBJ/$f.o")
done
"$CLANGXX" -target arm64-apple-ios$MINOS -isysroot "$DEVICE_SDK" -miphoneos-version-min=$MINOS -dynamiclib -fPIC \
  -Wl,-dead_strip -Wl,-no_adhoc_codesign \
  -Wl,-install_name,@rpath/PWDense.framework/PWDense \
  -Wl,-exported_symbols_list,"$BUILD/exports.txt" \
  "${OBJS[@]}" "$OCV_A" "$JPEG_A" -F"$BUILD/device" -framework PWOnnxRuntime \
  -lc++ -lz -framework Foundation -framework Accelerate \
  -o "$FW/PWDense" 2>&1 | grep -vE "was built for newer 'iOS'" || true
[ -f "$FW/PWDense" ] || { echo "DEVICE LINK FAIL"; exit 1; }
cp "$SRC/pwdense_c.h" "$FW/Headers/pwdense_c.h"; cp "$MODEL_SRC" "$FW/casdiffmvs.onnx"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>PWDense</string>
  <key>CFBundleIdentifier</key><string>com.kyle.pocketworld.dense</string>
  <key>CFBundleName</key><string>PWDense</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MINOS</string>
</dict></plist>
PLIST

# ---- PWDense.framework simulator slice (stub; arm64 + x86_64)
for arch in arm64 x86_64; do
  SFW=$BUILD/sim-$arch/PWDense.framework; mkdir -p "$SFW/Headers"
  "$CLANG" -target $arch-apple-ios14.0-simulator -isysroot "$SIM_SDK" -fPIC -fvisibility=hidden -O2 -I"$SRC" -c "$SRC/pwdense_c_sim.c" -o "$BUILD/sim-$arch.o"
  "$CLANG" -target $arch-apple-ios14.0-simulator -isysroot "$SIM_SDK" -dynamiclib -fPIC -Wl,-no_adhoc_codesign \
    -Wl,-install_name,@rpath/PWDense.framework/PWDense -Wl,-exported_symbols_list,"$BUILD/exports.txt" "$BUILD/sim-$arch.o" -o "$SFW/PWDense"
  cp "$SRC/pwdense_c.h" "$SFW/Headers/"; cp "$FW/Info.plist" "$SFW/Info.plist"
done
SIMFW=$BUILD/sim/PWDense.framework; mkdir -p "$SIMFW/Headers"; cp "$SRC/pwdense_c.h" "$SIMFW/Headers/"; cp "$FW/Info.plist" "$SIMFW/Info.plist"
lipo -create "$BUILD/sim-arm64/PWDense.framework/PWDense" "$BUILD/sim-x86_64/PWDense.framework/PWDense" -output "$SIMFW/PWDense"

xcodebuild -create-xcframework -framework "$FW" -framework "$SIMFW" -output "$OUT/PWDense.xcframework" | tail -1
xcodebuild -create-xcframework -framework "$ORTFW" -output "$OUT/PWOnnxRuntime.xcframework" | tail -1
echo "== boundary: exported symbols of the device PWDense =="; nm -gU "$OUT/PWDense.xcframework/ios-arm64/PWDense.framework/PWDense" | awk '{print $3}'
otool -L "$OUT/PWDense.xcframework/ios-arm64/PWDense.framework/PWDense" | grep -E "PWOnnxRuntime|libc\+\+|libz"
md5 -q "$FW/casdiffmvs.onnx" "$MODEL_SRC"
du -sh "$OUT"/*
