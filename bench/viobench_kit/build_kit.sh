#!/usr/bin/env bash
# Builds dist/{PWVIOBenchKit,PWXRSLAMEngine,PWBasaltEngine}.framework (unsigned; arloopbench's
# "Embed Frameworks" phase signs them). Bench-only. Needs xcodegen (brew) and Xcode 26.2.
# Usage: ./build_kit.sh [scratch dir]   (default: $TMPDIR/pw_viobench_kit_build)
set -euo pipefail
K="$(cd "$(dirname "$0")" && pwd)"
W="${1:-${TMPDIR:-/tmp}/pw_viobench_kit_build}"
rm -rf "$W" && mkdir -p "$W"
# The generated project goes to the scratch dir ($W); --project-root keeps source paths pointing at $K,
# so nothing generated lands in the repo. KIT_ROOT feeds the header / framework search paths.
xcodegen generate --spec "$K/project.yml" --project "$W" --project-root "$K" --quiet
xcodebuild -project "$W/PWVIOBenchKit.xcodeproj" -target PWVIOBenchKit -configuration Release \
  -sdk iphoneos ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  KIT_ROOT="$K" SYMROOT="$W/sym" OBJROOT="$W/obj" DEBUG_INFORMATION_FORMAT=dwarf -quiet
rm -rf "$K/dist" && mkdir -p "$K/dist"
cp -R "$W/sym/Release-iphoneos/PWVIOBenchKit.framework" "$K/dist/"
cp -R "$K/engines/PWXRSLAMEngine.framework" "$K/engines/PWBasaltEngine.framework" "$K/dist/"
# Headers are build inputs only; the embedded copies do not need them.
rm -rf "$K/dist"/*.framework/Headers "$K/dist"/*.framework/Modules
( cd "$K/dist" && find . -type f ! -name SHA256SUMS.txt | LC_ALL=C sort | xargs shasum -a 256 ) > "$W/SHA256SUMS.txt"
mv "$W/SHA256SUMS.txt" "$K/dist/SHA256SUMS.txt"
rm -rf "$W"
echo "built $K/dist"; cat "$K/dist/SHA256SUMS.txt"
