#!/usr/bin/env bash
# 把 assets/materials/*.mat 编成 *.filamat。
#
# 🔴 matc 必须与运行时引擎**同一个 Filament 版本**。我们经由 thermion 链的是
#    v1.58.0(thermion_dart hook/build.dart:326 `_FILAMENT_VERSION`)。
#    .filamat 里带版本号,版本不匹配 Material::Builder 会直接拒绝。
#
# matc 从哪来:官方 mac 发行包里就有,不需要自己编 Filament。
#   https://github.com/google/filament/releases/download/v1.58.0/filament-v1.58.0-mac.tgz
#   解出来的 filament/bin/matc 即是。
# 装到 $FILAMENT_TOOLS(默认 ~/Developer/filament-tools/filament/bin)。
#
# 编译参数照抄上游样例的构建脚本
#   ios/samples/hello-ar/build-resources.sh:
#       matc --api all --platform mobile -o <out>.filamat <in>.mat
# 「--api all」= 同一个 blob 里同时带 GL/Metal/Vulkan 的着色器,
# 这正是跨端所需(iOS 走 Metal,安卓走 GL/Vulkan,一份产物三端通用)。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILAMENT_TOOLS="${FILAMENT_TOOLS:-$HOME/Developer/filament-tools/filament/bin}"
MATC="$FILAMENT_TOOLS/matc"

if [[ ! -x "$MATC" ]]; then
  echo "matc not found at $MATC" >&2
  echo "Download filament-v1.58.0-mac.tgz and extract filament/bin/matc there." >&2
  exit 1
fi

# 阳性对照:先把版本印出来,免得哪天默默换了版本还以为在编同一份。
"$MATC" --version 2>&1 | sed 's/^/  matc: /' || true

shopt -s nullglob
for src in "$ROOT"/assets/materials/*.mat; do
  out="${src%.mat}.filamat"
  echo "  $(basename "$src") -> $(basename "$out")"
  "$MATC" --api all --platform mobile -o "$out" "$src"
done

echo "done. 产物已就地生成在 assets/materials/,记得在 pubspec.yaml 的 assets: 里声明。"
