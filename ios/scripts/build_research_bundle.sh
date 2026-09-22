#!/bin/sh
# 研究臂「并排装」构建 —— 出一个**换了 bundle id** 的 Release 包,
# 好让零 ARKit 那条臂能装进真机跑,而手机上那个生产包一个字节不碰。
#
# ══ 为什么要并排装 ═════════════════════════════════════════════════════════
# 用户的红线原话:「**没全面持平/超越 ARKit 之前绝不上生产**」。
# 只要研究臂用的还是 `com.kyle.PocketWorld` 这个 id,装机就是**覆盖**生产包 ——
# 图标、数据容器、版本号全被顶掉,没有第二份可回退。所以这条臂必须换 id:
#
#     生产包  com.kyle.PocketWorld            (手机上现装 build 168,本脚本永不触碰)
#     研究臂  com.kyle.PocketWorld.zeroarkit  (本脚本产出,另一个图标,另一份容器)
#
# 先例就在本机:`~/Developer/arloopbench` 用 `com.kyle.arloopbench`
# 与生产包并排装了两个月;`com.kyle.viobench` 同理。这里照抄那条做法,
# 不发明新机制:签名仍走工程里现成的 Automatic + DEVELOPMENT_TEAM=26AH7V448L。
#
# 🔴 **它不是上生产。** 产出物是一个**第二个** app,装上去只是多一个图标;
#    判据没过之前它跟生产包没有任何关系,生产包也不会因为它变任何行为。
#
# ══ 签名是怎么过的(2026-09-22 实测,按顺序)═════════════════════════════
# ① Flutter 本来就给 xcodebuild 传了 `-allowProvisioningUpdates` +
#    `-allowProvisioningDeviceRegistration`(flutter_tools/lib/src/ios/mac.dart:408,
#    codesign 时恒加),所以「让 Xcode 自动注册新 App ID」这一步**已经试过了**,
#    结果是:
#        Error (Xcode): No Accounts: Add a new account in Accounts settings.
#        Error (Xcode): Provisioning profile "iOS Team Provisioning Profile: *"
#                       doesn't include the Extended Virtual Addressing capability.
#        Error (Xcode): Provisioning profile "iOS Team Provisioning Profile: *"
#                       doesn't include the Increased Memory Limit capability.
#    本机 Xcode 没登录任何 Apple 账号(`defaults read com.apple.dt.Xcode
#    DVTDeveloperAccountManagerAppleIDLists` 为空),新 App ID 注册不了;Xcode
#    回落到本机已有的通配 profile `26AH7V448L.*`,而通配 profile 按苹果规则
#    **不能**带 increased-memory-limit / extended-virtual-addressing 这两项能力。
#    ⇒ 第 ① 步判死,原因是账号不在,不是脚本或工程的问题。
# ② 于是研究臂**临时**把这两项从 ios/Runner/Runner.entitlements 里去掉
#    (同样 trap 还原、不提交),让通配 profile 能签 —— 这正是 arloopbench 的
#    签法(它根本没有 entitlements 文件,签出来的 application-identifier 是
#    `26AH7V448L.com.kyle.arloopbench`)。
#
# 🔴 **已知差异(不是 bug)**:研究臂**没有增大内存上限、没有扩展虚拟地址**。
#    内存密集的重建阶段(深度/成网/贴图)可能与生产包行为不同 —— 更早被
#    jetsam 杀、或大分配失败。零 ARKit 采集页本身不在这一档;拿研究臂
#    比重建阶段的内存行为**不作数**。要恢复这两项能力:在 Xcode → Settings →
#    Accounts 登录团队账号,再以 `PW_RESEARCH_KEEP_KERNEL_ENTITLEMENTS=1`
#    跑本脚本,Flutter 传的 -allowProvisioningUpdates 会让 Xcode 注册
#    `com.kyle.PocketWorld.zeroarkit` 这个 App ID 并开这两项能力。
#
# ══ 怎么撤 ═════════════════════════════════════════════════════════════════
#   手机上:长按「PW 研究臂」图标 → 删除 App。生产包不受影响。
#   命令行:xcrun devicectl device uninstall app --device <UDID> com.kyle.PocketWorld.zeroarkit
#   工作树:本脚本对 pbxproj / Info.plist / Runner.entitlements 的改动是**临时**的,
#           trap 在任何退出路径(成功、失败、Ctrl-C)都会还原;脚本跑完
#           `git status --short ios/` 必须为空。
#
# ══ 用法 ═══════════════════════════════════════════════════════════════════
#   sh ios/scripts/build_research_bundle.sh
#   PW_RESEARCH_BUNDLE_ID=com.kyle.PocketWorld.xxx \
#   PW_RESEARCH_DISPLAY_NAME='别的名字' \
#   PW_RESEARCH_ENGINE=gpufenothread \
#   PW_RESEARCH_KEEP_KERNEL_ENTITLEMENTS=1 \
#     sh ios/scripts/build_research_bundle.sh
#
# 产出:build/ios/iphoneos/Runner.app(已签名,可直接 devicectl install)
# 接着跑:sh ios/scripts/install_research_bundle.sh

set -eu

# ── 参数 ───────────────────────────────────────────────────────────────────
PRODUCTION_BUNDLE_ID="com.kyle.PocketWorld"
RESEARCH_BUNDLE_ID="${PW_RESEARCH_BUNDLE_ID:-com.kyle.PocketWorld.zeroarkit}"
RESEARCH_DISPLAY_NAME="${PW_RESEARCH_DISPLAY_NAME:-PW 研究臂}"
RESEARCH_ENGINE="${PW_RESEARCH_ENGINE:-generic}"
KEEP_KERNEL_ENTITLEMENTS="${PW_RESEARCH_KEEP_KERNEL_ENTITLEMENTS:-0}"
EXPECTED_PW_SYMBOLS="${PW_EXPECTED_EXPORTED_SYMBOLS:-44}"
DEVELOPMENT_TEAM="26AH7V448L"
KERNEL_ENTITLEMENT_KEYS="com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing"

# ── 红线闸:绝不允许把产物打成生产 id ──────────────────────────────────────
if [ "$RESEARCH_BUNDLE_ID" = "$PRODUCTION_BUNDLE_ID" ]; then
  echo "error: 研究臂 bundle id 不能等于生产 id($PRODUCTION_BUNDLE_ID)——那是覆盖生产包" >&2
  exit 64
fi
case "$RESEARCH_BUNDLE_ID" in
  "$PRODUCTION_BUNDLE_ID".*) ;;
  *)
    echo "error: 研究臂 bundle id 必须是 $PRODUCTION_BUNDLE_ID 的子 id(签名用同一个 team)" >&2
    exit 64
    ;;
esac

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

pbxproj="ios/Runner.xcodeproj/project.pbxproj"
infoplist="ios/Runner/Info.plist"
entitlements="ios/Runner/Runner.entitlements"

# pod install 要 UTF-8 终端(docs/runbooks/app-update-install-runbook.md 第 3 步:
# 不带这两个变量时 pod install 可能静默失败、拿旧 Pods 工程「看起来构建成功」)。
LANG="${LANG:-en_US.UTF-8}"
LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LANG LC_ALL

# ── 前置闸:这三个文件必须是干净的,否则「还原」没有意义 ────────────────────
dirty="$(git status --porcelain -- "$pbxproj" "$infoplist" "$entitlements" || true)"
if [ -n "$dirty" ]; then
  echo "error: $pbxproj / $infoplist / $entitlements 有未提交改动,本脚本要临时改它们再还原,拒绝在脏树上跑:" >&2
  echo "$dirty" >&2
  exit 65
fi

# ── 备份 + trap 还原(成功/失败/Ctrl-C 都走同一条路)───────────────────────
backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/pw_research_bundle.XXXXXX")"
cp "$pbxproj"      "$backup_dir/project.pbxproj"
cp "$infoplist"    "$backup_dir/Info.plist"
cp "$entitlements" "$backup_dir/Runner.entitlements"

restore_sources() {
  rc=$?
  cp "$backup_dir/project.pbxproj"     "$pbxproj" 2>/dev/null || true
  cp "$backup_dir/Info.plist"          "$infoplist" 2>/dev/null || true
  cp "$backup_dir/Runner.entitlements" "$entitlements" 2>/dev/null || true
  # 构建副产物:pod install 会动 ios/Podfile.lock,flutter pub get 会动
  # pubspec.lock。两者都纳入版本控制,不还原的话 `git status` 不干净,
  # 临时改动就有被顺手提交进去的风险。
  git checkout -- ios/Podfile.lock pubspec.lock 2>/dev/null || true
  rm -rf "$backup_dir"
  echo ""
  echo "── 源码已还原 ──"
  git status --short -- ios/ pubspec.lock || true
  exit $rc
}
trap restore_sources EXIT INT TERM HUP

# ── 临时改 bundle id(先改 RunnerTests,免得被主 id 的模式吃掉)────────────
main_hits="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCTION_BUNDLE_ID};" "$pbxproj" || true)"
test_hits="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCTION_BUNDLE_ID}.RunnerTests;" "$pbxproj" || true)"
if [ "$main_hits" -ne 3 ] || [ "$test_hits" -ne 3 ]; then
  echo "error: pbxproj 里 bundle id 的出现次数变了(主 $main_hits 期望 3;测试 $test_hits 期望 3)——工程结构动过,先人工核对" >&2
  exit 65
fi

/usr/bin/sed -i '' \
  -e "s|PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCTION_BUNDLE_ID}.RunnerTests;|PRODUCT_BUNDLE_IDENTIFIER = ${RESEARCH_BUNDLE_ID}.RunnerTests;|g" \
  -e "s|PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCTION_BUNDLE_ID};|PRODUCT_BUNDLE_IDENTIFIER = ${RESEARCH_BUNDLE_ID};|g" \
  "$pbxproj"

left="$(grep -c "PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCTION_BUNDLE_ID};" "$pbxproj" || true)"
if [ "$left" -ne 0 ]; then
  echo "error: pbxproj 里还剩 $left 处生产 bundle id 没换掉" >&2
  exit 65
fi

# ── 临时改显示名(没有该键就加;CFBundleIdentifier 本来就是 $(PRODUCT_BUNDLE_IDENTIFIER),不用动)──
if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$infoplist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $RESEARCH_DISPLAY_NAME" "$infoplist"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $RESEARCH_DISPLAY_NAME" "$infoplist"
fi

# ── 临时去掉两项 kernel entitlements(见文件头「签名是怎么过的」②)──────────
if [ "$KEEP_KERNEL_ENTITLEMENTS" = "1" ]; then
  echo "⚠️ PW_RESEARCH_KEEP_KERNEL_ENTITLEMENTS=1:保留 kernel entitlements。要过签名,Xcode 里必须已登录团队账号,"
  echo "   否则会跟 2026-09-22 一样死在「No Accounts」+ 通配 profile 缺能力。"
else
  for key in $KERNEL_ENTITLEMENT_KEYS; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Delete :$key" "$entitlements"
    fi
  done
  left="$(/usr/bin/grep -c 'com.apple.developer.kernel' "$entitlements" || true)"
  if [ "$left" -ne 0 ]; then
    echo "error: $entitlements 里还剩 $left 处 kernel entitlement 没去掉" >&2
    exit 65
  fi
  /usr/bin/plutil -lint "$entitlements" >/dev/null
fi

echo "── 临时身份 ──"
echo "  bundle id          : $RESEARCH_BUNDLE_ID"
echo "  display name       : $RESEARCH_DISPLAY_NAME"
echo "  engine arm         : $RESEARCH_ENGINE"
echo "  kernel entitlements: $([ "$KEEP_KERNEL_ENTITLEMENTS" = "1" ] && echo 保留 || echo '去掉(研究臂无增大内存上限,已知差异)')"
echo ""

# ── 装机身份三件套(盖章脚本 ios/scripts/stamp_runtime_identity.sh 缺一即 exit 65)──
# 源清单在**改完之后**算 —— 收据要描述真正被构建的那份源,不是构建前的那份。
PW_PRODUCT_SOURCE_MANIFEST_SHA256="$(sh tool/product_source_manifest.sh)"
PW_DIAGNOSTIC_BUILD_ID="research-zeroarkit-$(date +%Y%m%d)"
PW_VIO_SHADOW_MODE="off"
export PW_PRODUCT_SOURCE_MANIFEST_SHA256 PW_DIAGNOSTIC_BUILD_ID PW_VIO_SHADOW_MODE
echo "  PW_PRODUCT_SOURCE_MANIFEST_SHA256=$PW_PRODUCT_SOURCE_MANIFEST_SHA256"
echo "  PW_DIAGNOSTIC_BUILD_ID=$PW_DIAGNOSTIC_BUILD_ID"
echo "  PW_VIO_SHADOW_MODE=$PW_VIO_SHADOW_MODE"
echo ""

# ── 构建 ───────────────────────────────────────────────────────────────────
# 🔴 **要签名**。不能加 --no-codesign:CODE_SIGNING_ALLOWED=NO 出来的 Release
#    包装不上真机(之前踩过)。Flutter 自己会给 xcodebuild 加
#    -allowProvisioningUpdates / -allowProvisioningDeviceRegistration。
sh ios/scripts/select_xrslam_engine.sh "$RESEARCH_ENGINE" -- flutter build ios --release

app="build/ios/iphoneos/Runner.app"
[ -d "$app" ] || { echo "error: 构建产物不存在:$app" >&2; exit 66; }

# ── 自检:任一条不对就非零退出 ─────────────────────────────────────────────
echo ""
echo "══ 自检 ══════════════════════════════════════════════════════════════"
fail=0

echo "产物时间戳          : $(/bin/ls -la "$app/Runner" | /usr/bin/awk '{print $6, $7, $8}')(必须是刚才)"

got_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")"
echo "CFBundleIdentifier  : $got_id"
[ "$got_id" = "$RESEARCH_BUNDLE_ID" ] || { echo "  🔴 期望 $RESEARCH_BUNDLE_ID"; fail=1; }
[ "$got_id" != "$PRODUCTION_BUNDLE_ID" ] || { echo "  🔴 产物打成了生产 id"; fail=1; }

got_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$app/Info.plist")"
echo "CFBundleDisplayName : $got_name"
[ "$got_name" = "$RESEARCH_DISPLAY_NAME" ] || { echo "  🔴 期望 $RESEARCH_DISPLAY_NAME"; fail=1; }

got_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Info.plist")"
got_short="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")"
echo "CFBundleVersion     : $got_short ($got_build)"

got_arm="$(/usr/libexec/PlistBuddy -c "Print :PWXrslamEngineArm" "$app/Info.plist" 2>/dev/null || echo MISSING)"
echo "PWXrslamEngineArm   : $got_arm"
[ "$got_arm" = "$RESEARCH_ENGINE" ] || { echo "  🔴 期望 $RESEARCH_ENGINE"; fail=1; }

got_build_id="$(/usr/libexec/PlistBuddy -c "Print :PWLiveCloudDiagnosticBuildId" "$app/Info.plist" 2>/dev/null || echo MISSING)"
echo "PWLiveCloudDiagnosticBuildId: $got_build_id"
[ "$got_build_id" = "$PW_DIAGNOSTIC_BUILD_ID" ] || { echo "  🔴 期望 $PW_DIAGNOSTIC_BUILD_ID"; fail=1; }

sym_count="$(/usr/bin/nm -g --defined-only "$app/Runner" | grep -c ' T _pw_' || true)"
echo "导出 _pw_ 符号数    : $sym_count(期望 $EXPECTED_PW_SYMBOLS)"
[ "$sym_count" -eq "$EXPECTED_PW_SYMBOLS" ] || { echo "  🔴 导出白名单变了 —— FFI 通路可能在 Release 里被关掉"; fail=1; }

echo "codesign --verify --deep --strict:"
if /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /'; then
  echo "  ✅ 签名有效"
else
  echo "  🔴 签名校验失败"
  fail=1
fi

# 签进去的 entitlements:application-identifier 必须是研究臂 id;
# 两项 kernel entitlements 去掉了就必须不在场,保留了就必须在场。
signed_ents="$(/usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null | /usr/bin/plutil -convert xml1 -o - - 2>/dev/null || true)"
signed_id="$(printf '%s\n' "$signed_ents" | /usr/bin/grep -A1 '<key>application-identifier</key>' | /usr/bin/grep '<string>' \
  | /usr/bin/sed 's/.*<string>\(.*\)<\/string>.*/\1/' || true)"
echo "签名里的 application-identifier: ${signed_id:-<读不到>}"
[ "${signed_id:-}" = "$DEVELOPMENT_TEAM.$RESEARCH_BUNDLE_ID" ] || { echo "  🔴 期望 $DEVELOPMENT_TEAM.$RESEARCH_BUNDLE_ID"; fail=1; }
for key in $KERNEL_ENTITLEMENT_KEYS; do
  if printf '%s\n' "$signed_ents" | /usr/bin/grep -q "<key>$key</key>"; then
    present=1
  else
    present=0
  fi
  if [ "$KEEP_KERNEL_ENTITLEMENTS" = "1" ]; then
    [ "$present" -eq 1 ] && echo "签名里 $key: 在场 ✅" || { echo "签名里 $key: 缺失 🔴(要求保留)"; fail=1; }
  else
    [ "$present" -eq 0 ] && echo "签名里 $key: 不在场(研究臂已知差异)" || { echo "签名里 $key: 在场 🔴(本该去掉)"; fail=1; }
  fi
done

echo "══════════════════════════════════════════════════════════════════════"
if [ "$fail" -ne 0 ]; then
  echo "🔴 自检未过"
  exit 1
fi
echo "✅ 自检全过。产物:$repo_root/$app"
echo "   下一步:sh ios/scripts/install_research_bundle.sh"
