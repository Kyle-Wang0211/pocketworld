#!/bin/sh

set -eu

# ── 引擎臂对账闸(所有 configuration 都跑,不只 Release)────────────────
#
# PW_XRSLAM_ENGINE 是**进程环境**里的请求;PW_XRSLAM_LINKED_ENGINE 是
# ios/Podfile 在 pod install 时写进 Pods-Runner xcconfig 的**实际结果**。
# 两者对不上,只有一种可能:换了开关但 pod install 没重跑,xcconfig 里
# 还是上一条臂 —— 也就是「看起来换了其实没换」。这时必须**构建失败**,
# 不允许静默沿用。(2026-09-20 在台架上因为这个作废过一整轮归因数据。)
pw_xrslam_engine_requested="${PW_XRSLAM_ENGINE:-}"
if [ -z "$pw_xrslam_engine_requested" ]; then
  pw_xrslam_engine_requested="generic"
fi
pw_xrslam_engine_linked="${PW_XRSLAM_LINKED_ENGINE:-generic}"
if [ "$pw_xrslam_engine_requested" != "$pw_xrslam_engine_linked" ]; then
  echo "error: PW_XRSLAM_ENGINE=$pw_xrslam_engine_requested 但 xcconfig 里链的是 $pw_xrslam_engine_linked;换臂后必须重跑 pod install(ios/scripts/select_xrslam_engine.sh)" >&2
  exit 70
fi

# Runtime receipts are mandatory for production Release builds. Debug/Profile
# builds intentionally remain usable without a frozen production manifest.
if [ "${CONFIGURATION:-}" != "Release" ]; then
  exit 0
fi

require_identity() {
  identity_name="$1"
  identity_value="$2"
  if [ -z "$identity_value" ] || [ "$identity_value" = "UNSTAMPED" ]; then
    echo "error: identity value is missing: $identity_name" >&2
    exit 65
  fi
}

require_sha256_identity() {
  identity_name="$1"
  identity_value="$2"
  require_identity "$identity_name" "$identity_value"
  if ! printf '%s\n' "$identity_value" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
    echo "error: identity value is invalid: $identity_name" >&2
    exit 65
  fi
}

require_build_label() {
  identity_name="$1"
  identity_value="$2"
  require_identity "$identity_name" "$identity_value"
  if ! printf '%s\n' "$identity_value" | /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'; then
    echo "error: identity value is invalid: $identity_name" >&2
    exit 65
  fi
}

require_uuid_identity() {
  identity_name="$1"
  identity_value="$2"
  require_identity "$identity_name" "$identity_value"
  if ! printf '%s\n' "$identity_value" | /usr/bin/grep -Eq \
      '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'; then
    echo "error: identity value is invalid: $identity_name" >&2
    exit 65
  fi
}

hash_artifact() {
  artifact_path="$1"
  if [ ! -f "$artifact_path" ]; then
    echo "error: runtime identity artifact is missing: $artifact_path" >&2
    exit 66
  fi
  artifact_sha256="$(/usr/bin/shasum -a 256 "$artifact_path" | /usr/bin/awk '{print $1}')"
  if ! printf '%s\n' "$artifact_sha256" | /usr/bin/grep -Eq '^[0-9a-f]{64}$'; then
    echo "error: runtime identity hash is invalid: $artifact_path" >&2
    exit 67
  fi
  printf '%s\n' "$artifact_sha256"
}

set_plist_string() {
  plist_key="$1"
  plist_value="$2"
  if ! /usr/libexec/PlistBuddy -c "Set :$plist_key $plist_value" "$runtime_plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :$plist_key string $plist_value" "$runtime_plist"
  fi
}

product_source_manifest="${PW_PRODUCT_SOURCE_MANIFEST_SHA256:-}"
diagnostic_build_id="${PW_DIAGNOSTIC_BUILD_ID:-}"
vio_shadow_mode="${PW_VIO_SHADOW_MODE:-}"
require_sha256_identity "PW_PRODUCT_SOURCE_MANIFEST_SHA256" "$product_source_manifest"
require_build_label "PW_DIAGNOSTIC_BUILD_ID" "$diagnostic_build_id"
case "$vio_shadow_mode" in
  on|off) ;;
  *)
    echo "error: identity value is invalid: PW_VIO_SHADOW_MODE" >&2
    exit 65
    ;;
esac

runtime_plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
native_host="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
dart_aot="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/App.framework/App"
official_sfm="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/PWOfficialSfm.framework/PWOfficialSfm"
# 链进去的是哪条臂,就对哪份归档取身份 —— 不再把出货档的名字写死。
xrslam_lib_name="${PW_XRSLAM_LINKED_ENGINE_LIB:-libxrslam_generic_4beb1a9.a}"
xrslam_engine_sha16="${PW_XRSLAM_LINKED_ENGINE_SHA16:-}"
xrslam_engine_fingerprint="${PW_XRSLAM_LINKED_ENGINE_FINGERPRINT:-}"
case "$pw_xrslam_engine_linked" in
  generic)
    xrslam_algorithm_branch="generic"
    xrslam_gpu_frontend="false"
    xrslam_pedigree="shipping"
    xrslam_other_fingerprint="/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/4437f552-36d8-4d91-9d8d-ae4aaadf54b6/scratchpad/build-run1/_deps/depends-opencv-build/opencv2.framework/Headers/core/mat.inl.hpp"
    ;;
  gpufenothread)
    xrslam_algorithm_branch="gpufe_nothread"
    xrslam_gpu_frontend="true"
    xrslam_pedigree="research_only"
    xrslam_other_fingerprint="/private/tmp/opencv-official-c9ad577-b49/modules/core/include/opencv2/core/mat.inl.hpp"
    ;;
  *)
    echo "error: unknown PW_XRSLAM_LINKED_ENGINE: $pw_xrslam_engine_linked" >&2
    exit 65
    ;;
esac
xrslam_archive="$SRCROOT/../vendor/xrslam/libs/ios-arm64/$xrslam_lib_name"
xrslam_ceres="$SRCROOT/../vendor/xrslam/libs/ios-arm64/libceres_official_1_14.a"
xrslam_opencv="$SRCROOT/../vendor/xrslam/libs/ios-arm64/libopencv_generic_4_0_1.a"
xrslam_upstream_revision="4beb1a942f33da9afbfae2d70e2c641cfc2bb675"
xrslam_build_patch_sha256="b98ed6aa689c9edaaac6da707d97592217d3f6caccc6df8c4d6961e2ee751de0"
xrslam_destroy_lifecycle_patch_sha256="13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220"
xrslam_zero_inlier_mask_patch_sha256="62b12204c647e445e88917859de6b29452df0e6cc65b447e7ea86005f98d1794"
opencv_upstream_revision="c9ad5779f2803dcc91a9938142209128d30b22d1"
opencv_build_patch_sha256="4041a1ac34b397679a04b733aa78bb1c37a25fcaf6a19c32e9563b0fd9159136"
ceres_upstream_revision="e809cf0c2879f521078b4c9e6329390b42ecf722"
spdlog_compatibility_patch_sha256="1afb69176857159ad29e69d0abf3359576ebc091104278fee5fdeeff08e21adb"

if [ ! -f "$runtime_plist" ]; then
  echo "error: runtime identity plist is missing: $runtime_plist" >&2
  exit 66
fi
if [ ! -f "$native_host" ]; then
  echo "error: runtime identity artifact is missing: $native_host" >&2
  exit 66
fi

dart_aot_sha256="$(hash_artifact "$dart_aot")"
official_sfm_sha256="$(hash_artifact "$official_sfm")"
xrslam_sha256="$(hash_artifact "$xrslam_archive")"
xrslam_ceres_sha256="$(hash_artifact "$xrslam_ceres")"
xrslam_opencv_sha256="$(hash_artifact "$xrslam_opencv")"
native_host_uuid_lines="$(/usr/bin/xcrun dwarfdump --uuid "$native_host" \
  | /usr/bin/awk '$1 == "UUID:" && $3 == "(arm64)" { print $2 }')"
native_host_uuid_count="$(printf '%s\n' "$native_host_uuid_lines" \
  | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
if [ "$native_host_uuid_count" -ne 1 ]; then
  echo "error: native host must contain exactly one arm64 LC_UUID" >&2
  exit 65
fi
native_host_uuid="$native_host_uuid_lines"
require_uuid_identity "PWNativeHostUUID" "$native_host_uuid"

# ── 二进制层面的换臂自证 ───────────────────────────────────────────────
#
# 「链的是哪条臂」不靠 xcconfig 自述,靠**产物里那条字符串**。两条臂各自
# 把自己的 OpenCV 构建目录绝对路径烤进 __TEXT,__cstring(CV_Assert 的
# __FILE__),彼此不同,别处也造不出来。要求:本臂的指纹**在场**、另一条臂的
# 指纹**不在场**。任何一条不满足就构建失败 —— 缓存里的旧臂混进来一定显形。
if [ -n "$xrslam_engine_fingerprint" ]; then
  if ! /usr/bin/strings -a "$native_host" | /usr/bin/grep -qF "$xrslam_engine_fingerprint"; then
    echo "error: 链接产物里找不到 $pw_xrslam_engine_linked 臂的指纹 —— 链进去的不是它" >&2
    exit 71
  fi
  if /usr/bin/strings -a "$native_host" | /usr/bin/grep -qF "$xrslam_other_fingerprint"; then
    echo "error: 链接产物里同时出现了另一条臂的指纹 —— 两条臂被一起链进去了" >&2
    exit 71
  fi
fi

set_plist_string "PWProductSourceManifestSHA256" "$product_source_manifest"
set_plist_string "PWDartAOTSHA256" "$dart_aot_sha256"
set_plist_string "PWOfficialSfmSHA256" "$official_sfm_sha256"
set_plist_string "PWXrslamSHA256" "$xrslam_sha256"
set_plist_string "PWXrslamUpstreamRevision" "$xrslam_upstream_revision"
set_plist_string "PWXrslamBuildPatchSHA256" "$xrslam_build_patch_sha256"
set_plist_string "PWXrslamDestroyLifecyclePatchSHA256" "$xrslam_destroy_lifecycle_patch_sha256"
set_plist_string "PWXrslamZeroInlierMaskPatchSHA256" "$xrslam_zero_inlier_mask_patch_sha256"
set_plist_string "PWXrslamAlgorithmBranch" "$xrslam_algorithm_branch"
set_plist_string "PWXrslamEngineArm" "$pw_xrslam_engine_linked"
set_plist_string "PWXrslamEngineLib" "$xrslam_lib_name"
set_plist_string "PWXrslamEngineSHA16" "$xrslam_engine_sha16"
set_plist_string "PWXrslamEngineFingerprint" "$xrslam_engine_fingerprint"
set_plist_string "PWXrslamEnginePedigree" "$xrslam_pedigree"
set_plist_string "PWXrslamGpuFrontendLinked" "$xrslam_gpu_frontend"
set_plist_string "PWXrslamIosEnabled" "false"
set_plist_string "PWXrslamThreadingEnabled" "false"
set_plist_string "PWXrslamCompileFlags" "-ffp-contract=off,-fno-fast-math,-fchar8_t,-Dceres=pw_xrslam_ceres_1_14"
set_plist_string "PWOpenCVUpstreamRevision" "$opencv_upstream_revision"
set_plist_string "PWOpenCVBuildPatchSHA256" "$opencv_build_patch_sha256"
set_plist_string "PWOpenCVSHA256" "$xrslam_opencv_sha256"
set_plist_string "PWCeresUpstreamRevision" "$ceres_upstream_revision"
set_plist_string "PWCeresSHA256" "$xrslam_ceres_sha256"
set_plist_string "PWSpdlogCompatibilityPatchSHA256" "$spdlog_compatibility_patch_sha256"
set_plist_string "PWNativeHostUUID" "$native_host_uuid"
set_plist_string "PWLiveCloudDiagnosticBuildId" "$diagnostic_build_id"
set_plist_string "PWVioShadowMode" "$vio_shadow_mode"

echo "PW_RUNTIME_IDENTITY product=$product_source_manifest dart=$dart_aot_sha256 sfm=$official_sfm_sha256 xrslam=$xrslam_sha256 opencv=$xrslam_opencv_sha256 ceres=$xrslam_ceres_sha256 branch=$xrslam_algorithm_branch engine=$pw_xrslam_engine_linked engine_lib=$xrslam_lib_name engine_sha16=$xrslam_engine_sha16 engine_pedigree=$xrslam_pedigree gpu_frontend=$xrslam_gpu_frontend xrslam_ios=false threading=false vio_shadow=$vio_shadow_mode host_uuid=$native_host_uuid build=$diagnostic_build_id"
