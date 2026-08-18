#!/bin/zsh
# 供应链完整性检查。发版前跑。
#
# 为什么是脚本而不是 CI:这个仓库没有 .github(无 CI 流水线)。与其假装把检查
# 加进不存在的流水线,不如给一个能真正被执行的入口 —— 将来有 CI 了,直接调它。
#
# 检查两件事,各自对应一个真实的失效模式:
#   1. pubspec.lock 只有在 `--enforce-lockfile` 下才真正生效。
#      默认的 `flutter pub get` 允许在满足约束的前提下**悄悄改变解析结果**,
#      锁文件形同虚设。Dart 官方文档:--enforce-lockfile 会在解析结果与锁文件
#      不符、或任何 hosted 包的 **content hash 变化** 时失败。
#   2. Edge Function 的依赖若写成 `@2` 这类 major-only specifier,那是
#      **semver range 不是固定版本** —— 每次部署都可能解析到不同的 2.x,
#      存在上游被投毒或引入 breaking change 的窗口。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAIL=0

echo "=== ① Flutter 依赖:锁文件必须精确成立 ==="
if flutter pub get --enforce-lockfile >/tmp/pubget.log 2>&1; then
  echo "  ✅ pubspec.lock 与 pubspec.yaml 一致,且所有 content hash 未变"
else
  echo "  🔴 失败 —— 解析结果偏离锁文件,或某个包的 content hash 变了:"
  tail -5 /tmp/pubget.log | sed 's/^/     /'
  FAIL=1
fi

echo
echo "=== ② Edge Function:不允许浮动版本 specifier ==="
FLOATING=$(grep -rnE "(jsr|npm):[^'\"]*@[0-9]+['\"]" supabase/functions/ 2>/dev/null || true)
if [ -n "$FLOATING" ]; then
  echo "  🔴 发现 major-only(浮动)依赖:"
  echo "$FLOATING" | sed 's/^/     /'
  echo "     → 改成完整版本,例如 @2.112.3"
  FAIL=1
else
  echo "  ✅ 全部为精确版本"
  grep -rhoE "(jsr|npm):[^'\"]+" supabase/functions/ 2>/dev/null | sort -u | sed 's/^/     /'
fi

echo
echo "=== ③ 锁定版本是否在各函数间保持一致 ==="
VERSIONS=$(grep -rhoE "jsr:@supabase/supabase-js@[0-9.]+" supabase/functions/ 2>/dev/null | sort -u)
COUNT=$(echo "$VERSIONS" | grep -c . || true)
if [ "$COUNT" -gt 1 ]; then
  echo "  ⚠️ 版本不统一(函数间行为可能出现差异):"
  echo "$VERSIONS" | sed 's/^/     /'
  FAIL=1
else
  echo "  ✅ 统一:$VERSIONS"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "供应链检查通过。"
else
  echo "🔴 供应链检查未通过 —— 修好再发版。"
fi
exit $FAIL
