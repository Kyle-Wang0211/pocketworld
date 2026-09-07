#!/bin/sh

set -eu

xrslam_revision="4beb1a942f33da9afbfae2d70e2c641cfc2bb675"
opencv_revision="c9ad5779f2803dcc91a9938142209128d30b22d1"
ceres_revision="e809cf0c2879f521078b4c9e6329390b42ecf722"
eigen_ref="3.3.7"
spdlog_ref="v1.3.1"
yaml_ref="yaml-cpp-0.7.0"
eigen_revision="cf794d3b741a6278df169e58461f8529f43bce5d"
spdlog_revision="a7148b718ea2fabb8387cb90aee9bf448da63e65"
yaml_revision="0579ae3d976091d7d664aa9d2527e0d0cff25763"
expected_ndk_revision="29.0.14206865"
expected_cmake_version="4.2.3"
expected_ninja_version="1.13.2"
expected_clang_revision="5e96669f06077099aa41290cdb4c5e6fa0f59349"
source_date_epoch="1700000000"
xrslam_patch_sha256="b98ed6aa689c9edaaac6da707d97592217d3f6caccc6df8c4d6961e2ee751de0"
zero_inlier_mask_patch_sha256="62b12204c647e445e88917859de6b29452df0e6cc65b447e7ea86005f98d1794"
opencv_patch_sha256="4041a1ac34b397679a04b733aa78bb1c37a25fcaf6a19c32e9563b0fd9159136"
spdlog_patch_sha256="1afb69176857159ad29e69d0abf3359576ebc091104278fee5fdeeff08e21adb"
expected_artifact_sha256="083220bb6ecbaa161c0f0bae9bf007da5c59ed010455cf6f2e3b600bb0eaf8f4"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../../.." && pwd)"
patch_dir="$script_dir/patches"
artifact="$script_dir/libs/arm64-v8a/libxrslam_generic_4beb1a9.so"
ndk_root="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-ndk}"
ndk_bin="$ndk_root/toolchains/llvm/prebuilt/darwin-x86_64/bin"

verify_toolchain() {
  actual_ndk_revision="$(awk -F' = ' '/^Pkg.Revision/ {print $2}' "$ndk_root/source.properties")"
  actual_cmake_version="$(cmake --version | awk 'NR == 1 {print $3}')"
  actual_ninja_version="$(ninja --version)"
  "$ndk_bin/clang++" --version | grep -Fq "$expected_clang_revision"
  test "$actual_ndk_revision" = "$expected_ndk_revision"
  test "$actual_cmake_version" = "$expected_cmake_version"
  test "$actual_ninja_version" = "$expected_ninja_version"
}

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_hash() {
  path="$1"
  expected="$2"
  actual="$(hash_file "$path")"
  if [ "$actual" != "$expected" ]; then
    echo "hash mismatch: $path expected=$expected actual=$actual" >&2
    exit 65
  fi
}

verify_pinned_inputs() {
  verify_toolchain
  require_hash "$patch_dir/xrslam_generic_mobile.patch" "$xrslam_patch_sha256"
  require_hash "$repo_root/vendor/xrslam/patches/xrslam_zero_inlier_mask.patch" \
    "$zero_inlier_mask_patch_sha256"
  require_hash "$patch_dir/opencv_mobile_contract.patch" "$opencv_patch_sha256"
  require_hash "$patch_dir/spdlog_char8_compat.patch" "$spdlog_patch_sha256"
  require_hash "$artifact" "$expected_artifact_sha256"
  "$ndk_bin/llvm-nm" -D --defined-only "$artifact" |
    grep -Eq ' XRSLAMCreate$'
  "$ndk_bin/llvm-nm" -D --defined-only "$artifact" |
    grep -Eq ' XRSLAMPushSensorData$'
  "$ndk_bin/llvm-nm" -D --defined-only "$artifact" |
    grep -Eq ' XRSLAMRunOneFrame$'
  "$ndk_bin/llvm-nm" -D --defined-only "$artifact" |
    grep -Eq ' XRSLAMGetResult$'
  "$ndk_bin/llvm-nm" -D --defined-only "$artifact" |
    grep -Eq ' XRSLAMDestroy$'
  "$ndk_bin/llvm-readelf" -lW "$artifact" |
    awk '$1 == "LOAD" && $NF != "0x4000" { bad = 1 } END { exit bad }'
}

if [ "${1:-}" = "--verify-only" ] || [ "$#" -eq 0 ]; then
  verify_pinned_inputs
  echo "XRSLAM_GENERIC_CORE_VERIFIED sha256=$expected_artifact_sha256"
  exit 0
fi

if [ "$1" != "--rebuild" ]; then
  echo "usage: $0 [--verify-only|--rebuild]" >&2
  exit 64
fi

work_root="${PW_XRSLAM_WORK_ROOT:-}"
case "$work_root" in
  /private/tmp/pw-xrslam-rebuild-*) ;;
  *)
    echo "PW_XRSLAM_WORK_ROOT must be a new /private/tmp/pw-xrslam-rebuild-* path" >&2
    exit 64
    ;;
esac
if [ -e "$work_root" ]; then
  echo "refusing to overwrite existing work root: $work_root" >&2
  exit 65
fi

mkdir -p "$work_root"
xrslam_source="$work_root/xrslam"
opencv_source="$work_root/opencv"
opencv_build="$work_root/opencv-build"
xrslam_build="$work_root/xrslam-build"
deps_root="$xrslam_build/_deps"

git clone --filter=blob:none --no-checkout \
  https://github.com/openxrlab/xrslam.git "$xrslam_source"
git -C "$xrslam_source" checkout --detach "$xrslam_revision"
test "$(git -C "$xrslam_source" rev-parse HEAD)" = "$xrslam_revision"
git -C "$xrslam_source" apply "$patch_dir/xrslam_generic_mobile.patch"
require_hash "$patch_dir/xrslam_generic_mobile.patch" "$xrslam_patch_sha256"
git -C "$xrslam_source" apply \
  "$repo_root/vendor/xrslam/patches/xrslam_zero_inlier_mask.patch"
require_hash "$repo_root/vendor/xrslam/patches/xrslam_zero_inlier_mask.patch" \
  "$zero_inlier_mask_patch_sha256"

git clone --filter=blob:none --no-checkout \
  https://github.com/opencv/opencv.git "$opencv_source"
git -C "$opencv_source" checkout --detach "$opencv_revision"
test "$(git -C "$opencv_source" rev-parse HEAD)" = "$opencv_revision"
git -C "$opencv_source" apply "$patch_dir/opencv_mobile_contract.patch"
require_hash "$patch_dir/opencv_mobile_contract.patch" "$opencv_patch_sha256"

deterministic_c_flags="-O3 -DNDEBUG -ffp-contract=off -fno-fast-math -ffile-prefix-map=$work_root=/pwbuild -fdebug-prefix-map=$work_root=/pwbuild"
deterministic_cxx_flags="$deterministic_c_flags -fchar8_t"
export SOURCE_DATE_EPOCH="$source_date_epoch"

cmake -S "$opencv_source" -B "$opencv_build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ndk_root/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DPW_CROSS_PLATFORM_SINGLE_THREADED=ON \
  -DWITH_PTHREADS_PF=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_opencv_world=OFF \
  -DBUILD_LIST=core,imgproc,imgcodecs,video,features2d,calib3d \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF \
  -DBUILD_JAVA=OFF \
  -DBUILD_ZLIB=OFF \
  -DWITH_ZLIB=ON \
  -DWITH_OPENCL=OFF \
  -DWITH_IPP=OFF \
  -DWITH_TBB=OFF \
  -DWITH_EIGEN=OFF \
  -DWITH_LAPACK=OFF \
  -DWITH_ITT=OFF \
  -DWITH_PNG=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_TIFF=OFF \
  -DWITH_WEBP=OFF \
  -DWITH_OPENEXR=OFF \
  '-DCPU_BASELINE=NEON;FP16' \
  -DCPU_DISPATCH= \
  "-DCMAKE_C_FLAGS_RELEASE=$deterministic_c_flags" \
  "-DCMAKE_CXX_FLAGS_RELEASE=$deterministic_cxx_flags"
cmake --build "$opencv_build" --parallel 12 --target \
  opencv_core opencv_flann opencv_imgproc opencv_imgcodecs \
  opencv_features2d opencv_calib3d opencv_video

mkdir -p "$deps_root"
git clone --filter=blob:none --no-checkout \
  https://github.com/eigenteam/eigen-git-mirror.git \
  "$deps_root/depends-eigen-src"
git -C "$deps_root/depends-eigen-src" checkout --detach "$eigen_revision"
test "$(git -C "$deps_root/depends-eigen-src" rev-parse HEAD)" = "$eigen_revision"
git clone --filter=blob:none --no-checkout \
  https://github.com/gabime/spdlog.git \
  "$deps_root/depends-spdlog-src"
git -C "$deps_root/depends-spdlog-src" checkout --detach "$spdlog_revision"
test "$(git -C "$deps_root/depends-spdlog-src" rev-parse HEAD)" = "$spdlog_revision"
git -C "$deps_root/depends-spdlog-src" apply \
  "$patch_dir/spdlog_char8_compat.patch"
require_hash "$patch_dir/spdlog_char8_compat.patch" "$spdlog_patch_sha256"
git clone --filter=blob:none --no-checkout \
  https://github.com/ceres-solver/ceres-solver.git \
  "$deps_root/depends-ceres-solver-src"
git -C "$deps_root/depends-ceres-solver-src" checkout --detach \
  "$ceres_revision"
test "$(git -C "$deps_root/depends-ceres-solver-src" rev-parse HEAD)" = "$ceres_revision"
git clone --filter=blob:none --no-checkout \
  https://github.com/jbeder/yaml-cpp.git \
  "$deps_root/depends-yaml-cpp-src"
git -C "$deps_root/depends-yaml-cpp-src" checkout --detach "$yaml_revision"
test "$(git -C "$deps_root/depends-yaml-cpp-src" rev-parse HEAD)" = "$yaml_revision"

cmake -S "$xrslam_source" -B "$xrslam_build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ndk_root/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-24 \
  -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DXRSLAM_CROSS_PLATFORM_GENERIC=ON \
  -DXRSLAM_IOS=OFF \
  -DXRSLAM_ENABLE_THREADING=OFF \
  -DXRSLAM_TEST=OFF \
  -DOpenCV_DIR="$opencv_build" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  "-DCMAKE_C_FLAGS_RELEASE=$deterministic_c_flags" \
  "-DCMAKE_CXX_FLAGS_RELEASE=$deterministic_cxx_flags" \
  '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=sha1 -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384' \
  -DSUITESPARSE=OFF \
  -DCXSPARSE=OFF \
  -DLAPACK=OFF \
  -DACCELERATESPARSE=OFF \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON
cmake --build "$xrslam_build" --parallel 12 --target xrslam

rebuilt="$xrslam_source/lib/libxrslam.so"
"$ndk_bin/llvm-strip" --strip-debug "$rebuilt"
rebuilt_sha256="$(hash_file "$rebuilt")"
run_receipt="$work_root/rebuild-run.receipt"
{
  echo "schema=pw.xrslam.generic-core-rebuild-run/1"
  echo "script_sha256=$(hash_file "$0")"
  echo "xrslam_revision=$(git -C "$xrslam_source" rev-parse HEAD)"
  echo "opencv_revision=$(git -C "$opencv_source" rev-parse HEAD)"
  echo "ceres_revision=$(git -C "$deps_root/depends-ceres-solver-src" rev-parse HEAD)"
  echo "eigen_ref=$eigen_ref"
  echo "eigen_revision=$(git -C "$deps_root/depends-eigen-src" rev-parse HEAD)"
  echo "spdlog_ref=$spdlog_ref"
  echo "spdlog_revision=$(git -C "$deps_root/depends-spdlog-src" rev-parse HEAD)"
  echo "yaml_ref=$yaml_ref"
  echo "yaml_revision=$(git -C "$deps_root/depends-yaml-cpp-src" rev-parse HEAD)"
  echo "android_ndk_revision=$expected_ndk_revision"
  echo "cmake_version=$expected_cmake_version"
  echo "ninja_version=$expected_ninja_version"
  echo "clang_revision=$expected_clang_revision"
  echo "source_date_epoch=$source_date_epoch"
  echo "xrslam_patch_sha256=$(hash_file "$patch_dir/xrslam_generic_mobile.patch")"
  echo "zero_inlier_mask_patch_sha256=$(hash_file "$repo_root/vendor/xrslam/patches/xrslam_zero_inlier_mask.patch")"
  echo "opencv_patch_sha256=$(hash_file "$patch_dir/opencv_mobile_contract.patch")"
  echo "spdlog_patch_sha256=$(hash_file "$patch_dir/spdlog_char8_compat.patch")"
  echo "artifact_sha256=$rebuilt_sha256"
} > "$run_receipt"
echo "XRSLAM_GENERIC_CORE_REBUILT path=$rebuilt sha256=$rebuilt_sha256"
echo "production_artifact=$artifact expected_sha256=$expected_artifact_sha256"
echo "run_receipt=$run_receipt sha256=$(hash_file "$run_receipt")"
echo "repo_root=$repo_root XRSLAM_IOS=OFF XRSLAM_ENABLE_THREADING=OFF"
require_hash "$rebuilt" "$expected_artifact_sha256"
echo "XRSLAM_GENERIC_CORE_REBUILD_VERIFIED sha256=$expected_artifact_sha256"
