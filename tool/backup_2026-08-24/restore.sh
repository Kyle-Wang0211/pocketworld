#!/bin/zsh
# 从 R2 还原完整采集目录树(含全部重复文件)
set -e
B="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${1:-r2}"; BUCKET="${2:-pw-backup}"; DEST="${3:?用法: restore.sh <remote> <bucket> <还原到的目录>}"

echo "▸ 拉取 blobs"
rclone copy "$REMOTE:$BUCKET/blobs" "$B/blobs" --s3-no-check-bucket --no-traverse --transfers 24 --progress

echo "▸ 按清单重建目录树 → $DEST"
n=0; bad=0
while IFS=$'\t' read -r h sz root rel; do
  out="$DEST/$root/$rel"
  mkdir -p "$(dirname "$out")"
  if [ -f "$B/blobs/$h" ]; then
    ln "$B/blobs/$h" "$out" 2>/dev/null || cp "$B/blobs/$h" "$out"
    n=$((n+1))
  else
    echo "  🔴 缺 blob: $h  ($root/$rel)"; bad=$((bad+1))
  fi
done < "$B/manifest.tsv"
echo "  还原 $n 个文件,缺失 $bad"
[ "$bad" -eq 0 ] || exit 1

echo "▸ 逐文件校验 sha256"
f=0
while IFS=$'\t' read -r h sz root rel; do
  a=$(shasum -a 256 "$DEST/$root/$rel" | cut -d' ' -f1)
  [ "$a" = "$h" ] || { echo "  🔴 $root/$rel"; f=$((f+1)); }
done < "$B/manifest.tsv"
[ "$f" -eq 0 ] && echo "  ✅ 全部 $(wc -l < "$B/manifest.tsv" | tr -d ' ') 个文件逐字节正确" || { echo "  🔴 $f 个不符"; exit 1; }
