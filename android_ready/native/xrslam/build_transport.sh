#!/usr/bin/env bash
# build_transport.sh — 编 `libpw_xrslam_transport.so`(JNI glue + 跨端 C++ 传输层)
# 并做三道**静态自证**。不需要 Gradle、不需要 Android Studio,只要 NDK + cmake + ninja。
#
# 🔴 为什么要有这个脚本:`android_ready/README.md` 自述 Kotlin 从未编译过,而
#    `.so` 是**某次没有留下命令的构建**的产物(`core_build_receipt.json` 标
#    `artifactProvenanceStatus: "pending_deterministic_rebuild"`)。
#    2026-09-22 给 JNI 加了三个出口(CreateWithCameraTimeOffset /
#    GetLastTimestampTrace / GetCounters),旧 `.so` 里没有它们 ⇒ 必须重编,
#    而重编就必须留下配方。
#
# 三道闸:
#   (1) 编译链接全绿。
#   (2) **符号闸** —— `nm -D` 出来的 `Java_com_pocketworld_capture_*` 必须与
#       `kotlin/com/pocketworld/capture/PwXrslamTransport.kt` 里声明的
#       `external fun native*` 一一对应。「绑定存在 ≠ 符号存在」在这个仓里
#       已经踩过三次(2026-09-19),所以这一条不是可选项。
#   (3) 16 KB 页对齐 —— `scripts/check_elf_align.py`。Google 的死线是
#       2027-02-01,而 `zipalign` 那条命令抓不到**预编译库**的段对齐。
#
# 用法:
#   ANDROID_NDK_HOME=/opt/homebrew/share/android-ndk ./build_transport.sh [builddir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${1:-$HERE/build-transport}"
NDK="${ANDROID_NDK_HOME:-/opt/homebrew/share/android-ndk}"
ABI="${ANDROID_ABI:-arm64-v8a}"
# API 24 = `core_build_receipt.json` 的 androidApi,必须一致,否则 JNI 侧与
# 核心库的 libc 期望不同档。
API="${ANDROID_PLATFORM:-24}"

[ -d "$NDK" ] || { echo "🔴 NDK not found: $NDK"; exit 2; }
CORE="$HERE/libs/$ABI/libxrslam_generic_4beb1a9.so"
[ -f "$CORE" ] || { echo "🔴 prebuilt core missing: $CORE (untracked, 341 MB)"; exit 2; }

echo "== (0) toolchain =="
"$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang" --version | head -2
cmake --version | head -1
ninja --version

echo "== (1) configure + build =="
rm -rf "$BUILD"
cmake -S "$HERE" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j

SO="$BUILD/libpw_xrslam_transport.so"
[ -f "$SO" ] || { echo "🔴 no artifact at $SO"; exit 1; }
file "$SO"
shasum -a 256 "$SO"

echo "== (2) 符号闸:JNI 出口 vs Kotlin external 声明 =="
NM="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm"
"$NM" -D --defined-only "$SO" | awk '{print $NF}' \
  | grep '^Java_com_pocketworld_capture_PwXrslamTransport_' | sort > "$BUILD/exported.txt"
grep -o 'external fun native[A-Za-z0-9_]*' \
  "$HERE/../../kotlin/com/pocketworld/capture/PwXrslamTransport.kt" \
  | sed 's/external fun /Java_com_pocketworld_capture_PwXrslamTransport_/' | sort > "$BUILD/declared.txt"
echo "-- exported --"; cat "$BUILD/exported.txt"
echo "-- declared --"; cat "$BUILD/declared.txt"
if ! diff -u "$BUILD/declared.txt" "$BUILD/exported.txt"; then
  echo "🔴 符号闸失败:Kotlin 声明与 .so 导出不一致"
  exit 1
fi
echo "✅ 符号闸通过 ($(wc -l < "$BUILD/exported.txt") 个)"

echo "== (3) 16 KB 页对齐 =="
python3 "$HERE/../../scripts/check_elf_align.py" "$SO"

echo "== (4) 未定义符号必须全部由核心库/NDK 提供 =="
"$NM" -D --undefined-only "$SO" | awk '{print $NF}' | grep '^XRSLAM' | sort -u \
  > "$BUILD/needed_xrslam.txt" || true
cat "$BUILD/needed_xrslam.txt"
"$NM" -D --defined-only "$CORE" | awk '{print $NF}' | grep '^XRSLAM' | sort -u \
  > "$BUILD/core_exports.txt"
missing="$(comm -23 "$BUILD/needed_xrslam.txt" "$BUILD/core_exports.txt" || true)"
if [ -n "$missing" ]; then
  echo "🔴 核心库没有这些符号: $missing"
  exit 1
fi
echo "✅ 引擎符号全部由 $(basename "$CORE") 提供"

echo
echo "产物: $SO"
