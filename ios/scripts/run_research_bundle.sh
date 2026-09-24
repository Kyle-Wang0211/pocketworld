#!/bin/sh
# ⚠️⚠️ 启动研究臂 —— **本脚本会开摄像头。**
#
#   零 ARKit 那条臂一进采集页就起 AVCaptureSession 拿后置相机。
#   **主 agent 必须先通知用户、拿到用户同意,才能跑这个脚本。**
#   子 agent 不执行本脚本;它只是被写好放在这里。
#
# ══ 为什么是并排装的那个 app ═══════════════════════════════════════════════
# 用户红线:「没全面持平/超越 ARKit 之前绝不上生产」。这里启动的是
# com.kyle.PocketWorld.zeroarkit(研究臂,另一个图标、另一份容器),
# **不是** com.kyle.PocketWorld(生产包,手机上那份 build 168 一个字节不碰)。
#
# 🔴 **它不是上生产。** 跑它只是在手机上跑第二个 app。
# 🔴 生产包本身即使装了也打不开这条臂 —— PwZeroArkitGate.swift 只读
#    `-PWVioPoseSource`,读不到就回落 ARKit,而且不提供任何打开它的 UI。
#
# ══ 怎么撤 ═════════════════════════════════════════════════════════════════
#   长按「PW 研究臂」图标 → 删除 App;或
#   xcrun devicectl device uninstall app --device <UDID> com.kyle.PocketWorld.zeroarkit
#
# ══ 用法 ═══════════════════════════════════════════════════════════════════
#   sh ios/scripts/run_research_bundle.sh                # ON 臂(自研位姿)
#   PW_POSE_SOURCE=arkit sh ios/scripts/run_research_bundle.sh   # OFF 臂(阴性对照)
#   sh ios/scripts/run_research_bundle.sh <UDID>
#
# 日志 tee 到 /tmp/pw_research_run_<时间戳>.log;Ctrl-C 结束后脚本会自己
# 把下面那份 grep 清单跑一遍。

set -eu

RESEARCH_BUNDLE_ID="${PW_RESEARCH_BUNDLE_ID:-com.kyle.PocketWorld.zeroarkit}"
PRODUCTION_BUNDLE_ID="com.kyle.PocketWorld"
POSE_SOURCE="${PW_POSE_SOURCE:-xrslam}"
DEVICE_UDID="${1:-${PW_DEVICE_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}}"

# ── 红线闸:本脚本永远不许启动生产包 ───────────────────────────────────────
if [ "$RESEARCH_BUNDLE_ID" = "$PRODUCTION_BUNDLE_ID" ]; then
  echo "error: 本脚本不启动生产包" >&2
  exit 64
fi

LOG="/tmp/pw_research_run_$(date +%Y%m%d_%H%M%S).log"

cat <<BANNER
══════════════════════════════════════════════════════════════════════════
⚠️  就要启动研究臂,**这会打开后置摄像头**。
    bundle : $RESEARCH_BUNDLE_ID
    位姿源 : -PWVioPoseSource $POSE_SOURCE
    设备   : $DEVICE_UDID
    日志   : $LOG
    生产包 $PRODUCTION_BUNDLE_ID 不受影响,也不会被启动。
    (锁屏状态下 launch 会 RequestDenied —— 先解锁手机。)
══════════════════════════════════════════════════════════════════════════
BANNER

/usr/bin/xcrun devicectl device process launch \
  --console --terminate-existing \
  --device "$DEVICE_UDID" \
  -e '{"OS_ACTIVITY_DT_MODE":"YES"}' \
  "$RESEARCH_BUNDLE_ID" \
  -- -PWVioPoseSource "$POSE_SOURCE" 2>&1 | tee "$LOG" || true

cat <<REPORT

══ 日志清单($LOG)═════════════════════════════════════════════════════
REPORT

# ── grep 清单 ──────────────────────────────────────────────────────────────
# 前四条:要**有**。最后一条 startSession:ON 臂里应当**一条都没有** ——
# 那是 ARKit 的 ARSession 起会话,零 ARKit 臂一条都不该走到。
for pat in 'zero-arkit' 'zero-arkit-preview' 'vio-consume' '时基' '租约'; do
  n="$(grep -c -- "$pat" "$LOG" || true)"
  printf '  %-22s %s 条\n' "$pat" "$n"
done
n_start="$(grep -c -- 'startSession' "$LOG" || true)"
printf '  %-22s %s 条' 'startSession' "$n_start"
if [ "$POSE_SOURCE" = "xrslam" ]; then
  if [ "$n_start" -eq 0 ]; then
    printf '   ✅ ON 臂应当为 0\n'
  else
    printf '   🔴 ON 臂里不该出现 ARSession.startSession\n'
  fi
else
  printf '   (OFF 臂走 ARKit,有是正常的)\n'
fi
echo "═══════════════════════════════════════════════════════════════════════"
echo "细看:grep -nE 'zero-arkit|vio-consume|时基|租约|startSession' $LOG"
