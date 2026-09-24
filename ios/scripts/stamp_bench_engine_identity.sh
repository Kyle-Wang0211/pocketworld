#!/bin/sh
# stamp_bench_engine_identity.sh —— 台架(arloopbench)的引擎臂身份章。
#
# 只给台架用:由 tool/bench 的同步脚本镜像到 arloopbench/ios/scripts/,
# 台架 Runner.xcodeproj 的「Stamp Bench Engine Identity」构建阶段调用它。
# 生产 Runner.xcodeproj **不**调用它(生产用 stamp_runtime_identity.sh)。
#
# ══ 抄的是 stamp_runtime_identity.sh 的「引擎臂」那一半,不是新规则 ═══════════
#   ① 对账闸(那边 :5-20):请求的臂 ≠ Podfile 实际写进 xcconfig 的臂 ⇒ 构建失败(exit 70)。
#      台架请求臂的环境变量是 PW_XRSLAM_ARM(台架 Podfile 一直用这个名字),
#      Podfile 把它映射成产品臂名写进 PW_XRSLAM_LINKED_ENGINE(与产品同名同义)。
#   ② 二进制指纹(那边 :179-196):本臂的 OpenCV 构建路径串**在场**、别的臂的**不在场**。
#      那边把「别的臂」写死成两条;台架 Podfile 把整张臂表里其余各臂的指纹写进
#      PW_XRSLAM_OTHER_ENGINE_FINGERPRINTS(`|` 分隔),这里逐条核 —— 加一条臂只改
#      Podfile 那张表,本脚本不用动。
#   ③ Info.plist 章(那边 :202-216 里与引擎有关的那几个键,**同名**):
#      PWXrslamEngineArm 是 ios/Runner/PwXrslamLive.swift `PwXrslamEngineIdentity`
#      读的键 —— 盖成 gpufenothread_pfk ⇒ 逐帧 K 账里的来源能判成 per_frame。
#   那边其余的身份(产品源码清单、PWOfficialSfm、诊断构建号)台架没有,不抄。
#
# ══ 何时盖章 ═══════════════════════════════════════════════════════════════
#   那边只在 Release 盖(:22-26)。台架 Release 与 Profile 都盖:两者都把 Swift/C
#   链进 Runner 本体(Debug 在 Runner.debug.dylib 里,指纹核不到),而产品的真机包
#   规矩是 Profile(pocketworld CLAUDE.md)。Debug 不盖 ⇒ PwXrslamEngineIdentity 报
#   「没盖章」(consumesPerFrameK = −1),K 来源如实标 per_frame_attached_unverified。

set -eu

# ── ① 对账闸(所有 configuration 都跑)────────────────────────────────────
pw_bench_arm_requested="${PW_XRSLAM_ARM:-}"
pw_xrslam_engine_linked="${PW_XRSLAM_LINKED_ENGINE:-}"
pw_bench_arm_linked="${PW_XRSLAM_LINKED_BENCH_ARM:-}"
if [ -z "$pw_xrslam_engine_linked" ]; then
  echo "error: xcconfig 里没有 PW_XRSLAM_LINKED_ENGINE —— 台架 Podfile 的 post_install 没跑(重跑 pod install)" >&2
  exit 70
fi
if [ "$pw_bench_arm_requested" != "$pw_bench_arm_linked" ]; then
  echo "error: PW_XRSLAM_ARM=$pw_bench_arm_requested 但 xcconfig 里链的是 PW_XRSLAM_ARM=$pw_bench_arm_linked($pw_xrslam_engine_linked);换臂后必须重跑 pod install" >&2
  exit 70
fi

case "${CONFIGURATION:-}" in
  Release|Profile) ;;
  *) exit 0 ;;
esac

hash_artifact() {
  if [ ! -f "$1" ]; then
    echo "error: runtime identity artifact is missing: $1" >&2
    exit 66
  fi
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

set_plist_string() {
  if ! /usr/libexec/PlistBuddy -c "Set :$1 $2" "$runtime_plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$runtime_plist"
  fi
}

runtime_plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
native_host="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
xrslam_lib_name="${PW_XRSLAM_LINKED_ENGINE_LIB:?}"
xrslam_engine_sha16="${PW_XRSLAM_LINKED_ENGINE_SHA16:?}"
xrslam_engine_fingerprint="${PW_XRSLAM_LINKED_ENGINE_FINGERPRINT:?}"
xrslam_pedigree="${PW_XRSLAM_LINKED_ENGINE_PEDIGREE:?}"
xrslam_gpu_frontend="${PW_XRSLAM_LINKED_ENGINE_GPU_FRONTEND:?}"
xrslam_other_fingerprints="${PW_XRSLAM_OTHER_ENGINE_FINGERPRINTS:-}"
xrslam_archive="$SRCROOT/../vendor/xrslam/libs/ios-arm64/$xrslam_lib_name"

for f in "$runtime_plist" "$native_host"; do
  if [ ! -f "$f" ]; then
    echo "error: runtime identity artifact is missing: $f" >&2
    exit 66
  fi
done

xrslam_sha256="$(hash_artifact "$xrslam_archive")"
case "$xrslam_sha256" in
  "$xrslam_engine_sha16"*) ;;
  *)
    echo "error: $xrslam_lib_name 的 sha256 ($xrslam_sha256) 与臂表的 sha16 ($xrslam_engine_sha16) 对不上" >&2
    exit 67
    ;;
esac

# ── ② 二进制指纹 ─────────────────────────────────────────────────────────
host_strings="$(/usr/bin/strings -a "$native_host")"
if ! printf '%s\n' "$host_strings" | /usr/bin/grep -qF "$xrslam_engine_fingerprint"; then
  echo "error: 链接产物里找不到 $pw_xrslam_engine_linked 臂的指纹 —— 链进去的不是它" >&2
  exit 71
fi
old_ifs="$IFS"
IFS='|'
for other in $xrslam_other_fingerprints; do
  [ -z "$other" ] && continue
  if printf '%s\n' "$host_strings" | /usr/bin/grep -qF "$other"; then
    echo "error: 链接产物里同时出现了另一条臂的指纹($other)—— 两条臂被一起链进去了" >&2
    exit 71
  fi
done
IFS="$old_ifs"

native_host_uuid="$(/usr/bin/xcrun dwarfdump --uuid "$native_host" \
  | /usr/bin/awk '$1 == "UUID:" && $3 == "(arm64)" { print $2 }' | /usr/bin/head -n 1)"

# ── ③ Info.plist 章(与 stamp_runtime_identity.sh 同名的键)──────────────────
set_plist_string "PWXrslamSHA256" "$xrslam_sha256"
set_plist_string "PWXrslamEngineArm" "$pw_xrslam_engine_linked"
set_plist_string "PWXrslamEngineLib" "$xrslam_lib_name"
set_plist_string "PWXrslamEngineSHA16" "$xrslam_engine_sha16"
set_plist_string "PWXrslamEngineFingerprint" "$xrslam_engine_fingerprint"
set_plist_string "PWXrslamEnginePedigree" "$xrslam_pedigree"
set_plist_string "PWXrslamGpuFrontendLinked" "$xrslam_gpu_frontend"
# [bench 2026-09-24] 线程化跟臂表走(官方配置臂 = true);旧臂表没有这一列 ⇒ false(与原先写死的值相同)。
set_plist_string "PWXrslamThreadingEnabled" "${PW_XRSLAM_LINKED_ENGINE_THREADING:-false}"
# [bench 2026-09-24] 空臂名 = 台架默认臂(09-24 起是 official_rules,不再是 generic)⇒ 写 default,不写臂名。
set_plist_string "PWXrslamBenchArm" "${pw_bench_arm_linked:-default}"
[ -n "$native_host_uuid" ] && set_plist_string "PWNativeHostUUID" "$native_host_uuid"

echo "PW_BENCH_ENGINE_IDENTITY engine=$pw_xrslam_engine_linked bench_arm=${pw_bench_arm_linked:-default} lib=$xrslam_lib_name sha16=$xrslam_engine_sha16 pedigree=$xrslam_pedigree gpu_frontend=$xrslam_gpu_frontend host_uuid=$native_host_uuid"
