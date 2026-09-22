#!/usr/bin/env bash
# compile_kotlin_check.sh — 把 `android_ready/kotlin/` 整包**真正编一遍**。
#
# 🔴 为什么要有它:`android_ready/README.md` 自述「**No Kotlin has ever been
#    compiled.** No Android SDK, no kotlinc, no JRE on this machine.」——
#    那一句现在过期了(2026-09-22:本机有 Android SDK platform-34、
#    Homebrew kotlin、Homebrew openjdk),所以这些 .kt 第一次有了编译证据。
#
# 它**不是** Gradle 构建。本仓还没有 `android/` 目录(Flutter Android app 从未
# 创建),所以 Gradle 那一层目前无处可跑。这个脚本用 `kotlinc` 直接对着
# `android.jar` + `flutter.jar` 做**类型检查与字节码生成**,能抓到的正是
# README 说「只会在第一次 Gradle 构建时暴露」的那类错(拼错的符号、签名不符、
# 不存在的常量、API level 不对的引用)。抓不到的是资源、manifest 合并、
# R8/proguard、以及任何运行期行为。
#
# 依赖:
#   ANDROID_SDK  ~/Library/Android/sdk        (platform-34 的 android.jar)
#   FLUTTER_ROOT /opt/homebrew/share/flutter  (embedding 的 flutter.jar)
#   kotlinc      /opt/homebrew/opt/kotlin/bin
#   JAVA_HOME    /opt/homebrew/opt/openjdk
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
OUT="${1:-$ROOT/build-kotlin-check}"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk}"
KOTLINC="${KOTLINC:-/opt/homebrew/opt/kotlin/bin/kotlinc}"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
FLUTTER_ROOT="${FLUTTER_ROOT:-/opt/homebrew/share/flutter}"

ANDROID_JAR="$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)"
FLUTTER_JAR="$FLUTTER_ROOT/bin/cache/artifacts/engine/android-arm64/flutter.jar"

[ -f "$ANDROID_JAR" ] || { echo "🔴 android.jar not found under $SDK/platforms"; exit 2; }
[ -f "$FLUTTER_JAR" ] || { echo "🔴 flutter.jar not found: $FLUTTER_JAR"; exit 2; }
[ -x "$KOTLINC" ]     || { echo "🔴 kotlinc not found: $KOTLINC"; exit 2; }

echo "== toolchain =="
"$KOTLINC" -version 2>&1 | head -2
echo "android.jar: $ANDROID_JAR"
echo "flutter.jar: $FLUTTER_JAR"

rm -rf "$OUT"
mkdir -p "$OUT"

# -no-jdk:本机的 JDK 是 25/27,而 Android 的 java.* 由 android.jar 提供。
#   把宿主 JDK 的 rt 拿掉、只留 android.jar,编出来的东西才对得上设备
#   （否则 `java.nio.ByteBuffer` 之类会解析到宿主 JDK 的更新版本签名）。
# -jvm-target 1.8:AGP 对 minSdk 24 的默认档。
echo
echo "== compile =="
"$KOTLINC" \
  -no-jdk \
  -jvm-target 1.8 \
  -classpath "$ANDROID_JAR:$FLUTTER_JAR" \
  -d "$OUT/classes" \
  "$ROOT/kotlin/com/pocketworld/capture"/*.kt

echo
echo "== produced classes =="
find "$OUT/classes" -name '*.class' | sort | sed "s|$OUT/classes/||"

echo
echo "== JNI 声明 vs .so 导出(再核一遍,与 build_transport.sh 同一判据)=="
NM="${ANDROID_NDK_HOME:-/opt/homebrew/share/android-ndk}/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm"
SO="$ROOT/native/xrslam/libs/arm64-v8a/libpw_xrslam_transport.so"
if [ -x "$NM" ] && [ -f "$SO" ]; then
  "$NM" -D --defined-only "$SO" | awk '{print $NF}' \
    | grep '^Java_com_pocketworld_capture_PwXrslamTransport_' | sort > "$OUT/exported.txt"
  "$JAVA_HOME/bin/javap" -classpath "$OUT/classes" -p \
      com.pocketworld.capture.PwXrslamTransport \
    | grep -E '\bnative\b' | sed -E 's/.*[ .]([A-Za-z0-9_]+)\(.*/Java_com_pocketworld_capture_PwXrslamTransport_\1/' \
    | sort > "$OUT/declared.txt"
  diff -u "$OUT/declared.txt" "$OUT/exported.txt" \
    && echo "✅ 编出来的 class 里的 native 方法与 .so 导出一一对应"
else
  echo "⚠️  跳过(缺 llvm-nm 或 .so)"
fi

echo
echo "✅ kotlinc 全绿"
