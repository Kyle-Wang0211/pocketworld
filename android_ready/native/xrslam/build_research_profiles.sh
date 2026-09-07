#!/bin/sh

set -eu

xrslam_revision="4beb1a942f33da9afbfae2d70e2c641cfc2bb675"
xrslam_tree="8dc778aa6e748f1b34c9c96ef083311eab580265"
target_source_manifest_sha256="dde850251a1b5ced4dd258f767a78918b51889c3b103b703a44193f15363a2b5"
ios_toolchain_sha256="ad3531f41be7390cba4e8f93e93d370108cdc45018413e0c27bb8920a4c31aad"
minimum_ios="14.0"
opencv_revision="c9ad5779f2803dcc91a9938142209128d30b22d1"
ceres_revision="e809cf0c2879f521078b4c9e6329390b42ecf722"
eigen_revision="cf794d3b741a6278df169e58461f8529f43bce5d"
spdlog_revision="a7148b718ea2fabb8387cb90aee9bf448da63e65"
yaml_revision="0579ae3d976091d7d664aa9d2527e0d0cff25763"
generic_patch_sha256="b98ed6aa689c9edaaac6da707d97592217d3f6caccc6df8c4d6961e2ee751de0"
zero_patch_sha256="62b12204c647e445e88917859de6b29452df0e6cc65b447e7ea86005f98d1794"
lifecycle_patch_sha256="13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220"
android_port_patch_sha256="33cc992445bc7f2c85c8b70e77b77b30b8cd02e6fda3720e69b10a40fd1a955a"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../../.." && pwd)"
contract="$repo_root/vendor/xrslam/profiles/xrslam_build_profiles.contract.json"
android_receipt="$repo_root/vendor/xrslam/profiles/android_pocketworld_hardened_generic.current.receipt.json"
android_artifact="$repo_root/android_ready/native/xrslam/libs/arm64-v8a/libxrslam_generic_4beb1a9.so"
android_port_patch="$repo_root/vendor/xrslam/patches/xrslam_android_official_semantics_build_route.patch"

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_hash() {
  actual="$(hash_file "$1")"
  if [ "$actual" != "$2" ]; then
    echo "hash mismatch: $1 expected=$2 actual=$actual" >&2
    exit 65
  fi
}

require_json_value() {
  actual="$(jq -r "$2" "$1")"
  if [ "$actual" != "$3" ]; then
    echo "contract mismatch: $1 query=$2 expected=$3 actual=$actual" >&2
    exit 65
  fi
}

verify_android_observation() {
  ndk_root="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-ndk}"
  readelf="$ndk_root/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
  test -x "$readelf"
  require_hash "$android_artifact" \
    "$(jq -r '.artifact_sha256' "$android_receipt")"
  "$readelf" -S "$android_artifact" | grep -Fq '.debug_info'
  require_json_value "$android_receipt" '.debug_info_present' 'true'
  require_json_value "$android_receipt" '.artifact_strip_status' 'not_stripped'
  require_json_value "$android_receipt" \
    '.recipe_strip_claim_matches_observed_artifact' 'false'
}

verify_contract() {
  command -v jq >/dev/null
  require_json_value "$contract" '.upstream_revision' "$xrslam_revision"
  require_json_value "$contract" '.upstream_tree' "$xrslam_tree"
  require_json_value "$contract" '.product_selection_change' 'false'
  require_json_value "$contract" \
    '.profiles.official_ios_semantics.xrslam_ios' 'true'
  require_json_value "$contract" \
    '.profiles.official_ios_semantics.threading' 'true'
  require_json_value "$contract" \
    '.profiles.official_ios_semantics.algorithm_change' 'false'
  require_json_value "$contract" \
    '.profiles.official_ios_semantics.camera_timestamp_offset_seconds' '0'
  require_json_value "$contract" \
    '.profiles.official_ios_semantics.calibration_policy' \
    'exact_machine_calibration_only'
  require_json_value "$contract" \
    '.profiles.official_ios_semantics.release_floating_point_flags | join(" ")' \
    '-O3 -ffast-math'
  require_json_value "$contract" \
    '.profiles.pocketworld_hardened_generic.algorithm_change' 'true'
  require_hash "$repo_root/android_ready/native/xrslam/patches/xrslam_generic_mobile.patch" \
    "$generic_patch_sha256"
  require_hash "$repo_root/vendor/xrslam/patches/xrslam_zero_inlier_mask.patch" \
    "$zero_patch_sha256"
  require_hash "$repo_root/vendor/xrslam/patches/xrslam_destroy_lifecycle.patch" \
    "$lifecycle_patch_sha256"
  require_hash "$android_port_patch" "$android_port_patch_sha256"
  verify_android_observation
  echo "XRSLAM_PROFILE_CONTRACT_VERIFIED revision=$xrslam_revision tree=$xrslam_tree"
}

new_work_root() {
  work_root="${PW_XRSLAM_PROFILE_WORK_ROOT:-}"
  case "$work_root" in
    /private/tmp/pw-xrslam-profile-*) ;;
    *)
      echo "PW_XRSLAM_PROFILE_WORK_ROOT must be a new /private/tmp/pw-xrslam-profile-* path" >&2
      exit 64
      ;;
  esac
  if [ -e "$work_root" ]; then
    echo "refusing to overwrite existing work root: $work_root" >&2
    exit 65
  fi
  mkdir -p "$work_root"
}

clone_exact_upstream() {
  source_root="$work_root/xrslam"
  git clone --filter=blob:none --no-checkout \
    https://github.com/openxrlab/xrslam.git "$source_root"
  git -C "$source_root" checkout --detach "$xrslam_revision"
  test "$(git -C "$source_root" rev-parse HEAD)" = "$xrslam_revision"
  test "$(git -C "$source_root" rev-parse 'HEAD^{tree}')" = "$xrslam_tree"
  test -z "$(git -C "$source_root" status --short)"
  source_manifest="$work_root/upstream-target-sources.manifest"
  git -C "$source_root" ls-tree -r --full-tree HEAD |
    awk '$4 ~ /^(xrslam|xrslam-extra|xrslam-interface)\// {print $3 "  " $4}' \
      > "$source_manifest"
  require_hash "$source_manifest" "$target_source_manifest_sha256"
  upstream_toolchain="$source_root/cmake/Modules/Platform/ios.toolchain.cmake"
  require_hash "$upstream_toolchain" "$ios_toolchain_sha256"
}

verify_pinned_dependency_checkouts() {
  deps_root="$1"
  test "$(git -C "$deps_root/depends-eigen-src" rev-parse HEAD)" = "$eigen_revision"
  test "$(git -C "$deps_root/depends-ceres-solver-src" rev-parse HEAD)" = "$ceres_revision"
  test "$(git -C "$deps_root/depends-spdlog-src" rev-parse HEAD)" = "$spdlog_revision"
  test "$(git -C "$deps_root/depends-yaml-cpp-src" rev-parse HEAD)" = "$yaml_revision"
}

prepare_local_dependency_sources() {
  dependency_source_root=""
  mirror_root="${PW_XRSLAM_LOCAL_DEP_MIRROR_ROOT:-}"
  if [ -z "$mirror_root" ]; then
    return
  fi
  dependency_source_root="$work_root/pinned-dependencies"
  mkdir -p "$dependency_source_root"
  for dependency in eigen ceres-solver spdlog yaml-cpp; do
    mirror="$mirror_root/depends-$dependency-src"
    test -d "$mirror/.git"
    destination="$dependency_source_root/depends-$dependency-src"
    git clone --local --no-checkout "$mirror" "$destination"
  done
  git -C "$dependency_source_root/depends-eigen-src" checkout --detach \
    "$eigen_revision"
  git -C "$dependency_source_root/depends-ceres-solver-src" checkout --detach \
    "$ceres_revision"
  git -C "$dependency_source_root/depends-spdlog-src" checkout --detach \
    "$spdlog_revision"
  git -C "$dependency_source_root/depends-yaml-cpp-src" checkout --detach \
    "$yaml_revision"
  verify_pinned_dependency_checkouts "$dependency_source_root"
}

archive_identity() {
  artifact="$1"
  member_root="$work_root/archive-members"
  member_manifest="$work_root/archive-members.sha256"
  member_order="$work_root/archive-member-order.txt"
  mkdir -p "$member_root"
  xcrun ar -t "$artifact" > "$member_order"
  (cd "$member_root" && xcrun ar -x "$artifact")
  : > "$member_manifest"
  while IFS= read -r member; do
    test -n "$member"
    test -f "$member_root/$member"
    printf '%s  %s\n' "$(hash_file "$member_root/$member")" "$member" \
      >> "$member_manifest"
  done < "$member_order"
  member_count="$(wc -l < "$member_order" | tr -d ' ')"
  unique_member_count="$(sort -u "$member_order" | wc -l | tr -d ' ')"
  test "$member_count" = "$unique_member_count"
  member_manifest_sha256="$(hash_file "$member_manifest")"
}

verify_ios_minos() {
  # Every archive member must carry LC_BUILD_VERSION for iOS with the same
  # deployment target written into the generated receipt.
  minos_manifest="$work_root/archive-member-build-versions.txt"
  : > "$minos_manifest"
  while IFS= read -r member; do
    build_output="$(xcrun vtool -show-build "$work_root/archive-members/$member")"
    platform="$(printf '%s\n' "$build_output" | awk '/platform / {print $2; exit}')"
    minos="$(printf '%s\n' "$build_output" | awk '/minos / {print $2; exit}')"
    sdk="$(printf '%s\n' "$build_output" | awk '/sdk / {print $2; exit}')"
    test "$platform" = "IOS"
    test "$minos" = "$minimum_ios"
    printf '%s  platform=%s minos=%s sdk=%s\n' \
      "$member" "$platform" "$minos" "$sdk" >> "$minos_manifest"
  done < "$work_root/archive-member-order.txt"
  minos_manifest_sha256="$(hash_file "$minos_manifest")"
}

build_ios_official() {
  verify_contract
  new_work_root
  clone_exact_upstream
  prepare_local_dependency_sources
  build_root="$work_root/build-ios"
  build_log="$work_root/build-ios.log"
  sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
  sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
  xcode_version="$(xcodebuild -version | tr '\n' ' ')"
  compiler_version="$(xcrun --sdk iphoneos clang++ --version | awk 'NR == 1')"

  set -- cmake -S "$source_root" -B "$build_root" -G Xcode \
    -DCMAKE_TOOLCHAIN_FILE="$source_root/cmake/Modules/Platform/ios.toolchain.cmake" \
    -DCMAKE_CONFIGURATION_TYPES=Release \
    -DIOS_PLATFORM=OS64 \
    -DIOS_ARCH=arm64 \
    -DIOS_DEPLOYMENT_TARGET="$minimum_ios" \
    -DENABLE_BITCODE=0 \
    -DENABLE_ARC=1 \
    -DENABLE_VISIBILITY=0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DXRSLAM_IOS=ON \
    -DXRSLAM_ENABLE_THREADING=ON
  if [ -n "$dependency_source_root" ]; then
    set -- "$@" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-EIGEN=$dependency_source_root/depends-eigen-src" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-CERES-SOLVER=$dependency_source_root/depends-ceres-solver-src" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-SPDLOG=$dependency_source_root/depends-spdlog-src" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-YAML-CPP=$dependency_source_root/depends-yaml-cpp-src"
  fi
  "$@"
  cmake --build "$build_root" --config Release --target xrslam --verbose \
    > "$build_log" 2>&1 || {
      cat "$build_log" >&2
      echo "XRSLAM_IOS_OFFICIAL_BUILD_BLOCKED log=$build_log" >&2
      exit 70
    }
  cat "$build_log"

  artifact="$source_root/lib/iOS/libxrslam.a"
  test -f "$artifact"
  grep -Fq -- '-ffast-math' "$build_log"
  grep -Fq -- '-O3' "$build_log"
  grep -Fq '#define XRSLAM_IOS' "$build_root/xrslam/include/xrslam/version.h"
  grep -Fq '#define XRSLAM_ENABLE_THREADING' \
    "$build_root/xrslam/include/xrslam/version.h"
  git -C "$source_root" diff --quiet --
  if [ -n "$dependency_source_root" ]; then
    verify_pinned_dependency_checkouts "$dependency_source_root"
  else
    verify_pinned_dependency_checkouts "$build_root/_deps"
  fi
  archive_identity "$artifact"
  verify_ios_minos

  artifact_sha256="$(hash_file "$artifact")"
  receipt="$work_root/source-faithful-official-ios-semantics.receipt.json"
  jq -n \
    --arg artifact "$artifact" \
    --arg artifact_sha256 "$artifact_sha256" \
    --arg archive_member_manifest "$member_manifest" \
    --arg archive_member_manifest_sha256 "$member_manifest_sha256" \
    --arg minos_manifest "$minos_manifest" \
    --arg minos_manifest_sha256 "$minos_manifest_sha256" \
    --arg upstream_revision "$xrslam_revision" \
    --arg upstream_tree "$xrslam_tree" \
    --arg target_source_manifest_sha256 "$target_source_manifest_sha256" \
    --arg minimum_ios "$minimum_ios" \
    --arg sdk_path "$sdk_path" \
    --arg sdk_version "$sdk_version" \
    --arg xcode_version "$xcode_version" \
    --arg compiler_version "$compiler_version" \
    --arg opencv_archive_md5 "35ebe10de1089f6b1e1cce04d822f740" \
    --arg ceres_revision "$ceres_revision" \
    --arg eigen_revision "$eigen_revision" \
    --arg spdlog_revision "$spdlog_revision" \
    --arg yaml_revision "$yaml_revision" \
    --argjson archive_member_count "$member_count" \
    '{
      schema: "pw.xrslam.source-faithful-official-ios-semantics-build/1",
      profile_id: "source-faithful-official-ios-semantics-4beb1a9",
      research_only: true,
      product_selected: false,
      artifact: $artifact,
      artifact_sha256: $artifact_sha256,
      archive_member_count: $archive_member_count,
      archive_member_manifest: $archive_member_manifest,
      archive_member_manifest_sha256: $archive_member_manifest_sha256,
      lc_build_version_manifest: $minos_manifest,
      lc_build_version_manifest_sha256: $minos_manifest_sha256,
      upstream_revision: $upstream_revision,
      upstream_tree: $upstream_tree,
      target_source_manifest_sha256: $target_source_manifest_sha256,
      source_patches: [],
      algorithm_change: false,
      xrslam_ios: true,
      threading: true,
      release_floating_point_flags: ["-O3", "-ffast-math"],
      minimum_ios: $minimum_ios,
      sdk_path: $sdk_path,
      sdk_version: $sdk_version,
      xcode_version: $xcode_version,
      compiler_version: $compiler_version,
      dependencies: {
        opencv_ios_framework_archive_md5: $opencv_archive_md5,
        ceres_revision: $ceres_revision,
        eigen_revision: $eigen_revision,
        spdlog_revision: $spdlog_revision,
        yaml_cpp_revision: $yaml_revision
      },
      camera_timestamp_offset_seconds: 0,
      calibration_policy: "exact_machine_calibration_only"
    }' > "$receipt"
  echo "XRSLAM_IOS_OFFICIAL_PROFILE_BUILT artifact=$artifact sha256=$artifact_sha256"
  echo "receipt=$receipt sha256=$(hash_file "$receipt")"
}

probe_android_official_semantics() {
  verify_contract
  new_work_root
  clone_exact_upstream
  prepare_local_dependency_sources
  require_hash "$android_port_patch" "$android_port_patch_sha256"
  git -C "$source_root" apply "$android_port_patch"
  changed_paths="$(git -C "$source_root" diff --name-only)"
  expected_changed_paths="CMakeLists.txt
xrslam-interface/CMakeLists.txt"
  test "$changed_paths" = "$expected_changed_paths"

  opencv_dir="${PW_XRSLAM_ANDROID_OPENCV_DIR:-}"
  if [ -z "$opencv_dir" ] || [ ! -f "$opencv_dir/OpenCVConfig-version.cmake" ]; then
    echo "XRSLAM_ANDROID_OFFICIAL_SEMANTICS_BUILD_BLOCKED" >&2
    echo "missing exact OpenCV 4.0.1 Android CMake package; set PW_XRSLAM_ANDROID_OPENCV_DIR" >&2
    exit 69
  fi
  opencv_version="$(awk '/set\(OpenCV_VERSION / {gsub(/[()]/, "", $2); print $2; exit}' \
    "$opencv_dir/OpenCVConfig-version.cmake")"
  if [ "$opencv_version" != "4.0.1" ]; then
    echo "XRSLAM_ANDROID_OFFICIAL_SEMANTICS_BUILD_BLOCKED" >&2
    echo "OpenCV package version must be 4.0.1, observed=$opencv_version path=$opencv_dir" >&2
    exit 69
  fi

  ndk_root="${ANDROID_NDK_ROOT:-/opt/homebrew/share/android-ndk}"
  ndk_bin="$ndk_root/toolchains/llvm/prebuilt/darwin-x86_64/bin"
  build_root="$work_root/build-android-official-semantics"
  build_log="$work_root/build-android-official-semantics.log"
  source_date_epoch="1700000000"
  official_release_flags="-O3 -DNDEBUG -ffast-math"
  export SOURCE_DATE_EPOCH="$source_date_epoch"
  set -- cmake -S "$source_root" -B "$build_root" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ndk_root/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-24 \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DXRSLAM_ANDROID_OFFICIAL_IOS_SEMANTICS=ON \
    -DXRSLAM_IOS=ON \
    -DXRSLAM_ENABLE_THREADING=ON \
    -DXRSLAM_TEST=OFF \
    -DOpenCV_DIR="$opencv_dir" \
    "-DCMAKE_C_FLAGS_RELEASE=$official_release_flags" \
    "-DCMAKE_CXX_FLAGS_RELEASE=$official_release_flags" \
    -DSUITESPARSE=OFF \
    -DCXSPARSE=OFF \
    -DLAPACK=OFF \
    -DACCELERATESPARSE=OFF
  if [ -n "$dependency_source_root" ]; then
    set -- "$@" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-EIGEN=$dependency_source_root/depends-eigen-src" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-CERES-SOLVER=$dependency_source_root/depends-ceres-solver-src" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-SPDLOG=$dependency_source_root/depends-spdlog-src" \
      "-DFETCHCONTENT_SOURCE_DIR_DEPENDS-YAML-CPP=$dependency_source_root/depends-yaml-cpp-src"
  fi
  "$@"
  cmake --build "$build_root" --parallel 12 --target xrslam --verbose \
    > "$build_log" 2>&1 || {
      cat "$build_log" >&2
      echo "XRSLAM_ANDROID_OFFICIAL_SEMANTICS_BUILD_BLOCKED log=$build_log" >&2
      exit 70
    }

  artifact="$source_root/lib/libxrslam.so"
  test -f "$artifact"
  grep -Fq '#define XRSLAM_IOS' "$build_root/xrslam/include/xrslam/version.h"
  grep -Fq '#define XRSLAM_ENABLE_THREADING' \
    "$build_root/xrslam/include/xrslam/version.h"
  grep -Fq -- '-ffast-math' "$build_log"
  grep -Fq -- '-O3' "$build_log"
  "$ndk_bin/llvm-nm" -D --defined-only "$artifact" | grep -Eq ' XRSLAMCreate$'

  opencv_manifest="$work_root/opencv-android-package.manifest"
  : > "$opencv_manifest"
  find "$opencv_dir" -type f -print | LC_ALL=C sort |
    while IFS= read -r file; do
      relative="${file#"$opencv_dir"/}"
      printf '%s  %s\n' "$(hash_file "$file")" "$relative"
    done > "$opencv_manifest"
  opencv_manifest_sha256="$(hash_file "$opencv_manifest")"
  artifact_sha256="$(hash_file "$artifact")"
  build_id="$($ndk_bin/llvm-readelf -n "$artifact" |
    awk '/Build ID:/ {print $3; exit}')"
  receipt="$work_root/android-official-ios-semantics-port.receipt.json"
  jq -n \
    --arg artifact "$artifact" \
    --arg artifact_sha256 "$artifact_sha256" \
    --arg build_id "$build_id" \
    --arg upstream_revision "$xrslam_revision" \
    --arg upstream_tree "$xrslam_tree" \
    --arg target_source_manifest_sha256 "$target_source_manifest_sha256" \
    --arg build_route_patch_sha256 "$android_port_patch_sha256" \
    --arg opencv_version "$opencv_version" \
    --arg opencv_manifest_sha256 "$opencv_manifest_sha256" \
    --arg ceres_revision "$ceres_revision" \
    --arg eigen_revision "$eigen_revision" \
    --arg spdlog_revision "$spdlog_revision" \
    --arg yaml_revision "$yaml_revision" \
    --arg ndk_revision "$(awk -F' = ' '/^Pkg.Revision/ {print $2}' "$ndk_root/source.properties")" \
    '{
      schema: "pw.xrslam.android-official-ios-semantics-port-build/1",
      classification: "cross_platform_port_candidate",
      official_android_sample: false,
      research_only: true,
      product_selected: false,
      artifact: $artifact,
      artifact_sha256: $artifact_sha256,
      elf_build_id_sha1: $build_id,
      upstream_revision: $upstream_revision,
      upstream_tree: $upstream_tree,
      target_source_manifest_sha256: $target_source_manifest_sha256,
      algorithm_source_patches: [],
      build_route_patch_sha256: $build_route_patch_sha256,
      algorithm_change: false,
      xrslam_ios: true,
      threading: true,
      release_floating_point_flags: ["-O3", "-ffast-math"],
      android_abi: "arm64-v8a",
      android_api: 24,
      android_ndk_revision: $ndk_revision,
      dependencies: {
        opencv_version: $opencv_version,
        opencv_package_manifest_sha256: $opencv_manifest_sha256,
        ceres_revision: $ceres_revision,
        eigen_revision: $eigen_revision,
        spdlog_revision: $spdlog_revision,
        yaml_cpp_revision: $yaml_revision
      }
    }' > "$receipt"
  echo "XRSLAM_ANDROID_OFFICIAL_SEMANTICS_PORT_BUILT artifact=$artifact sha256=$artifact_sha256"
  echo "receipt=$receipt sha256=$(hash_file "$receipt")"
}

case "${1:-}" in
  --verify-contract)
    verify_contract
    ;;
  --build-ios-official)
    build_ios_official
    ;;
  --probe-android-official-semantics)
    probe_android_official_semantics
    ;;
  *)
    echo "usage: $0 --verify-contract|--build-ios-official|--probe-android-official-semantics" >&2
    exit 64
    ;;
esac
