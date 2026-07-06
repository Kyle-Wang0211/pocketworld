#!/bin/bash
# build_gpu_extract_archive.sh — compiles the device-proven GPU DSP-SIFT
# extraction chain (dsp_sift_gpu_c.cc + Dawn harness + orchestrator +
# pyramid + 11 baked WGSL sources) into libs/ios-arm64/sfm/
# libpwsfm_gpu_extract.a for the pocketworld app link.
#
# Recipe source: glomap_vendor/iosapp/siftextractbench/project.yml — the
# exact TU/flag set that ran on iPhone 14 Pro (f16 1448 ms/frame @
# 4224×2376/8192 features, all parity gates PASS, ARKit-coexistence
# validated). Dawn itself is NOT baked in here — the podspec links the
# prebuilt iOS libwebgpu_dawn.a by path (member-pull; the renderer's Dawn
# inside libaether3d_ffi.a usually satisfies everything first).
set -euo pipefail

A="$HOME/Developer/Aether3D-cross/aether_cpp"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/libs/ios-arm64/sfm"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CXXFLAGS=(
  -target arm64-apple-ios16.0
  -std=c++20 -stdlib=libc++ -O2 -w
  -DEIGEN_MPL2_ONLY -DGLOG_USE_GLOG_EXPORT -DGLOG_NO_ABBREVIATED_SEVERITIES
  -DGLOG_VERSION_MAJOR=0 -DGLOG_VERSION_MINOR=7
  -I"$A/tools" -I"$A/include" -I"$A/third_party/stb"
  -I"$A/third_party/dawn/include"
  -I"$A/build-ios-device-dawn/third_party/dawn/gen/include"
  -I"$A/third_party/glomap_vendor/colmap-src"
  -I"$A/third_party/glomap_vendor/stubs"
  -I"$A/third_party/glog-install/include"
  -I"$A/third_party/ceres/include"
  -I"$A/third_party/ceres-build-ios/include"
  -I"$A/third_party/ceres/config"
  -I"$A/third_party/eigen-install/include/eigen3"
)

SRCS=(
  "$A/third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc"
  "$A/tools/sift_extract_dawn.cc"
  "$A/tools/sift_pyramid_dawn.cc"
  "$A/tools/dawn_kernel_harness.cpp"
  "$A/build/generated/aether/shaders/sift_gray_to_f32_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_gss_blur_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_gss_resample_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_dog_detect_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_nonextrema_suppress_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_affine_shape_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_orientation_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_dsp_descriptor_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_dsp_descriptor_f16_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_dsp_descriptor_par_wgsl.cpp"
  "$A/build/generated/aether/shaders/sift_dsp_mean_wgsl.cpp"
)

OBJS=()
for src in "${SRCS[@]}"; do
  obj="$TMP/$(basename "${src%.*}").o"
  echo "CXX $(basename "$src")"
  xcrun -sdk iphoneos clang++ "${CXXFLAGS[@]}" -c "$src" -o "$obj"
  OBJS+=("$obj")
done

mkdir -p "$OUT"
rm -f "$OUT/libpwsfm_gpu_extract.a"
xcrun -sdk iphoneos ar rcs "$OUT/libpwsfm_gpu_extract.a" "${OBJS[@]}"
echo "OK: $OUT/libpwsfm_gpu_extract.a"
xcrun -sdk iphoneos nm "$OUT/libpwsfm_gpu_extract.a" | grep -c "T _aether_dsp_sift_extract_gpu" || true
