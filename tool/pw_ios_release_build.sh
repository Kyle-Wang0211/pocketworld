#!/bin/sh
# 生产 iOS release 构建(出包配方)—— build 171 起用它,不再手敲。
#
# 配方来源 = 台账 ~/Developer/pw_builds_20260904/README.md 里 157/159/169/170 的出包记录:
#   PW_PRODUCT_SOURCE_MANIFEST_SHA256=<tool/product_source_manifest.sh>
#   PW_DIAGNOSTIC_BUILD_ID=<号-标签>  PW_VIO_SHADOW_MODE=off
#   flutter build ios --release --no-codesign --no-pub
#   XDG_CONFIG_HOME 隔离(复制原 settings)
# 本脚本只做两处更正,别的一字不改:
#
# 🔴 更正 1(2026-09-24 查实):XDG 隔离的 settings 放错过位置。
#   Flutter 3.47.1 flutter_tools/lib/src/base/config.dart:200-207 —— 设了 XDG_CONFIG_HOME 时读的是
#   `$XDG_CONFIG_HOME/settings`,不是 `$XDG_CONFIG_HOME/flutter/settings`(那是没设 XDG 时的
#   `~/.config/flutter/settings` 形状)。放错 ⇒ 所有设置变 Not set ⇒ `enable-swift-package-manager`
#   从 false 变成默认开 ⇒ 插件被迁到 SwiftPM:pod install 改写 ios/Podfile.lock(−113 行)与
#   project.pbxproj(删掉「[CP] Copy Pods Resources」),资源包全改名(161 → 186 个文件),
#   Runner 与 168 不再同构。169/170 当时就是这样编的,只因为两次都只把 App.framework 换进 168 的包
#   才没出事。
#   ⇒ 本脚本把 settings 放到 `$XDG_CONFIG_HOME/settings`,并且**先过闸**:
#      `flutter config --list` 必须出现 `enable-swift-package-manager: false`,否则不编。
#
# 更正 2:构建前后都核 git 工作树。pod install / flutter 会改已跟踪文件(上面那次就是),
#   构建前不干净不编;构建后已跟踪文件有任何改动 ⇒ 判失败(产物不可信),改动留着给人看,不自动还原。
#
# 用法:
#   tool/pw_ios_release_build.sh <build-number> <diagnostic-build-id> <xdg-dir>
#   例:tool/pw_ios_release_build.sh 171 171-lod-viewer /private/tmp/.../xdg
#   PW_FLUTTER_SETTINGS_SRC 可覆盖要复制的原 settings(默认 ~/.config/flutter/settings)。
#   PW_RELEASE_GATE_ONLY=1 只跑 XDG 闸不编(给闸自己的阴性对照用)。
set -eu
cd "$(dirname "$0")/.."

[ $# -eq 3 ] || { echo "用法: $0 <build-number> <diagnostic-build-id> <xdg-dir>" >&2; exit 64; }
build_number="$1"
build_id="$2"
xdg="$3"
settings_src="${PW_FLUTTER_SETTINGS_SRC:-$HOME/.config/flutter/settings}"

# ── XDG 隔离 + 闸 ───────────────────────────────────────────────────────
mkdir -p "$xdg"
# 只跑闸时不动 xdg 里现有的东西(阴性对照要检的就是「放错位置」的那个布局)。
[ "${PW_RELEASE_GATE_ONLY:-0}" = "1" ] || cp "$settings_src" "$xdg/settings"
config_list="$(XDG_CONFIG_HOME="$xdg" flutter config --list 2>/dev/null || true)"
if ! printf '%s\n' "$config_list" | grep -q '^ *enable-swift-package-manager: false$'; then
  echo "🔴 XDG 闸不过:$xdg 下 flutter config --list 没有 'enable-swift-package-manager: false'" >&2
  printf '%s\n' "$config_list" | grep -i 'swift-package' >&2 || true
  echo "   (settings 必须在 \$XDG_CONFIG_HOME/settings,不是 \$XDG_CONFIG_HOME/flutter/settings)" >&2
  exit 65
fi
echo "✓ XDG 闸:enable-swift-package-manager: false"
[ "${PW_RELEASE_GATE_ONLY:-0}" = "1" ] && exit 0

# ── 构建前工作树 ────────────────────────────────────────────────────────
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "🔴 已跟踪文件有未提交改动,不编(出包必须对应一个提交):" >&2
  git status --short --untracked-files=no >&2
  exit 66
fi

manifest="$(sh tool/product_source_manifest.sh)"
head="$(git rev-parse HEAD)"
echo "PW_RELEASE_BUILD head=$head manifest=$manifest build=$build_number id=$build_id"

XDG_CONFIG_HOME="$xdg" \
PW_PRODUCT_SOURCE_MANIFEST_SHA256="$manifest" \
PW_DIAGNOSTIC_BUILD_ID="$build_id" \
PW_VIO_SHADOW_MODE=off \
  flutter build ios --release --no-codesign --no-pub --build-number "$build_number"

# ── 构建后工作树 ────────────────────────────────────────────────────────
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "🔴 构建改了已跟踪文件 ⇒ 产物不可信(多半是 pod install / SwiftPM 迁移):" >&2
  git status --short --untracked-files=no >&2
  exit 67
fi
untracked="$(git status --porcelain | grep '^??' || true)"
if [ -n "$untracked" ]; then
  echo "⚠️ 构建后多出未跟踪文件(列出,不判失败):" >&2
  printf '%s\n' "$untracked" >&2
fi
echo "PW_RELEASE_BUILD_OK head=$head manifest=$manifest"
