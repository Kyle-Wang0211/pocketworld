#!/bin/sh
#
# build_ios_generic.sh —— 出货 iOS 引擎 libxrslam_generic_4beb1a9.a 的重建 + 校验。
#
# ══ 🔴 这份脚本是**抄**出来的,不是我推出来的 ═══════════════════════════════
# 配置参数逐行抄 `~/Developer/viobench-build/gpufe/configure_engine.sh`,
# 归档与校验步骤抄同目录的 `assemble_and_build.sh`。那两份是 2026-09-09 的
# 前序工作,头注释写着该守的纪律:
#     "Every option here is recovered from libxrslam_gpufe_4beb1a9.receipt.json
#      (compile_flags, threading, xrslam_ios, ceres_namespace, gpu_frontend)
#      - not guessed."
# 本文件只做一件不同的事:那两份编的是 **gpufe 研究臂**,这份编 **generic 出货臂**
# (无 GPU 前端、threading OFF、归档里不含 localization)。
#
# ══ 🔴 判据是**行为门**,不是逐字节 ═════════════════════════════════════════
# 逐字节复现**已经试过并且失败过**,结论就写在 gpufe 那份 receipt 里
# (assemble_and_build.sh 写入的 rebuild_note_zh):
#     "磁盘清理删掉了构建树后按回执参数重建。相对 09-05 那版,**未改动的成员
#      不是逐字节相同**:差异是同语义的寄存器分配与栈溢出选择(指令序列等价),
#      **编译器与 SDK 版本均未变,原因未定位**。因此本次判据改为**行为门**:
#      真机回放 AUDIT=1 的 CLAHE/检测逐位审计 + ATE 落在基线带内。"
# ⇒ 不要再去追 artifact_sha256 / archive_member_manifest_sha256 的复现,
#   那个目标已知达不到。--rebuild 出来的产物**必然**与出货 .a 不同,
#   这是**预期**,不是失败。能不能替换出货件,由行为门判(见 --gate-help)。
#
# ══ 仍然值得保留的一半:把现有出货件钉死 ═══════════════════════════════════
# --verify-only 与重建无关,它防的是出货 .a 被悄悄换掉:校验工具链、两个声明
# patch、artifact sha、55 成员清单、五函数 ABI。这一半实跑通过,继续保留。
#
# 用法:
#   ./build_ios_generic.sh                 # = --verify-only
#   ./build_ios_generic.sh --manifest      # 打印现有出货件的成员清单
#   ./build_ios_generic.sh --gate-help     # 打印行为门该怎么跑
#   PW_XRSLAM_IOS_WORK_ROOT=/private/tmp/pw-xrslam-ios-rebuild-<tag> \
#     ./build_ios_generic.sh --rebuild     # 重建到暂存路径(**不覆盖**出货件)

set -eu

xrslam_revision="4beb1a942f33da9afbfae2d70e2c641cfc2bb675"
eigen_dir_name="eigen-3.3.7"
opencv_version="4.0.1"
minimum_ios="14.0"
source_date_epoch="1700000000"
expected_clang_version="Apple clang version 17.0.0 (clang-1700.6.3.2)"
expected_ninja_version="1.13.2"

lifecycle_patch_sha256="13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220"
zero_inlier_mask_patch_sha256="62b12204c647e445e88917859de6b29452df0e6cc65b447e7ea86005f98d1794"
# 🔴 第三个 patch:**新基线专有**,出货 .a 里没有它。
# 把上游 `if(IOS)` 里写死的两个开关解耦成 XRSLAM_IOS_OVERRIDE /
# XRSLAM_THREADING_OVERRIDE。**变量名与做法抄我们自己的台架树**
# (~/Developer/xrslam-4beb1a9-thr,2026-08-31 那处解耦),两棵树保持一致。
# 只在调用方显式 define 时生效 ⇒ 默认与未打 patch 等价(阴性对照)。
# 生产 generic 档必须从**干净 4beb1a9** 出发(台架树有 27 个文件改动、含算法),
# 所以不能直接用台架树,只能把那处解耦作为 patch 带过来。
override_patch_sha256="ed0a82a308f6b39e147f62f7a95da5a1dcc33eeedc6a6685076aa99063c5a8e6"

expected_artifact_sha256="fdc75c99358014d9485bea36667547825465a85562847548d02a582da38c8011"
expected_member_manifest_sha256="9f4a1a98032dc376d77547f54903c33f0fe8cc62ab5d3f5e85534480e285b013"
expected_member_count="55"
expected_abi="XRSLAMCreate XRSLAMDestroy XRSLAMGetResult XRSLAMPushSensorData XRSLAMRunOneFrame"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
patch_dir="$script_dir/patches"
artifact="$script_dir/libs/ios-arm64/libxrslam_generic_4beb1a9.a"
deps="${PW_XRSLAM_DEPS_TARBALLS:-$HOME/Developer/xrslam-deps-tarballs}"

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }

require_hash() {
  actual="$(hash_file "$1")"
  [ "$actual" = "$2" ] || { echo "hash mismatch: $1 expected=$2 actual=$actual" >&2; exit 65; }
}

verify_toolchain() {
  actual_clang="$(clang --version | head -1)"
  [ "$actual_clang" = "$expected_clang_version" ] || {
    echo "clang mismatch: expected='$expected_clang_version' actual='$actual_clang'" >&2; exit 65; }
  actual_ninja="$(ninja --version)"
  [ "$actual_ninja" = "$expected_ninja_version" ] || {
    echo "ninja mismatch: expected=$expected_ninja_version actual=$actual_ninja" >&2; exit 65; }
  command -v xcrun >/dev/null
}

member_manifest() {
  tmp="$(mktemp -d)"
  ( cd "$tmp" && ar -x "$1" )
  ar -t "$1" | while IFS= read -r m; do
    [ -f "$tmp/$m" ] && printf '%s  %s\n' "$(hash_file "$tmp/$m")" "$m"
  done
  rm -rf "$tmp"
}

# 🔴 绝不用 `nm | grep -q`:grep 命中即退出,nm 收到 SIGPIPE,pipefail 下会把
# **成功的检查**报成失败。这条教训写在 assemble_and_build.sh 里:
# "09-09 赔掉一个重建周期,09-04 赔掉一个归档"。
check_abi() {
  syms="$(mktemp)"
  nm -g --defined-only "$1" > "$syms" 2>/dev/null || true
  for sym in $expected_abi; do
    if grep -Eq "_$sym\$" "$syms"; then :; else
      echo "missing exported symbol: $sym" >&2; rm -f "$syms"; exit 67
    fi
  done
  rm -f "$syms"
}

verify_artifact() {
  count="$(ar -t "$1" | wc -l | tr -d ' ')"
  [ "$count" = "$expected_member_count" ] || {
    echo "member count mismatch: expected=$expected_member_count actual=$count" >&2; exit 66; }
  mf="$(mktemp)"; member_manifest "$1" > "$mf"
  actual_manifest="$(hash_file "$mf")"; rm -f "$mf"
  [ "$actual_manifest" = "$expected_member_manifest_sha256" ] || {
    echo "member manifest mismatch: expected=$expected_member_manifest_sha256 actual=$actual_manifest" >&2
    exit 66; }
  check_abi "$1"
  echo "  member_count=$count manifest=$actual_manifest ABI=ok"
}

gate_help() {
  cat <<'GATE'
行为门(替代逐字节判据)—— 口径来自 gpufe receipt 的 rebuild_note_zh

  逐字节复现在 2026-09-09 已试过并失败:同一编译器、同一 SDK,未改动的成员
  仍然不是逐字节相同(同语义的寄存器分配/栈溢出差异,原因未定位)。
  所以新产物要替换出货件,必须过下面两道,缺一不可:

  ① 离线回放等价 —— EuRoC 三档,ATE 落在现役基线带内
  ② 真机回放等价 —— 同一段录制,新旧两个 .a 各跑一遍,位姿逐帧对照;
     差异要能归因到数值噪声,不能是轨迹形状改变

  🔴 两道都过之前,--rebuild 的产物只留在暂存路径,**不进 vendor/**。
GATE
}

case "${1:---verify-only}" in
  --manifest) member_manifest "$artifact"; exit 0 ;;
  --gate-help) gate_help; exit 0 ;;
  --verify-only)
    verify_toolchain
    require_hash "$patch_dir/xrslam_destroy_lifecycle.patch" "$lifecycle_patch_sha256"
    require_hash "$patch_dir/xrslam_zero_inlier_mask.patch" "$zero_inlier_mask_patch_sha256"
    require_hash "$artifact" "$expected_artifact_sha256"
    verify_artifact "$artifact"
    echo "XRSLAM_IOS_GENERIC_VERIFIED sha256=$expected_artifact_sha256"
    exit 0 ;;
  --rebuild) ;;
  *) echo "usage: $0 [--verify-only|--manifest|--gate-help|--rebuild]" >&2; exit 64 ;;
esac

verify_toolchain
require_hash "$patch_dir/xrslam_destroy_lifecycle.patch" "$lifecycle_patch_sha256"
require_hash "$patch_dir/xrslam_zero_inlier_mask.patch" "$zero_inlier_mask_patch_sha256"
require_hash "$patch_dir/xrslam_ios_threading_override.patch" "$override_patch_sha256"

work_root="${PW_XRSLAM_IOS_WORK_ROOT:-}"
case "$work_root" in
  /private/tmp/pw-xrslam-ios-rebuild-*) ;;
  *) echo "PW_XRSLAM_IOS_WORK_ROOT must be a new /private/tmp/pw-xrslam-ios-rebuild-* path" >&2
     exit 64 ;;
esac
[ -e "$work_root" ] && { echo "refusing to overwrite: $work_root" >&2; exit 65; }

# configure_engine.sh 的前置检查,照抄
[ -d "$deps/$eigen_dir_name" ] || { echo "missing eigen 3.3.7 under $deps" >&2; exit 65; }
[ -d "$deps/opencv-$opencv_version-ios-framework/opencv2.framework" ] || {
  echo "missing opencv $opencv_version ios framework (extract the zip) under $deps" >&2; exit 65; }

mkdir -p "$work_root"
X="$work_root/xrslam"
B="$work_root/build"

git clone --filter=blob:none --no-checkout https://github.com/openxrlab/xrslam.git "$X"
git -C "$X" checkout --detach "$xrslam_revision"
[ "$(git -C "$X" rev-parse HEAD)" = "$xrslam_revision" ]
[ -z "$(git -C "$X" status --porcelain)" ]
git -C "$X" apply "$patch_dir/xrslam_destroy_lifecycle.patch"
git -C "$X" apply "$patch_dir/xrslam_zero_inlier_mask.patch"
git -C "$X" apply "$patch_dir/xrslam_ios_threading_override.patch"

export SOURCE_DATE_EPOCH="$source_date_epoch"
# iOS 专有:ar 归档头时间戳写 0(Android 产 .so 无归档头,用不上)。
# 出处 reproducible-builds.org/docs/archives/;现有出货 .a 带真实时间戳 ⇒ 当时没用。
export ZERO_AR_DATE=1

# ══ 配置:逐行抄 configure_engine.sh,只改 generic 臂该改的三处 ═════════════
#   · XRSLAM_ENABLE_THREADING:gpufe 是 ON,generic 出货档是 **OFF**
#   · 不传 XRSLAM_GPU_FRONTEND / PW_GPU_FRONTEND_INCLUDE_DIR
#   · 源码树用干净 4beb1a9 + 三个 patch,不是台架树
cmake -S "$X" -B "$B" -G Ninja \
  -D CMAKE_MAKE_PROGRAM="$(command -v ninja)" \
  -D CMAKE_TOOLCHAIN_FILE="$X/cmake/Modules/Platform/ios.toolchain.cmake" \
  -D CMAKE_BUILD_TYPE=Release \
  -D IOS_PLATFORM=OS64 -D IOS_ARCH=arm64 -D IOS_DEPLOYMENT_TARGET="$minimum_ios" \
  -D ENABLE_BITCODE=0 -D ENABLE_ARC=1 -D ENABLE_VISIBILITY=0 \
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -D XRSLAM_IOS_OVERRIDE=1 -D XRSLAM_IOS=OFF \
  -D XRSLAM_THREADING_OVERRIDE=1 -D XRSLAM_ENABLE_THREADING=OFF \
  -D CMAKE_CXX_FLAGS="-ffp-contract=off -fno-fast-math -fchar8_t -Dceres=pw_xrslam_ceres_1_14" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-EIGEN="$deps/$eigen_dir_name" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-OPENCV="$deps/opencv-$opencv_version-ios-framework/opencv2.framework" \
  -D FETCHCONTENT_FULLY_DISCONNECTED=OFF

# ══ 编译:抄 assemble_and_build.sh ═════════════════════════════════════════
# 🔴 不编默认目标:XRSLAM_IOS=OFF 时 interface 是 dylib,而 dylib 的链接需要
# 只有 app 侧才提供的符号。改成编静态库 + **单独编 interface 的两个 .o**,
# 归档时直接收那两个对象文件 —— 这正是出货归档里成员 2-3 的来源。
ninja -C "$B" xrslam-core xrslam-extra-opencv-image xrslam-extra-yaml-config yaml-cpp
for t in xrslam-interface/CMakeFiles/xrslam.dir/src/XRSLAMInternal.cpp.o \
         xrslam-interface/CMakeFiles/xrslam.dir/src/XRSLAMManager.cpp.o; do
  ninja -C "$B" "$t"
done

find_one() {
  f="$(find "$B" -name "$1" -type f | head -1)"
  [ -n "$f" ] || { echo "not built: $1" >&2; exit 70; }
  echo "$f"
}

# 合并顺序照**出货 generic 归档实测的成员次序**:
#   2-3 XRSLAMInternal/XRSLAMManager → 4 opencv_image → 5-6 yaml_config/config
#   → 7-26 core → 27-55 yaml-cpp
# (gpufe 那份顺序不同,它还含 localization —— 不要照抄它的顺序。)
merged="$work_root/libxrslam_generic_4beb1a9.a"
xcrun libtool -static -D -o "$merged" \
  "$(find_one XRSLAMInternal.cpp.o)" \
  "$(find_one XRSLAMManager.cpp.o)" \
  "$(find_one libxrslam-extra-opencv-image.a)" \
  "$(find_one libxrslam-extra-yaml-config.a)" \
  "$(find_one libxrslam-core.a)" \
  "$(find_one libyaml-cpp.a)" 2>&1 | grep -v "has no symbols" || true

[ -f "$merged" ] || { echo "libtool produced nothing" >&2; exit 70; }
check_abi "$merged"

count="$(ar -t "$merged" | wc -l | tr -d ' ')"
mf="$work_root/member-manifest.txt"; member_manifest "$merged" > "$mf"

{
  echo "schema=pw.xrslam.ios-generic-rebuild-run/2"
  echo "script_sha256=$(hash_file "$0")"
  echo "xrslam_revision=$(git -C "$X" rev-parse HEAD)"
  echo "clang_version=$expected_clang_version"
  echo "ninja_version=$expected_ninja_version"
  echo "source_date_epoch=$source_date_epoch"
  echo "zero_ar_date=1"
  echo "lifecycle_patch_sha256=$lifecycle_patch_sha256"
  echo "zero_inlier_mask_patch_sha256=$zero_inlier_mask_patch_sha256"
  echo "override_patch_sha256=$override_patch_sha256"
  echo "artifact_sha256=$(hash_file "$merged")"
  echo "archive_member_count=$count"
  echo "archive_member_manifest_sha256=$(hash_file "$mf")"
  echo "acceptance=behavioural-gate (see --gate-help); byte-identity is NOT the gate"
} > "$work_root/rebuild-run.receipt"

echo "XRSLAM_IOS_GENERIC_REBUILT"
echo "  path     = $merged   (**暂存,未进 vendor/**)"
echo "  members  = $count  (出货件是 $expected_member_count)"
echo "  artifact = $(hash_file "$merged")"
echo "  manifest = $(hash_file "$mf")"
echo "  出货件   = $expected_member_manifest_sha256"
echo "🔴 与出货件不同是**预期**,逐字节复现已知达不到(见文件头)。"
echo "🔴 能不能替换出货件,跑行为门判:$0 --gate-help"
