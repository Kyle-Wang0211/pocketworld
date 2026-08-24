#!/bin/bash
# 一次跑完全部正向 + 负向对照 + 端到端 I/O + Swift 编译。
# 任何一项红就整体退出非零。
#
# ⚠️ 解释器:本机默认 python3 (3.14) 的 numpy 装坏了(site-packages/numpy 缺 __init__.py,
#    import 退化成 namespace package)。这里显式用 3.11。
set -u
PY=${PY:-/opt/homebrew/bin/python3.11}
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
TMP=$(mktemp -d)
FAIL=0

run() {
  local name="$1"; shift
  echo "───────────────────────────────────────────────── $name"
  if "$@" > "$TMP/out.txt" 2>&1; then
    tail -n 3 "$TMP/out.txt"
    echo "  [PASS] $name"
  else
    tail -n 25 "$TMP/out.txt"
    echo "  [FAIL] $name"
    FAIL=$((FAIL+1))
  fi
}

run "thermal_hysteresis 正向"   "$PY" thermal_hysteresis.py --selftest
run "thermal_hysteresis 负向"   "$PY" thermal_hysteresis.py --negative-control
run "g_sensitivity 正向"        "$PY" g_sensitivity.py --selftest
run "g_sensitivity 负向"        "$PY" g_sensitivity.py --negative-control
run "bias_window 正向"          "$PY" bias_window.py --selftest
run "bias_window 负向"          "$PY" bias_window.py --negative-control
run "templog 正向"              "$PY" templog.py --selftest
run "templog 负向"              "$PY" templog.py --negative-control

# 端到端:造合成 session → 从 CSV 读回来 → 出结论
run "端到端 造 session"          "$PY" thermal_hysteresis.py --make-synthetic "$TMP/sess"
run "端到端 滞回分析"            "$PY" thermal_hysteresis.py \
      --imu "$TMP/sess/imu.csv" --segments "$TMP/sess/segments.csv" \
      --json "$TMP/sess/hyst.json"

# Swift:macOS 真编译 + 真运行,iOS arm64 typecheck
run "Swift macOS 编译"          swiftc -O ThermalStateLogger.swift -o "$TMP/tsl"
run "Swift macOS 运行"          "$TMP/tsl" 2 "$TMP/thermal.csv"
run "Swift iOS typecheck"       xcrun --sdk iphoneos swiftc -typecheck \
      -target arm64-apple-ios15.0 ThermalStateLogger.swift

# Swift 负向对照:改坏一个 API 名,iOS typecheck 必须失败
echo "───────────────────────────────────────────────── Swift 负向(API 名改坏必须编不过)"
sed 's/thermalStateDidChangeNotification/thermalStateDidChangeNotificationXX/' \
    ThermalStateLogger.swift > "$TMP/broken.swift"
if xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios15.0 \
      "$TMP/broken.swift" > "$TMP/berr.txt" 2>&1; then
  echo "  [FAIL] 改坏 API 名居然编过了 —— typecheck 没在真检查"
  FAIL=$((FAIL+1))
else
  echo "  $(grep -c 'error' "$TMP/berr.txt") 个 error,符合预期"
  echo "  [PASS] Swift 负向"
fi

echo "═════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ 全部通过"
else
  echo "  ❌ $FAIL 项失败"
fi
rm -rf "$TMP"
exit "$FAIL"
