#!/bin/sh
# 产品源清单 sha256 —— 装机身份 PW_PRODUCT_SOURCE_MANIFEST_SHA256 的唯一配方。
#
# 2026-09-01:build 73 及更早的值是临时算的,配方没记下来,不可复现也不可比。
# 这个脚本把配方固定:对纳入版本控制的产品源(lib/、ios/Runner/、pubspec.yaml)
# 逐文件 sha256,按路径排序后整体 sha256。build 74 起彼此可比;与 73 及更早
# 不可比,这是已知断点。
#
# 静默出口纪律:版本控制里有、工作树里没有的文件(未提交的删除)不能被跳过 ——
# 跳过会让哈希在无人察觉的情况下变。它们以 MISSING 记进哈希输入,所以一定显形。
# 早先一版把这里写成在 while 里 exit,那只退出管道子 shell,rc 仍是 0 —— 本身
# 就是一个静默出口。
set -eu
cd "$(dirname "$0")/.."
git ls-files lib ios/Runner pubspec.yaml \
  | LC_ALL=C sort \
  | while IFS= read -r f; do
      if [ -f "$f" ]; then
        printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
      else
        printf 'MISSING  %s\n' "$f"
      fi
    done \
  | /usr/bin/shasum -a 256 \
  | cut -d' ' -f1
