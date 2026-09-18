#!/bin/sh
#
# build_ios_generic.sh —— 出货 iOS 引擎 libxrslam_generic_4beb1a9.a 的可复现构建。
#
# ── 为什么有这个文件 ────────────────────────────────────────────────────────
# 2026-09-18 查清:Android 侧有 build_generic_core.sh(工具链/源码/patch/产物
# 四层 sha256 断言、SOURCE_DATE_EPOCH 固定、逐位可重放),**iOS 侧什么都没有**。
# 出货 .a 的 receipt 里记着 `build_commands_sha256=41c21b74…`,但那个命令文件
# 在整台机器上已经找不到 —— 也就是说出货血统**当时就不可复现**,而这已经咬过
# 一次(PWOfficialSfm 同类问题)。没有它,任何引擎侧改动都上不了 iOS。
#
# 本脚本按 receipt 的规格重建该流程。**结构逐段抄 Android 那份**(同仓
# android_ready/native/xrslam/build_generic_core.sh),只改平台相关的部分。
#
# ── iOS 相对 Android 的三处实质差别 ────────────────────────────────────────
# ① 产物是 **ar 归档**(.a),不是链接产物(.so)⇒ 归档头里有时间戳/uid/gid,
#    每次构建都不同。现有出货 .a 实测带着 `Aug 28 11:58 2026`、uid 501,
#    说明当时**没有**处理过 —— 这正是它的 artifact_sha256 不可重放的原因。
#    修法:`ZERO_AR_DATE=1`(Apple libtool/ld64 认这个环境变量,把归档时间戳
#    写成 0)。出处:reproducible-builds.org/docs/archives/、LLVM 官方博客
#    "Deterministic builds with clang and lld"。
#    Android 那份没有这一条,是因为 .so 里根本没有 ar 归档头。
# ② OpenCV **不从源码编**,用钉死的预编译 framework(receipt 只记
#    `opencv_headers_revision`,归档里也确实没有任何 opencv 的 .o)。
# ③ 不打 Android 的 `xrslam_generic_mobile.patch`(receipt 只声明了两个 patch:
#    lifecycle + zero_inlier_mask)⇒ 不走 XRSLAM_CROSS_PLATFORM_GENERIC。
#
# ══ 🔴🔴 2026-09-18 实跑得到的结论:出货 .a **无法从它自己的 receipt 重建** ══
#
# 四轮实跑,三条独立证据指向同一件事:那份 .a 是从一棵**我们已经没有的源码树**
# 编出来的,receipt 里声明的输入不足以复现它。
#
#  证据一:`build_commands_sha256=41c21b74…` 指向的命令文件,仓内外全机扫过,
#          **不存在**。
#
#  证据二:`declared_source_diff_sha256=c6d8267…` 对不上。
#          在干净 4beb1a9 上只打两个声明 patch 后:
#            git diff 的 sha256      = 4b228e9fa0037960d14b3c7fc543bcb4be85d2539…
#            两个 patch 文件拼接 sha  = 3a74cf2320b883133c724a8d359dde7c3fbf9b91…
#          两种口径都不是 c6d8267…。
#
#  证据三(最硬):receipt 自己声明的组合在干净 4beb1a9 上**自相矛盾**。
#          上游 CMakeLists.txt:17-27 有两段互斥的强制:
#              if(IOS)      set(XRSLAM_IOS ON); set(XRSLAM_ENABLE_THREADING ON)
#              if(NOT IOS)  set(XRSLAM_PC ON)      # ⇒ 拉入 argparse / liteviz
#          于是:
#            IOS 为真 ⇒ xrslam_ios / threading 被强开,与 receipt 的 False 矛盾;
#            IOS 为假 ⇒ XRSLAM_PC 被强开,需要 argparse / liteviz,
#                       而 receipt 的依赖清单里**这两个都没有**。
#          两条路都无法同时满足 receipt。⇒ 那棵树的 CMakeLists 必定被改过,
#          而那个改动**没有被声明**。
#
# ⇒ 本脚本**做不到**"重建出与出货 .a 逐成员一致的产物"。它能做到的是:
#    ① --verify-only:把现有出货 .a 钉住(工具链/patch/成员清单/ABI 五函数),
#      这一半已经实跑通过,防止它再被悄悄换掉;
#    ② --rebuild:在干净 4beb1a9 上建立一条**新的、可复现的**基线 —— 但那需要
#      再声明一个 CMakeLists patch(中和上面那段 force-on),
#      且产物**不会**与出货 .a 逐位相同,要靠台架行为对照来判等价。
#    🔴 ②是产品决定不是技术决定:等于换一次引擎基线。未经点头不要做。
#
# ── 验收判据(可执行,不是口号)──────────────────────────────────────────
# receipt 里的 `archive_member_manifest_sha256` 是**逐成员内容哈希、按归档顺序**
# 的清单哈希,格式 `archive-order: sha256-two-spaces-member-newline`。
# 它绕开了 ar 归档头的时间戳,所以**即使 artifact_sha256 对不上,内容是否一致
# 仍然可判**。本脚本的 manifest 算法已用现有出货 .a 验证过,逐位复现
# 9f4a1a98032dc376d77547f54903c33f0fe8cc62ab5d3f5e85534480e285b013。
#
# 用法:
#   ./build_ios_generic.sh                 # 等同 --verify-only
#   ./build_ios_generic.sh --verify-only   # 只校验现有产物与钉死输入
#   ./build_ios_generic.sh --manifest      # 打印现有产物的成员清单
#   PW_XRSLAM_IOS_WORK_ROOT=/private/tmp/pw-xrslam-ios-rebuild-<tag> \
#     ./build_ios_generic.sh --rebuild     # 全量重建

set -eu

# ── 钉死的输入(全部取自 libxrslam_generic_4beb1a9.receipt.json)────────────
xrslam_revision="4beb1a942f33da9afbfae2d70e2c641cfc2bb675"
ceres_revision="e809cf0c2879f521078b4c9e6329390b42ecf722"
eigen_ref="3.3.7"
eigen_revision="cf794d3b741a6278df169e58461f8529f43bce5d"
spdlog_ref="v1.3.1"
spdlog_revision="a7148b718ea2fabb8387cb90aee9bf448da63e65"
yaml_ref="yaml-cpp-0.7.0"
yaml_revision="0579ae3d976091d7d664aa9d2527e0d0cff25763"
opencv_version="4.0.1"
opencv_headers_revision="c9ad5779f2803dcc91a9938142209128d30b22d1"
# 上游 cmake/external/ios/opencv.cmake 自己声明的 URL_MD5,本地包已逐位核过。
opencv_zip_md5="35ebe10de1089f6b1e1cce04d822f740"

expected_clang_version="Apple clang version 17.0.0 (clang-1700.6.3.2)"
minimum_ios="14.0"
source_date_epoch="1700000000"
# Android 那份钉的也是这个版本,两端保持一致。
expected_ninja_version="1.13.2"

lifecycle_patch_sha256="13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220"
zero_inlier_mask_patch_sha256="62b12204c647e445e88917859de6b29452df0e6cc65b447e7ea86005f98d1794"

expected_artifact_sha256="fdc75c99358014d9485bea36667547825465a85562847548d02a582da38c8011"
expected_member_manifest_sha256="9f4a1a98032dc376d77547f54903c33f0fe8cc62ab5d3f5e85534480e285b013"
expected_member_count="55"

# receipt: exported_abi
expected_abi="XRSLAMCreate XRSLAMDestroy XRSLAMGetResult XRSLAMPushSensorData XRSLAMRunOneFrame"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
patch_dir="$script_dir/patches"
artifact="$script_dir/libs/ios-arm64/libxrslam_generic_4beb1a9.a"
deps_tarballs="${PW_XRSLAM_DEPS_TARBALLS:-$HOME/Developer/xrslam-deps-tarballs}"

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }

require_hash() {
  path="$1"; expected="$2"
  actual="$(hash_file "$path")"
  if [ "$actual" != "$expected" ]; then
    echo "hash mismatch: $path expected=$expected actual=$actual" >&2
    exit 65
  fi
}

verify_toolchain() {
  actual_clang="$(clang --version | head -1)"
  if [ "$actual_clang" != "$expected_clang_version" ]; then
    echo "clang mismatch: expected='$expected_clang_version' actual='$actual_clang'" >&2
    echo "🔴 编译器漂了就别指望复现 —— 先把 Xcode 切回对应版本。" >&2
    exit 65
  fi
  command -v libtool >/dev/null
  command -v xcrun >/dev/null
  actual_ninja="$(ninja --version)"
  if [ "$actual_ninja" != "$expected_ninja_version" ]; then
    echo "ninja mismatch: expected=$expected_ninja_version actual=$actual_ninja" >&2
    exit 65
  fi
}

# 逐成员内容哈希、按归档顺序。格式与 receipt 的
# `archive-order: sha256-two-spaces-member-newline` 一致(已对现有产物验证)。
member_manifest() {
  a="$1"
  tmp="$(mktemp -d)"
  ( cd "$tmp" && ar -x "$a" )
  ar -t "$a" | while IFS= read -r m; do
    if [ -f "$tmp/$m" ]; then
      printf '%s  %s\n' "$(hash_file "$tmp/$m")" "$m"
    fi
  done
  rm -rf "$tmp"
}

verify_artifact() {
  a="$1"
  count="$(ar -t "$a" | wc -l | tr -d ' ')"
  if [ "$count" != "$expected_member_count" ]; then
    echo "member count mismatch: expected=$expected_member_count actual=$count" >&2
    exit 66
  fi
  mf="$(mktemp)"
  member_manifest "$a" > "$mf"
  actual_manifest="$(hash_file "$mf")"
  rm -f "$mf"
  if [ "$actual_manifest" != "$expected_member_manifest_sha256" ]; then
    echo "member manifest mismatch:" >&2
    echo "  expected=$expected_member_manifest_sha256" >&2
    echo "  actual  =$actual_manifest" >&2
    exit 66
  fi
  # 五函数官方 ABI 必须都在,且是定义而非未定义引用。
  for sym in $expected_abi; do
    if ! nm -g --defined-only "$a" 2>/dev/null | grep -Eq "_$sym$"; then
      echo "missing exported symbol: $sym" >&2
      exit 67
    fi
  done
  echo "  member_count=$count manifest=$actual_manifest ABI=ok"
}

verify_pinned_inputs() {
  verify_toolchain
  require_hash "$patch_dir/xrslam_destroy_lifecycle.patch" "$lifecycle_patch_sha256"
  require_hash "$patch_dir/xrslam_zero_inlier_mask.patch" "$zero_inlier_mask_patch_sha256"
  require_hash "$artifact" "$expected_artifact_sha256"
  verify_artifact "$artifact"
}

case "${1:---verify-only}" in
  --manifest)
    member_manifest "$artifact"
    exit 0
    ;;
  --verify-only)
    verify_pinned_inputs
    echo "XRSLAM_IOS_GENERIC_VERIFIED sha256=$expected_artifact_sha256"
    exit 0
    ;;
  --rebuild) ;;
  *)
    echo "usage: $0 [--verify-only|--manifest|--rebuild]" >&2
    exit 64
    ;;
esac

# ── 重建 ────────────────────────────────────────────────────────────────────
verify_toolchain
require_hash "$patch_dir/xrslam_destroy_lifecycle.patch" "$lifecycle_patch_sha256"
require_hash "$patch_dir/xrslam_zero_inlier_mask.patch" "$zero_inlier_mask_patch_sha256"

work_root="${PW_XRSLAM_IOS_WORK_ROOT:-}"
case "$work_root" in
  /private/tmp/pw-xrslam-ios-rebuild-*) ;;
  *)
    echo "PW_XRSLAM_IOS_WORK_ROOT must be a new /private/tmp/pw-xrslam-ios-rebuild-* path" >&2
    exit 64
    ;;
esac
if [ -e "$work_root" ]; then
  echo "refusing to overwrite existing work root: $work_root" >&2
  exit 65
fi

test -d "$deps_tarballs/opencv-$opencv_version-ios-framework/opencv2.framework" || {
  echo "missing pinned OpenCV framework under $deps_tarballs" >&2
  exit 65
}

mkdir -p "$work_root"
xrslam_source="$work_root/xrslam"
xrslam_build="$work_root/xrslam-build"
deps_root="$xrslam_build/_deps"

git clone --filter=blob:none --no-checkout \
  https://github.com/openxrlab/xrslam.git "$xrslam_source"
git -C "$xrslam_source" checkout --detach "$xrslam_revision"
test "$(git -C "$xrslam_source" rev-parse HEAD)" = "$xrslam_revision"
# 🔴 receipt: source_tree_clean_before_declared_patches=true —— 打 patch 前必须干净
test -z "$(git -C "$xrslam_source" status --porcelain)"
git -C "$xrslam_source" apply "$patch_dir/xrslam_destroy_lifecycle.patch"
git -C "$xrslam_source" apply "$patch_dir/xrslam_zero_inlier_mask.patch"

mkdir -p "$deps_root"
clone_pinned() {
  url="$1"; dst="$2"; rev="$3"
  git clone --filter=blob:none --no-checkout "$url" "$dst"
  git -C "$dst" checkout --detach "$rev"
  test "$(git -C "$dst" rev-parse HEAD)" = "$rev"
}
clone_pinned https://github.com/eigenteam/eigen-git-mirror.git \
  "$deps_root/depends-eigen-src" "$eigen_revision"
clone_pinned https://github.com/gabime/spdlog.git \
  "$deps_root/depends-spdlog-src" "$spdlog_revision"
clone_pinned https://github.com/ceres-solver/ceres-solver.git \
  "$deps_root/depends-ceres-solver-src" "$ceres_revision"
clone_pinned https://github.com/jbeder/yaml-cpp.git \
  "$deps_root/depends-yaml-cpp-src" "$yaml_revision"

# 🔴 OpenCV 走的是同一个 SuperBuildDepends 约定:上游
# cmake/external/ios/opencv.cmake 只做 FetchContent + file(COPY ...) —— 它要的是
# **解压后的 framework 内容**落在 _deps/depends-opencv-src。
# FetchContent 对单顶层目录的压缩包会剥掉那一层,所以这里放的是
# opencv2.framework 的**内容**(Headers/Resources/Versions/…),不是它本身。
opencv_zip="$deps_tarballs/opencv-$opencv_version-ios-framework.zip"
test -f "$opencv_zip" || { echo "missing $opencv_zip" >&2; exit 65; }
actual_md5="$(md5 -q "$opencv_zip")"
test "$actual_md5" = "$opencv_zip_md5" || {
  echo "opencv zip md5 mismatch: expected=$opencv_zip_md5 actual=$actual_md5" >&2
  exit 65
}
unzip -q "$opencv_zip" -d "$work_root/opencv-unzip"
mkdir -p "$deps_root/depends-opencv-src"
( cd "$work_root/opencv-unzip/opencv2.framework" && tar cf - . ) |
  ( cd "$deps_root/depends-opencv-src" && tar xf - )

# receipt: compile_flags。-ffp-contract=off / -fno-fast-math 与 Android 同口径
# (设备端 FMA 收缩会让同一份源码算出不同的数,我们在稠密线上为此栽过)。
deterministic_c_flags="-O3 -DNDEBUG -ffp-contract=off -fno-fast-math -ffile-prefix-map=$work_root=/pwbuild -fdebug-prefix-map=$work_root=/pwbuild"
deterministic_cxx_flags="$deterministic_c_flags -fchar8_t -Dceres=pw_xrslam_ceres_1_14"
export SOURCE_DATE_EPOCH="$source_date_epoch"
# 🔴 iOS 专有:把 ar 归档头里的时间戳写成 0。见文件头 ①。
export ZERO_AR_DATE=1

# 🔴 用**上游自己的** iOS 工具链文件与变量名,不要手写 CMAKE_SYSTEM_NAME。
# 实测:手写 CMAKE_OSX_DEPLOYMENT_TARGET 时 ceres 1.14 的 CMakeLists:196 直接报
#   "Unsupported iOS version: , Ceres requires at least iOS version 7.0"
# —— 它读的是 IOS_DEPLOYMENT_TARGET / IOS_PLATFORM(那套 ios.toolchain.cmake 的
# 变量),CMAKE_OSX_* 它根本不看。上游 build-ios.sh 传的就是下面这组,照抄;
# 只把版本从上游的 12.0 换成 receipt 钉的 $minimum_ios。
# ══ 🔴 关键:**不要**用 CMake 的 iOS 平台支持 ═════════════════════════════
# 上游 CMakeLists.txt:18-21 有一段:
#     if(IOS)
#       set(XRSLAM_IOS ON)
#       set(XRSLAM_ENABLE_THREADING ON)
#     endif()
# 它会**覆盖**命令行传进来的 -DXRSLAM_IOS=OFF / -DXRSLAM_ENABLE_THREADING=OFF。
# 而 `IOS` 这个变量,无论用 ios.toolchain.cmake 还是 CMAKE_SYSTEM_NAME=iOS,
# 都会被置真 ⇒ 两条路都会把出货档的两个开关强行打开,与 receipt
# (xrslam_ios=False / threading=False)矛盾。
#
# receipt 的 compile_flags 才是答案:里面有 `-arch arm64` 与
# `-miphoneos-version-min=14.0` —— 这是**手工指定 iOS 目标**的写法,
# 说明出货构建根本没走 CMake 的 iOS 平台支持。这样:
#   * IOS 不置真 ⇒ 那段 force-on 不触发 ⇒ 两个开关保持 OFF ✅
#   * xrslam-ios 子目录不被 add ⇒ 不需要 Swift 编译器(Ninja 生成器下配不出来)✅
#   * ceres 1.14 不走它的 iOS 分支 ⇒ 不再要 IOS_DEPLOYMENT_TARGET ✅
# 一个根因解释了三次配置失败。
ios_sysroot="$(xcrun --sdk iphoneos --show-sdk-path)"
ios_target_flags="-arch arm64 -miphoneos-version-min=$minimum_ios -fvisibility=hidden -fvisibility-inlines-hidden"
deterministic_c_flags="$deterministic_c_flags $ios_target_flags"
deterministic_cxx_flags="$deterministic_cxx_flags $ios_target_flags -std=gnu++17"

cmake -S "$xrslam_source" -B "$xrslam_build" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
  -DCMAKE_OSX_SYSROOT="$ios_sysroot" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DXRSLAM_IOS=OFF \
  -DXRSLAM_ENABLE_THREADING=OFF \
  -DXRSLAM_ENABLE_DEBUG_INSPECTION=ON \
  -DXRSLAM_TEST=OFF \
  -DXRSLAM_DEBUG=OFF \
  -DXRSLAM_PC_HEADLESS_ONLY=ON \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  "-DCMAKE_C_FLAGS_RELEASE=$deterministic_c_flags" \
  "-DCMAKE_CXX_FLAGS_RELEASE=$deterministic_cxx_flags" \
  -DSUITESPARSE=OFF -DCXSPARSE=OFF -DLAPACK=OFF -DACCELERATESPARSE=OFF \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON

cmake --build "$xrslam_build" --parallel 12 --target \
  xrslam-core xrslam-extra xrslam-interface yaml-cpp

# ── 合并成出货归档 ──────────────────────────────────────────────────────────
# 顺序必须与 receipt 的成员清单一致:interface → extra → core → yaml-cpp。
# (现有产物实测 55 个成员:2-3 interface / 4-6 extra / 7-26 core / 27-55 yaml)
merged="$work_root/libxrslam_generic_4beb1a9.a"
find_lib() {
  found="$(find "$xrslam_build" -name "$1" -type f | head -1)"
  test -n "$found" || { echo "not built: $1" >&2; exit 70; }
  echo "$found"
}
xcrun libtool -static -D -o "$merged" \
  "$(find_lib libxrslam-interface.a)" \
  "$(find_lib libxrslam-extra.a)" \
  "$(find_lib libxrslam-core.a)" \
  "$(find_lib libyaml-cpp.a)"

rebuilt_sha256="$(hash_file "$merged")"
mf="$work_root/member-manifest.txt"
member_manifest "$merged" > "$mf"
rebuilt_manifest="$(hash_file "$mf")"

run_receipt="$work_root/rebuild-run.receipt"
{
  echo "schema=pw.xrslam.ios-generic-rebuild-run/1"
  echo "script_sha256=$(hash_file "$0")"
  echo "xrslam_revision=$(git -C "$xrslam_source" rev-parse HEAD)"
  echo "eigen_revision=$(git -C "$deps_root/depends-eigen-src" rev-parse HEAD)"
  echo "spdlog_revision=$(git -C "$deps_root/depends-spdlog-src" rev-parse HEAD)"
  echo "ceres_revision=$(git -C "$deps_root/depends-ceres-solver-src" rev-parse HEAD)"
  echo "yaml_revision=$(git -C "$deps_root/depends-yaml-cpp-src" rev-parse HEAD)"
  echo "opencv_version=$opencv_version"
  echo "opencv_headers_revision=$opencv_headers_revision"
  echo "clang_version=$expected_clang_version"
  echo "source_date_epoch=$source_date_epoch"
  echo "zero_ar_date=1"
  echo "lifecycle_patch_sha256=$(hash_file "$patch_dir/xrslam_destroy_lifecycle.patch")"
  echo "zero_inlier_mask_patch_sha256=$(hash_file "$patch_dir/xrslam_zero_inlier_mask.patch")"
  echo "artifact_sha256=$rebuilt_sha256"
  echo "archive_member_manifest_sha256=$rebuilt_manifest"
} > "$run_receipt"

echo "XRSLAM_IOS_GENERIC_REBUILT path=$merged"
echo "  artifact_sha256  = $rebuilt_sha256"
echo "  manifest_sha256  = $rebuilt_manifest"
echo "  shipping manifest= $expected_member_manifest_sha256"
echo "  run_receipt=$run_receipt"
if [ "$rebuilt_manifest" = "$expected_member_manifest_sha256" ]; then
  echo "XRSLAM_IOS_GENERIC_REBUILD_REPRODUCED ✅ 与出货产物**内容逐成员一致**"
else
  echo "XRSLAM_IOS_GENERIC_REBUILD_DIVERGED 🔴 内容与出货产物不一致 —— 先查清差异再谈打 patch" >&2
  echo "  对照:diff <($0 --manifest) $mf" >&2
  exit 71
fi
