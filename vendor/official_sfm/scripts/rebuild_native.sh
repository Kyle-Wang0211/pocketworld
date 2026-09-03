#!/bin/sh
set -eu

# PWOFFICIAL_P3_PRODUCT_PROMOTION_V1
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROMOTE="$ROOT/scripts/promote_official_pair.py"
PWOFFICIAL_EXPECTED_PROMOTE_HELPER_SHA256=425e74c73228dc18c0c6136396fbb214bba90055cddec436a1fd0e56cf4f3073
[ -f "$PROMOTE" ] || {
  echo "FAIL: missing product promotion helper: $PROMOTE" >&2
  exit 65
}
[ "$(/usr/bin/shasum -a 256 "$PROMOTE" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_PROMOTE_HELPER_SHA256" ] || {
  echo "FAIL: product promotion helper SHA-256 mismatch" >&2
  exit 65
}

# Recovery is deliberately the first stateful product operation. It must run
# before manifests, SDK discovery, Git identity, or dependency preflight can
# reject the build, because those inputs may be the reason recovery is needed.
python3 "$PROMOTE" --recover-only

: "${PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST:?fresh-review accepted product manifest is required}"
: "${PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST_SHA256:?accepted manifest SHA-256 is required}"
: "${PWOFFICIAL_IDENTITY_OBSERVER:?accepted product identity observer is required}"
DEV_ROOT=$(CDPATH= cd -- "$ROOT/../.." && pwd)
AETHER_ROOT=${AETHER_ROOT:-"$DEV_ROOT/../Aether3D-cross"}
BUILD_FRAMEWORK="$ROOT/scripts/build_xcframework.sh"
VERIFY_CARRIER="$AETHER_ROOT/aether_cpp/tests/sift/verify_pwofficial_gpu_extract_artifact.sh"
ALGORITHM_REVISION=b930ab185135dfbd172aef7c2bbeed67ef315f75
PWOFFICIAL_DAWN_ARCHIVE="$AETHER_ROOT/aether_cpp/build-ios-device-dawn/third_party/dawn/src/dawn/native/Debug-iphoneos/libwebgpu_dawn.a"
# [PW-MIXED-MMA 2026-09-04] Dawn 归档更新:vendored Dawn 的 Metal 后端补登第三条
# 子组矩阵配置(f16 in → f32 out 8x8x8)。上游 Dawn 只硬编码 f32→f32 与 f16→f16
# (metal/PhysicalDeviceMTL.mm),而 Apple 硬件/MSL/WGSL 语言层/tint 生成端全都支持
# 混合形态 —— 我们出货的 Metal 匹配核就在用。补上后 WGSL 匹配器拿到同款
# half 操作数 + float 累加器:**逐字节精确**(u8 在 f16 精确;逐积 ≤65,025、
# K=128 总和 ≤262,144 在 f32 24 位尾数内精确),主机实测 −11.4%。
# 归档变更方式:只把重编的 PhysicalDeviceMTL.o 替换进 6 月钉定的归档
# (640 个成员,其余逐字节未动,仅 __.SYMDEF 由 ranlib 重建)。
# 旧钉子(6 月 21 日):625cf65dded708ad1abd3dc92f3b47c3c90c384f508676b56303f9341d301b42
PWOFFICIAL_DAWN_SHA256=a283007b6bb4f3a328434205e93a73be5738563393033c2dd81b29e3364ccb17
PWOFFICIAL_EXPECTED_CARRIER_SHA256=189f728d21c2efa211851e6d42e63182a0808e836884baed8b6e060c91a48902
PWOFFICIAL_EXPECTED_OLD_CARRIER_SHA256=6c6a0aa0c5abf5eda79c50ef367f04c67838326b5f7c42e09f6649f8906eb88e
PWOFFICIAL_EXPECTED_OLD_FRAMEWORK_SHA256=0b69ca576a624972f0b95993d8f1e217a1f0bfe54fe1b1ac0890a37531520485
PWOFFICIAL_EXPECTED_SELF_SHA256=cb15b6201e76b5ef1fd9a522265da823ff16498c2b7760a032317e8b04214eaa
PWOFFICIAL_EXPECTED_CORE_SHA256=1ac64d0a138f47f6285c36e6b4b257832ac3932264b8df664797cbeb2217bb04
PWOFFICIAL_EXPECTED_CERES_SHA256=ac61cdcf32f5948fec0bb8892b22803c9752787da57de68b959137bb19e87dd6
PWOFFICIAL_EXPECTED_GLOG_SHA256=dc35639b7b1b9d7d9603f13bbf9d4c883cd64099d8e537595cce69edf8ac3b03
PWOFFICIAL_EXPECTED_SQLITE_TBD_SHA256=a6c7fdd47be427d45dcf1cf00adf290018285776b53136cd3e501a485c3ff279
PWOFFICIAL_EXPECTED_OBSERVER_SHA256=eb493fd4e097e58809d8b228f30ad4d91319a419bd5045787a384fb01eff934a
LIVE_CARRIER="$ROOT/libs/ios-arm64/libpwofficial_gpu_extract.a"
LIVE_FRAMEWORK="$ROOT/Frameworks/PWOfficialSfm.xcframework"
PRESERVE_SELF="$DEV_ROOT/vendor/aether_ffi/libs/ios-arm64/sfm/libpwsfm_gpu_extract.a"
CORE_ARCHIVE="$ROOT/libs/ios-arm64/libpwofficial_core.a"
DIST_ROOT=${DIST_ROOT:-"$DEV_ROOT/../dist"}
CERES_ARCHIVE="$DIST_ROOT/libs/ios-arm64/sfm/libceres.a"
GLOG_ARCHIVE="$DIST_ROOT/libs/ios-arm64/sfm/libglog.a"
IPHONEOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SQLITE_TBD="$IPHONEOS_SDK/usr/lib/libsqlite3.tbd"

for required in \
  "$PROMOTE" \
  "$BUILD_FRAMEWORK" \
  "$VERIFY_CARRIER" \
  "$PWOFFICIAL_DAWN_ARCHIVE" \
  "$LIVE_CARRIER" \
  "$LIVE_FRAMEWORK" \
  "$PRESERVE_SELF" \
  "$CORE_ARCHIVE" \
  "$CERES_ARCHIVE" \
  "$GLOG_ARCHIVE" \
  "$SQLITE_TBD"
do
  [ -e "$required" ] || {
    echo "FAIL: missing frozen input: $required" >&2
    exit 65
  }
done

[ -f "$PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST" ] || {
  echo "FAIL: missing accepted product manifest" >&2
  exit 65
}
[ -x "$PWOFFICIAL_IDENTITY_OBSERVER" ] || {
  echo "FAIL: identity observer is missing or not executable" >&2
  exit 65
}
[ "$(/usr/bin/shasum -a 256 "$PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST" | awk '{print $1}')" = \
  "$PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST_SHA256" ] || {
  echo "FAIL: accepted product manifest SHA-256 mismatch" >&2
  exit 65
}
[ "$(/usr/bin/shasum -a 256 "$PWOFFICIAL_IDENTITY_OBSERVER" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_OBSERVER_SHA256" ] || {
  echo "FAIL: product identity observer SHA-256 mismatch" >&2
  exit 65
}

actual_revision=$(git -C "$AETHER_ROOT" rev-parse HEAD)
[ "$actual_revision" = "$ALGORITHM_REVISION" ] || {
  echo "FAIL: algorithm revision mismatch: $actual_revision" >&2
  exit 66
}
actual_dawn_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_DAWN_ARCHIVE" | awk '{print $1}')
[ "$actual_dawn_sha" = "$PWOFFICIAL_DAWN_SHA256" ] || {
  echo "FAIL: pinned Dawn archive SHA-256 mismatch" >&2
  exit 67
}
[ "$(/usr/bin/shasum -a 256 "$CERES_ARCHIVE" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_CERES_SHA256" ] || {
  echo "FAIL: frozen Ceres archive SHA-256 mismatch" >&2
  exit 67
}
[ "$(/usr/bin/shasum -a 256 "$GLOG_ARCHIVE" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_GLOG_SHA256" ] || {
  echo "FAIL: frozen glog archive SHA-256 mismatch" >&2
  exit 67
}
[ "$(/usr/bin/shasum -a 256 "$SQLITE_TBD" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_SQLITE_TBD_SHA256" ] || {
  echo "FAIL: frozen iPhoneOS sqlite3 stub SHA-256 mismatch" >&2
  exit 67
}

PWOFFICIAL_WORK=$(mktemp -d /private/tmp/pwofficial-p3-promotion.XXXXXX)
PWOFFICIAL_TASK_ROOT=$PWOFFICIAL_WORK
CARRIER_BUILD="$PWOFFICIAL_WORK/carrier-build"
PWOFFICIAL_GPU_CARRIER="$CARRIER_BUILD/Release-iphoneos/libpwofficial_gpu_extract.a"
PWOFFICIAL_XCFRAMEWORK_OUT="$PWOFFICIAL_WORK/PWOfficialSfm.xcframework"
PWOFFICIAL_LINK_MAP="$PWOFFICIAL_WORK/PWOfficialSfm-device.map"

verify_accepted_product_identity() {
  output=$1
  "$PWOFFICIAL_IDENTITY_OBSERVER" "$DEV_ROOT" "$output"
  if ! cmp -s "$PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST" "$output"; then
    echo "FAIL: product identity drifted from the fresh-review accepted manifest" >&2
    diff -u "$PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST" "$output" >&2 || true
    exit 68
  fi
}

verify_accepted_product_identity \
  "$PWOFFICIAL_WORK/product-identity-before-build.manifest"

old_carrier_sha=$(/usr/bin/shasum -a 256 "$LIVE_CARRIER" | awk '{print $1}')
old_framework_sha=$(python3 "$PROMOTE" --sha256-path "$LIVE_FRAMEWORK")
preserve_sha=$(/usr/bin/shasum -a 256 "$PRESERVE_SELF" | awk '{print $1}')
core_sha=$(/usr/bin/shasum -a 256 "$CORE_ARCHIVE" | awk '{print $1}')
[ "$old_carrier_sha" = "$PWOFFICIAL_EXPECTED_OLD_CARRIER_SHA256" ] || {
  echo "FAIL: old official carrier differs from the accepted product identity" >&2
  exit 68
}
[ "$old_framework_sha" = "$PWOFFICIAL_EXPECTED_OLD_FRAMEWORK_SHA256" ] || {
  echo "FAIL: old official framework differs from the accepted product identity" >&2
  exit 68
}
[ "$preserve_sha" = "$PWOFFICIAL_EXPECTED_SELF_SHA256" ] || {
  echo "FAIL: self carrier differs from the frozen read-only identity" >&2
  exit 68
}
[ "$core_sha" = "$PWOFFICIAL_EXPECTED_CORE_SHA256" ] || {
  echo "FAIL: official core differs from the accepted product identity" >&2
  exit 68
}

cmake -S "$AETHER_ROOT/aether_cpp" -B "$CARRIER_BUILD" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_BUILD_TYPE=Release \
  -DDAWN_FETCH_DEPENDENCIES=OFF \
  -DAETHER_ALLOW_TEST_ASSET_DOWNLOADS=OFF \
  -DAETHER_ENABLE_DAWN=ON
cmake --build "$CARRIER_BUILD" --config Release --target pwofficial_gpu_extract

"$VERIFY_CARRIER" "$PWOFFICIAL_GPU_CARRIER"
candidate_carrier_sha=$(/usr/bin/shasum -a 256 "$PWOFFICIAL_GPU_CARRIER" | awk '{print $1}')
[ "$candidate_carrier_sha" = "$PWOFFICIAL_EXPECTED_CARRIER_SHA256" ] || {
  echo "FAIL: candidate carrier does not match the two-build accepted artifact" >&2
  exit 68
}

"$ROOT/scripts/verify_abi_signatures.py"
"$ROOT/scripts/verify_source_parity.py"

PWOFFICIAL_TASK_ROOT="$PWOFFICIAL_TASK_ROOT" \
PWOFFICIAL_GPU_CARRIER="$PWOFFICIAL_GPU_CARRIER" \
PWOFFICIAL_XCFRAMEWORK_OUT="$PWOFFICIAL_XCFRAMEWORK_OUT" \
PWOFFICIAL_DAWN_ARCHIVE="$PWOFFICIAL_DAWN_ARCHIVE" \
PWOFFICIAL_DAWN_SHA256="$PWOFFICIAL_DAWN_SHA256" \
PWOFFICIAL_LINK_MAP="$PWOFFICIAL_LINK_MAP" \
PWOFFICIAL_CERES_ARCHIVE="$CERES_ARCHIVE" \
PWOFFICIAL_CERES_SHA256="$PWOFFICIAL_EXPECTED_CERES_SHA256" \
PWOFFICIAL_GLOG_ARCHIVE="$GLOG_ARCHIVE" \
PWOFFICIAL_GLOG_SHA256="$PWOFFICIAL_EXPECTED_GLOG_SHA256" \
  "$BUILD_FRAMEWORK"

candidate_framework_sha=$(python3 "$PROMOTE" \
  --sha256-path "$PWOFFICIAL_XCFRAMEWORK_OUT")
[ -s "$PWOFFICIAL_LINK_MAP" ] || {
  echo "FAIL: candidate build did not retain a link map" >&2
  exit 69
}

[ "$(/usr/bin/shasum -a 256 "$PRESERVE_SELF" | awk '{print $1}')" = "$preserve_sha" ] ||
  {
    echo "FAIL: self carrier changed during candidate build" >&2
    exit 70
  }
[ "$(/usr/bin/shasum -a 256 "$CORE_ARCHIVE" | awk '{print $1}')" = "$core_sha" ] ||
  {
    echo "FAIL: official core changed during candidate build" >&2
    exit 70
  }
[ "$(/usr/bin/shasum -a 256 "$PWOFFICIAL_DAWN_ARCHIVE" | awk '{print $1}')" = \
  "$PWOFFICIAL_DAWN_SHA256" ] || {
  echo "FAIL: Dawn archive changed during candidate build" >&2
  exit 70
}
[ "$(/usr/bin/shasum -a 256 "$CERES_ARCHIVE" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_CERES_SHA256" ] || {
  echo "FAIL: Ceres archive changed during candidate build" >&2
  exit 70
}
[ "$(/usr/bin/shasum -a 256 "$GLOG_ARCHIVE" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_GLOG_SHA256" ] || {
  echo "FAIL: glog archive changed during candidate build" >&2
  exit 70
}
[ "$(/usr/bin/shasum -a 256 "$SQLITE_TBD" | awk '{print $1}')" = \
  "$PWOFFICIAL_EXPECTED_SQLITE_TBD_SHA256" ] || {
  echo "FAIL: iPhoneOS sqlite3 stub changed during candidate build" >&2
  exit 70
}

verify_accepted_product_identity \
  "$PWOFFICIAL_WORK/product-identity-before-promotion.manifest"

python3 "$PROMOTE" \
  --task-root "$PWOFFICIAL_TASK_ROOT" \
  --candidate-carrier "$PWOFFICIAL_GPU_CARRIER" \
  --candidate-framework "$PWOFFICIAL_XCFRAMEWORK_OUT" \
  --expected-old-carrier-sha256 "$old_carrier_sha" \
  --expected-old-framework-sha256 "$old_framework_sha" \
  --expected-candidate-carrier-sha256 "$candidate_carrier_sha" \
  --expected-candidate-framework-sha256 "$candidate_framework_sha" \
  --preserve-path "$PRESERVE_SELF" \
  --expected-preserve-sha256 "$preserve_sha" \
  --expected-core-sha256 "$core_sha" \
  --dawn-archive "$PWOFFICIAL_DAWN_ARCHIVE" \
  --expected-dawn-sha256 "$PWOFFICIAL_DAWN_SHA256" \
  --ceres-archive "$CERES_ARCHIVE" \
  --expected-ceres-sha256 "$PWOFFICIAL_EXPECTED_CERES_SHA256" \
  --glog-archive "$GLOG_ARCHIVE" \
  --expected-glog-sha256 "$PWOFFICIAL_EXPECTED_GLOG_SHA256" \
  --sqlite-tbd "$SQLITE_TBD" \
  --expected-sqlite-tbd-sha256 "$PWOFFICIAL_EXPECTED_SQLITE_TBD_SHA256"

[ "$(/usr/bin/shasum -a 256 "$LIVE_CARRIER" | awk '{print $1}')" = \
  "$candidate_carrier_sha" ] || {
  echo "FAIL: promoted carrier verification failed" >&2
  exit 71
}
[ "$(python3 "$PROMOTE" --sha256-path "$LIVE_FRAMEWORK")" = \
  "$candidate_framework_sha" ] || {
  echo "FAIL: promoted framework verification failed" >&2
  exit 71
}
[ "$(/usr/bin/shasum -a 256 "$PRESERVE_SELF" | awk '{print $1}')" = "$preserve_sha" ] ||
  {
    echo "FAIL: self carrier changed after promotion" >&2
    exit 71
  }

python3 "$PROMOTE" \
  --assert-ready \
  --expected-ready-carrier-sha256 "$candidate_carrier_sha" \
  --expected-ready-framework-sha256 "$candidate_framework_sha" \
  --preserve-path "$PRESERVE_SELF" \
  --expected-preserve-sha256 "$preserve_sha" \
  --expected-core-sha256 "$core_sha" \
  --dawn-archive "$PWOFFICIAL_DAWN_ARCHIVE" \
  --expected-dawn-sha256 "$PWOFFICIAL_DAWN_SHA256" \
  --ceres-archive "$CERES_ARCHIVE" \
  --expected-ceres-sha256 "$PWOFFICIAL_EXPECTED_CERES_SHA256" \
  --glog-archive "$GLOG_ARCHIVE" \
  --expected-glog-sha256 "$PWOFFICIAL_EXPECTED_GLOG_SHA256" \
  --sqlite-tbd "$SQLITE_TBD" \
  --expected-sqlite-tbd-sha256 "$PWOFFICIAL_EXPECTED_SQLITE_TBD_SHA256"

"$ROOT/scripts/verify_abi_signatures.py"
"$ROOT/scripts/verify_boundary.sh" \
  "$LIVE_FRAMEWORK/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm"
"$ROOT/scripts/verify_source_parity.py"

echo "PASS: official carrier/framework pair promoted transactionally"
echo "PWOFFICIAL_EVIDENCE_DIR=$PWOFFICIAL_WORK"
echo "PWOFFICIAL_GPU_CARRIER_SHA256=$candidate_carrier_sha"
echo "PWOFFICIAL_XCFRAMEWORK_SHA256=$candidate_framework_sha"
echo "PWOFFICIAL_LINK_MAP=$PWOFFICIAL_LINK_MAP"
