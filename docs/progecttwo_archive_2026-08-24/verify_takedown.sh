#!/bin/zsh
# A1 端到端验证:证明"下架"在 CDN/存储层真正生效(文件变 404),而不只是数据库改了个字段。
#
# 用法:
#   export SUPABASE_SERVICE_ROLE_KEY="eyJ...(从 Supabase Dashboard → Settings → API 复制)"
#   zsh verify_takedown.sh
#
# 安全:脚本只从环境变量读 key,不写盘、不打印 key。跑完后 `unset SUPABASE_SERVICE_ROLE_KEY`。
# 它会挑一个你自己的公开作品做下架→验证→恢复的完整往返,结束后作品恢复原状。

set -euo pipefail
REF="tzvwkqmgaourwqrmxbyb"
BASE="https://${REF}.supabase.co"
ANON="sb_publishable_ur4tTV2iXSV4NsL3YYttyw_SIjFAMST"
SRV="${SUPABASE_SERVICE_ROLE_KEY:?请先 export SUPABASE_SERVICE_ROLE_KEY}"

echo "① 找一个公开且状态正常的作品……"
WORK=$(curl -s "${BASE}/rest/v1/works?select=id,model_storage_path,thumbnail_storage_path&visibility=eq.public&moderation_status=eq.ok&limit=1" \
  -H "apikey: ${ANON}" -H "Authorization: Bearer ${SRV}")
WID=$(echo "$WORK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
MPATH=$(echo "$WORK" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0].get('model_storage_path','') if d else '')")
[ -z "$WID" ] && { echo "  没有可测的公开作品,先发布一个再来。"; exit 1; }
echo "  work_id=$WID"
echo "  model=$MPATH"

MURL="${BASE}/storage/v1/object/public/works/${MPATH}"
echo "\n② 下架前:文件应可下载(期望 200)"
curl -s -o /dev/null -w "   模型文件 HTTP %{http_code}\n" "$MURL"

echo "\n③ 调 admin-moderate-work 下架(status=removed)……"
curl -s -X POST "${BASE}/functions/v1/admin-moderate-work" \
  -H "Authorization: Bearer ${SRV}" -H "Content-Type: application/json" \
  -d "{\"work_id\":\"${WID}\",\"status\":\"removed\",\"reason\":\"A1 端到端验证\"}" | python3 -m json.tool

echo "\n④ 下架后:文件应变 404/400(🔑 这是'下架真正生效'的判据)"
sleep 2
curl -s -o /dev/null -w "   模型文件 HTTP %{http_code}(期望 4xx)\n" "$MURL"

echo "\n⑤ feed 查询应看不到该作品(RLS 过滤)"
CNT=$(curl -s "${BASE}/rest/v1/works?select=id&id=eq.${WID}&visibility=eq.public&moderation_status=eq.ok" \
  -H "apikey: ${ANON}" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")
echo "   公开可见行数=$CNT(期望 0)"

echo "\n⑥ 恢复(status=ok),把作品还原……"
curl -s -X POST "${BASE}/functions/v1/admin-moderate-work" \
  -H "Authorization: Bearer ${SRV}" -H "Content-Type: application/json" \
  -d "{\"work_id\":\"${WID}\",\"status\":\"ok\",\"reason\":\"验证结束,恢复\"}" | python3 -m json.tool

echo "\n⑦ 恢复后:文件应重新可下载(期望 200)"
sleep 2
curl -s -o /dev/null -w "   模型文件 HTTP %{http_code}(期望 200)\n" "$MURL"

echo "\n完成。若 ④ 是 4xx 且 ⑦ 是 200,则 A1 端到端闭环成立。"
