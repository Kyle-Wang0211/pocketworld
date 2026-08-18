#!/bin/sh
# 供应链完整性检查。
#
# 用法:
#   sh tool/verify_supply_chain.sh              全部检查(本地发版前)
#   sh tool/verify_supply_chain.sh --edge-only  跳过 Flutter(CI 里用,省去装 SDK)
#
# POSIX sh 而非 zsh:CI runner(ubuntu-latest)上没有 zsh。原来那版是
# `#!/bin/zsh`,在 CI 里会直接起不来 —— 一个只在本地能跑的检查脚本,
# 在真正需要它把关的地方是不存在的。
#
# 四项检查,各自对应一个真实的失效模式:
#
#   ① pubspec.lock 只有在 `--enforce-lockfile` 下才真正生效。默认的
#      `flutter pub get` 允许在满足约束的前提下悄悄改变解析结果。
#
#   ② Edge Function 依赖若写成 `@2`,那是 semver **range** 不是固定版本,
#      每次部署都可能解析到不同的 2.x。
#
#   ③ 各函数之间版本必须一致,否则同一份逻辑会有不同行为。
#
#   ④ 【新增】版本号钉死 ≠ 内容钉死。`@2.112.3` 被重新发布成另一份产物,
#      ①②③ 全部照样通过。只有逐包哈希能发现这件事。
#      顺带解决一个更大的盲区:一行 jsr:@supabase/supabase-js 会展开成
#      **9 个**带哈希的包(5 个 npm 传递依赖 + tslib + iceberg-js +
#      phoenix)。②③ 只看得见源码里写出来的那 1 个。

set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0
EDGE_ONLY=0
[ "${1:-}" = "--edge-only" ] && EDGE_ONLY=1

if [ "$EDGE_ONLY" -eq 0 ]; then
  echo "=== ① Flutter 依赖:锁文件必须精确成立 ==="
  if flutter pub get --enforce-lockfile >/tmp/pubget.log 2>&1; then
    echo "  ✅ pubspec.lock 与 pubspec.yaml 一致,且所有 content hash 未变"
  else
    echo "  🔴 失败 —— 解析结果偏离锁文件,或某个包的 content hash 变了:"
    tail -5 /tmp/pubget.log | sed 's/^/     /'
    FAIL=1
  fi
  echo
fi

echo "=== ② Edge Function:不允许浮动版本 specifier ==="
FLOATING=$(grep -rnE "(jsr|npm):[^'\"]*@[0-9]+['\"]" supabase/functions/ 2>/dev/null || true)
if [ -n "$FLOATING" ]; then
  echo "  🔴 发现 major-only(浮动)依赖:"
  echo "$FLOATING" | sed 's/^/     /'
  echo "     → 改成完整版本,例如 @2.112.3"
  FAIL=1
else
  echo "  ✅ 全部为精确版本"
fi

echo
echo "=== ③ 锁定版本是否在各函数间保持一致 ==="
VERSIONS=$(grep -rhoE "jsr:@supabase/supabase-js@[0-9.]+" supabase/functions/ 2>/dev/null | sort -u)
COUNT=$(printf '%s\n' "$VERSIONS" | grep -c . 2>/dev/null || echo 0)
if [ "$COUNT" -gt 1 ]; then
  echo "  ⚠️ 版本不统一(函数间行为可能出现差异):"
  printf '%s\n' "$VERSIONS" | sed 's/^/     /'
  FAIL=1
else
  echo "  ✅ 统一:$VERSIONS"
fi

echo
echo "=== ④ 依赖内容哈希(覆盖传递依赖) ==="
if [ ! -f tool/edge-deps.lock ]; then
  echo "  🔴 tool/edge-deps.lock 缺失。重建:"
  echo "     cd supabase/functions && deno cache --lock=../../tool/edge-deps.lock */index.ts _shared/*.ts"
  FAIL=1
elif ! command -v deno >/dev/null 2>&1; then
  echo "  ⚠️ 未安装 deno —— 哈希校验跳过(这是唯一能发现同版本被替换的检查)"
else
  PKGS=$(grep -c 'integrity' tool/edge-deps.lock 2>/dev/null || echo '?')
  if (cd supabase/functions && deno cache --lock=../../tool/edge-deps.lock --frozen */index.ts _shared/*.ts) >/tmp/denolock.log 2>&1; then
    echo "  ✅ $PKGS 个包的内容哈希与锁文件一致"
  else
    echo "  🔴 哈希不匹配 —— 某个依赖的内容变了(版本号没变):"
    grep -E 'Actual|Expected|Integrity' /tmp/denolock.log | head -6 | sed 's/^/     /'
    FAIL=1
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "供应链检查通过。"
else
  echo "🔴 供应链检查未通过 —— 修好再发版。"
fi
exit $FAIL
