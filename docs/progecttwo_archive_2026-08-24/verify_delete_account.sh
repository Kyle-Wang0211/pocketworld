#!/bin/zsh
# A4 端到端验证:证明账号删除真的删干净了(业务行级联 + storage 文件),
# 而不是只清了本地 session。
#
# 🔒 安全设计:本脚本**自己创建一个一次性测试账号**并只删那一个。
#    它绝不会碰你的真实账号 —— 每一步都会打印目标 user_id,你可以核对。
#    测试邮箱用 .invalid 顶级域(RFC 2606 保留),不会真的发出任何邮件。
#
# 用法:
#   export SUPABASE_SERVICE_ROLE_KEY="eyJ...(Dashboard → Settings → API)"
#   zsh verify_delete_account.sh

set -euo pipefail
REF="tzvwkqmgaourwqrmxbyb"
BASE="https://${REF}.supabase.co"
SRV="${SUPABASE_SERVICE_ROLE_KEY:?请先 export SUPABASE_SERVICE_ROLE_KEY}"
STAMP=$(date +%s)
EMAIL="pw-delete-test-${STAMP}@example.invalid"

j() { python3 -m json.tool 2>/dev/null || cat; }

echo "① 用 service_role 创建一次性测试账号:$EMAIL"
CREATED=$(curl -s -X POST "${BASE}/auth/v1/admin/users" \
  -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"TestOnly-${STAMP}!\",\"email_confirm\":true}")
UID_=$(echo "$CREATED" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
[ -z "$UID_" ] && { echo "创建失败:"; echo "$CREATED" | j; exit 1; }
echo "   ✅ 测试 user_id = $UID_"
echo "   ⚠️  下面所有删除操作只针对这个 id。请核对它不是你自己的账号。"

echo "\n② 给它造一点可验证的数据:上传一个 storage 文件"
TESTPATH="${UID_}/a4-verify-${STAMP}.ply"
printf 'ply\nformat ascii 1.0\nelement vertex 0\nend_header\n' > /tmp/a4_test.ply
curl -s -X POST "${BASE}/storage/v1/object/works/${TESTPATH}" \
  -H "Authorization: Bearer ${SRV}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @/tmp/a4_test.ply -o /dev/null -w "   上传 HTTP %{http_code}\n"

echo "   插入一个 works 行指向它"
curl -s -X POST "${BASE}/rest/v1/works" \
  -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"user_id\":\"${UID_}\",\"title\":\"A4 verify\",\"format\":\"ply\",\"model_storage_path\":\"${TESTPATH}\",\"visibility\":\"private\"}" \
  -o /dev/null -w "   插入 works HTTP %{http_code}\n"

echo "\n③ 删除前确认三样东西都存在"
echo -n "   profiles 行数: "
curl -s "${BASE}/rest/v1/profiles?select=id&id=eq.${UID_}" -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)))"
echo -n "   works 行数:    "
curl -s "${BASE}/rest/v1/works?select=id&user_id=eq.${UID_}" -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)))"
curl -s -o /dev/null -w "   storage 文件:  HTTP %{http_code}(期望 200)\n" \
  "${BASE}/storage/v1/object/works/${TESTPATH}" -H "Authorization: Bearer ${SRV}"

echo "\n④ 调 delete-account(service_role 路径,指定 target_user_id)……"
curl -s -X POST "${BASE}/functions/v1/delete-account" \
  -H "Authorization: Bearer ${SRV}" -H "Content-Type: application/json" \
  -d "{\"target_user_id\":\"${UID_}\"}" | j

echo "\n⑤ 删除后:三样都应该没了(🔑 这才是'真删'的判据)"
sleep 2
echo -n "   profiles 行数: "
curl -s "${BASE}/rest/v1/profiles?select=id&id=eq.${UID_}" -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)),'(期望 0)')"
echo -n "   works 行数:    "
curl -s "${BASE}/rest/v1/works?select=id&user_id=eq.${UID_}" -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)),'(期望 0)')"
curl -s -o /dev/null -w "   storage 文件:  HTTP %{http_code}(期望 4xx)\n" \
  "${BASE}/storage/v1/object/works/${TESTPATH}" -H "Authorization: Bearer ${SRV}"
echo -n "   auth 用户:     "
curl -s "${BASE}/auth/v1/admin/users/${UID_}" -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" \
  -o /dev/null -w "HTTP %{http_code}(期望 404)\n"

echo "\n⑥ 审计行应保留(故意无外键,支持删除后追溯)"
curl -s "${BASE}/rest/v1/audit_logs?select=action,metadata&target_id=eq.${UID_}&action=eq.user.account_deleted" \
  -H "Authorization: Bearer ${SRV}" -H "apikey: ${SRV}" | j

rm -f /tmp/a4_test.ply
echo "\n完成。若 ⑤ 全为 0/4xx/404 且 ⑥ 有一条审计记录,则 A4 端到端闭环成立。"
