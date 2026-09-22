#!/bin/sh
# 把研究臂装到真机 —— **并排**装,生产包一个字节不碰。
#
# ══ 为什么并排装 ═══════════════════════════════════════════════════════════
# 用户红线:「没全面持平/超越 ARKit 之前绝不上生产」。研究臂用的是另一个
# bundle id(com.kyle.PocketWorld.zeroarkit),iOS 把它当成**另一个 app**:
# 另一个图标、另一份沙盒容器、另一条版本线。装它不会覆盖、不会降级、
# 也不会动 com.kyle.PocketWorld 的任何数据。
#
# 🔴 **它不是上生产。** 手机上多一个图标而已。
# 🔴 本脚本**只装不起**。装完只用 `devicectl device info apps` 核对存在;
#    **不** launch —— 研究臂一进采集页就开摄像头,开摄像头必须先由主 agent
#    通知用户。要跑见 ios/scripts/run_research_bundle.sh(那份也不该由子 agent 执行)。
#
# ══ 怎么撤 ═════════════════════════════════════════════════════════════════
#   手机上长按「PW 研究臂」图标 → 删除 App;或
#   xcrun devicectl device uninstall app --device <UDID> com.kyle.PocketWorld.zeroarkit
#
# ══ 用法 ═══════════════════════════════════════════════════════════════════
#   sh ios/scripts/install_research_bundle.sh                 # 用默认 UDID
#   sh ios/scripts/install_research_bundle.sh <UDID> [app 路径]

set -eu

PRODUCTION_BUNDLE_ID="com.kyle.PocketWorld"
PRODUCTION_EXPECTED_BUILD="${PW_PRODUCTION_EXPECTED_BUILD:-168}"
RESEARCH_BUNDLE_ID="${PW_RESEARCH_BUNDLE_ID:-com.kyle.PocketWorld.zeroarkit}"
DEVICE_UDID="${1:-${PW_DEVICE_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}}"

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
APP_PATH="${2:-build/ios/iphoneos/Runner.app}"

[ -d "$APP_PATH" ] || { echo "error: 找不到 $APP_PATH,先跑 ios/scripts/build_research_bundle.sh" >&2; exit 66; }

# ── 红线闸:要装的包**必须不是**生产 id ────────────────────────────────────
app_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist")"
if [ "$app_id" = "$PRODUCTION_BUNDLE_ID" ]; then
  echo "error: $APP_PATH 的 CFBundleIdentifier 是生产 id($PRODUCTION_BUNDLE_ID)——装它就是覆盖生产包。拒绝。" >&2
  exit 64
fi
if [ "$app_id" != "$RESEARCH_BUNDLE_ID" ]; then
  echo "error: $APP_PATH 的 id 是 $app_id,不是期望的 $RESEARCH_BUNDLE_ID" >&2
  exit 64
fi
echo "要装的包:$APP_PATH  id=$app_id"

tmp_json="$(mktemp "${TMPDIR:-/tmp}/pw_apps.XXXXXX.json")"
cleanup() { rm -f "$tmp_json" "$tmp_json".before 2>/dev/null || true; }
trap cleanup EXIT INT TERM HUP

# app 清单查询;第 2 个参数是 bundle id,打印 "版本|build",查不到打印空
query_app() {
  /usr/bin/xcrun devicectl device info apps --device "$DEVICE_UDID" --json-output "$1" >/dev/null 2>&1 \
    || { echo "error: devicectl 查询失败(手机连着吗?)" >&2; return 70; }
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
for app in data.get("result", {}).get("apps", []):
    if app.get("bundleIdentifier") == want:
        print("%s|%s" % (app.get("version"), app.get("bundleVersion")))
        break
PY
}

# ── 装机前:记下生产包的版本,装完要逐字对回来 ─────────────────────────────
before_prod="$(query_app "$tmp_json".before "$PRODUCTION_BUNDLE_ID")"
echo "装机前 $PRODUCTION_BUNDLE_ID : ${before_prod:-<未安装>}"
if [ -z "$before_prod" ]; then
  echo "⚠️ 装机前手机上就没有生产包 —— 后面的「不变」只能证明没被本脚本装上,不能证明它还在。"
fi

# ── 装 ─────────────────────────────────────────────────────────────────────
echo ""
echo "── devicectl install ──"
/usr/bin/xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH"

# ── 装机后核对:两个条目都要在,生产包版本必须一字不变 ─────────────────────
echo ""
echo "══ 装机后核对 ════════════════════════════════════════════════════════"
fail=0
after_prod="$(query_app "$tmp_json" "$PRODUCTION_BUNDLE_ID")"
after_res="$(query_app "$tmp_json" "$RESEARCH_BUNDLE_ID")"
echo "$PRODUCTION_BUNDLE_ID : ${after_prod:-<缺失>}"
echo "$RESEARCH_BUNDLE_ID : ${after_res:-<缺失>}"

if [ -z "$after_prod" ]; then
  echo "  🔴 生产包不见了 —— 红线事故"
  fail=1
elif [ -n "$before_prod" ] && [ "$after_prod" != "$before_prod" ]; then
  echo "  🔴 生产包版本变了:$before_prod → $after_prod"
  fail=1
else
  case "$after_prod" in
    *"|$PRODUCTION_EXPECTED_BUILD") echo "  ✅ 生产包仍在,build 仍是 $PRODUCTION_EXPECTED_BUILD" ;;
    *) echo "  🔴 生产包 build 不是期望的 $PRODUCTION_EXPECTED_BUILD:$after_prod"; fail=1 ;;
  esac
fi

if [ -z "$after_res" ]; then
  echo "  🔴 研究臂没装上"
  fail=1
else
  echo "  ✅ 研究臂已装上(并排,不覆盖)"
fi

echo "══════════════════════════════════════════════════════════════════════"
[ "$fail" -eq 0 ] || { echo "🔴 核对未过"; exit 1; }
echo "✅ 两个 bundle 都在。**没有启动任何 app,摄像头没开过。**"
echo "   要跑研究臂:ios/scripts/run_research_bundle.sh —— 启动会开摄像头,主 agent 必须先通知用户。"
