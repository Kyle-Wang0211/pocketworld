#!/bin/zsh
# 把去重后的采集素材推到 Cloudflare R2(免费额度 10GB,本备份 2.0GB)
set -e
B="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${1:-r2}"          # rclone remote 名
BUCKET="${2:-pw-backup}"   # bucket 名

echo "▸ 上传 blobs(1878 个唯一对象,约 2.0 GB)"
rclone copy "$B/blobs" "$REMOTE:$BUCKET/blobs" \
  --transfers 16 --checkers 32 --progress --no-traverse

echo "▸ 上传清单"
rclone copy "$B/manifest.tsv" "$REMOTE:$BUCKET/"
rclone copy "$B/restore.sh"   "$REMOTE:$BUCKET/"
rclone copy "$B/README.md"    "$REMOTE:$BUCKET/"

echo "▸ 校验:远端对象数应为 1878"
n=$(rclone size "$REMOTE:$BUCKET/blobs" --json | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
echo "  远端 blob 数: $n"
[ "$n" = "1878" ] && echo "  ✅ 一致" || { echo "  🔴 不一致,重跑 upload.sh"; exit 1; }
