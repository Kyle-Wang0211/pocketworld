#!/bin/zsh
# Patch the embedded thermion_dart.framework so its MinimumOSVersion
# matches our app's deployment target (iOS 13+).
#
# Why: Flutter's iOS build hardcodes IPHONEOS_DEPLOYMENT_TARGET=12.0 in
# the cached engine settings. Thermion's native framework is built
# against iOS 13. Without this patch, App Store Connect rejects the
# upload with "ITMS-90725: SDK version issue. iOS 13.0 required."
#
# Run AFTER `flutter build ios --release` (or `--debug` for local
# Xcode-driven device runs) and BEFORE archiving in Xcode / running
# `xcodebuild archive`.
#
# Source: https://thermion.dev/ios — keep mirrored here so we don't
# have to chase the doc URL on every build.

set -euo pipefail

# Resolve relative to project root, regardless of where the script is
# invoked from (CI, local zsh, Xcode Run Script).
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR}/../.."

directories=(
    "${PROJECT_ROOT}/build/ios/iphoneos/Runner.app/Frameworks/thermion_dart.framework"
    "${PROJECT_ROOT}/build/ios/Release-iphoneos/Runner.app/Frameworks/thermion_dart.framework"
    "${PROJECT_ROOT}/build/native_assets/ios/thermion_dart.framework"
)

patched=0
for dir in "${directories[@]}"; do
    plist_path="$dir/Info.plist"
    if [[ -f "$plist_path" ]]; then
        /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 13.0" "$plist_path"
        echo "  patched $plist_path → MinimumOSVersion=13.0"
        patched=$((patched + 1))
    fi
done

if [[ $patched -eq 0 ]]; then
    echo "thermion_minos_fix: no thermion_dart.framework found yet —"
    echo "  run 'flutter build ios' first, then re-run this script."
    exit 0
fi

echo "thermion_minos_fix: patched $patched framework(s)."
