#!/bin/sh

set -eu

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
xrslam_archive="$SRCROOT/../vendor/xrslam/libs/ios-arm64/libxrslam_generic_4beb1a9.a"
xrslam_ceres="$SRCROOT/../vendor/xrslam/libs/ios-arm64/libceres_official_1_14.a"
xrslam_opencv="$SRCROOT/../vendor/xrslam/libs/ios-arm64/libopencv_generic_4_0_1.a"
xrslam_upstream_revision="4beb1a942f33da9afbfae2d70e2c641cfc2bb675"
xrslam_build_patch_sha256="b98ed6aa689c9edaaac6da707d97592217d3f6caccc6df8c4d6961e2ee751de0"
xrslam_destroy_lifecycle_patch_sha256="13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220"
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

set_plist_string "PWProductSourceManifestSHA256" "$product_source_manifest"
set_plist_string "PWDartAOTSHA256" "$dart_aot_sha256"
set_plist_string "PWOfficialSfmSHA256" "$official_sfm_sha256"
set_plist_string "PWXrslamSHA256" "$xrslam_sha256"
set_plist_string "PWXrslamUpstreamRevision" "$xrslam_upstream_revision"
set_plist_string "PWXrslamBuildPatchSHA256" "$xrslam_build_patch_sha256"
set_plist_string "PWXrslamDestroyLifecyclePatchSHA256" "$xrslam_destroy_lifecycle_patch_sha256"
set_plist_string "PWXrslamAlgorithmBranch" "generic"
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

echo "PW_RUNTIME_IDENTITY product=$product_source_manifest dart=$dart_aot_sha256 sfm=$official_sfm_sha256 xrslam=$xrslam_sha256 opencv=$xrslam_opencv_sha256 ceres=$xrslam_ceres_sha256 branch=generic xrslam_ios=false threading=false vio_shadow=$vio_shadow_mode host_uuid=$native_host_uuid build=$diagnostic_build_id"
