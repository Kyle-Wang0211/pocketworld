#!/bin/bash
# check171.sh <app> — pre-install checks for build 171. Every check prints PASS/FAIL; run it on
# 171 (all must PASS) and on 168 (the LOD/identity checks must FAIL there = negative control).
set -uo pipefail
APP="$1"
BASE=~/Developer/pw_builds_20260904/Runner-168-feature-reuse.app
T=$(mktemp -d)
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
unsigned_sha() { cp "$1" "$T/u"; codesign --remove-signature "$T/u" 2>/dev/null; shasum -a 256 "$T/u" | cut -d' ' -f1; }

# 1 bundle id
bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
[ "$bid" = com.kyle.PocketWorld ] && ok "bundle id $bid" || bad "bundle id $bid"

# 2 signature
codesign --verify --deep --strict "$APP" 2>"$T/cs" && ok "codesign --verify --deep --strict" || bad "codesign: $(cat "$T/cs")"
codesign -d --entitlements - "$APP" 2>/dev/null | plutil -p - > "$T/e1" 2>/dev/null
codesign -d --entitlements - "$BASE" 2>/dev/null | plutil -p - > "$T/e0" 2>/dev/null
cmp -s "$T/e0" "$T/e1" && ok "entitlements == 168" || bad "entitlements differ from 168"
auth=$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1)
echo "     signer: $auth"

# 3 LOD entry points + version string in Runner
nm -m "$APP/Runner" > "$T/nm" 2>/dev/null
for s in pwlod_viewer_create pwlod_build_from_ply pwlod_verify_octree pwlod_version pwlod_viewer_set_points pwlod_viewer_set_style; do
  grep -q " _$s\$" "$T/nm" && grep " _$s\$" "$T/nm" | grep -vq undefined && ok "Runner defines _$s" || bad "Runner lacks _$s"
done
strings -a "$APP/Runner" > "$T/str"
grep -qx '72ee817f abi=3' "$T/str" && ok 'version string "72ee817f abi=3"' || bad 'version string "72ee817f abi=3" missing'
grep -q ' _pwlod_run$' "$T/nm" && bad "M1 pwlod_run linked into Runner" || ok "pwlod_run (M1) not in Runner"

# 4 wgpuCreateInstance definitions per image, compared with 168
for img in Runner Frameworks/App.framework/App Frameworks/Flutter.framework/Flutter \
    Frameworks/PWDense.framework/PWDense Frameworks/PWOfficialSfm.framework/PWOfficialSfm \
    Frameworks/PWOnnxRuntime.framework/PWOnnxRuntime Frameworks/thermion_dart.framework/thermion_dart; do
  n1=$(nm -m "$APP/$img" 2>/dev/null | grep ' _wgpuCreateInstance$' | grep -vc undefined)
  n0=$(nm -m "$BASE/$img" 2>/dev/null | grep ' _wgpuCreateInstance$' | grep -vc undefined)
  if [ "$img" = Runner ]; then
    [ "$n1" = 1 ] && ok "Runner defines wgpuCreateInstance once (168: $n0)" || bad "Runner defines wgpuCreateInstance $n1 times"
  else
    [ "$n1" = "$n0" ] && ok "$img wgpuCreateInstance defs $n1 == 168" || bad "$img wgpuCreateInstance $n1 vs 168 $n0"
  fi
done
w1=$(grep -v undefined "$T/nm" | grep -c ' _wgpu[A-Z][A-Za-z]*$')
w0=$(nm -m "$BASE/Runner" | grep -v undefined | grep -c ' _wgpu[A-Z][A-Za-z]*$')
echo "     Runner defined _wgpu* : $w1 (168: $w0)"

# 5 Dart AOT: LOD classes reachable, debug page not
strings -a "$APP/Frameworks/App.framework/App" > "$T/aot"
for c in GpuCloudLayer DenseLodCache LodBridge LodStyle; do
  grep -qx "$c" "$T/aot" && ok "App.framework has class $c" || bad "App.framework lacks $c"
done
grep -q 'LodDebugPage' "$T/aot" && bad "LodDebugPage reachable" || ok "LodDebugPage not in App.framework"
grep -qx 'SparseCloudPainter' "$T/aot" && ok "positive control: SparseCloudPainter present" || bad "SparseCloudPainter missing (grep broken?)"

# 6 identity stamps = this bundle's truth
p() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null; }
[ "$(p PWDartAOTSHA256)" = "$(shasum -a 256 "$APP/Frameworks/App.framework/App" | cut -d' ' -f1)" ] && ok "PWDartAOTSHA256 = App bytes in bundle" || bad "PWDartAOTSHA256 stale"
[ "$(p PWOfficialSfmSHA256)" = "$(shasum -a 256 "$APP/Frameworks/PWOfficialSfm.framework/PWOfficialSfm" | cut -d' ' -f1)" ] && ok "PWOfficialSfmSHA256 = PWOfficialSfm bytes in bundle" || bad "PWOfficialSfmSHA256 stale"
uuid=$(xcrun dwarfdump --uuid "$APP/Runner" | awk '$1=="UUID:"{print $2}')
[ "$(p PWNativeHostUUID)" = "$uuid" ] && ok "PWNativeHostUUID = Runner LC_UUID $uuid" || bad "PWNativeHostUUID $(p PWNativeHostUUID) vs $uuid"
[ "$(p CFBundleVersion)" = 171 ] && ok "CFBundleVersion 171" || bad "CFBundleVersion $(p CFBundleVersion)"
p PWBuildExperimentMarker | grep -q 'lod-one-viewer-v3$' && ok "experiment marker names the change" || bad "experiment marker lacks lod-one-viewer-v3"
[ "$(p PWLiveCloudDiagnosticBuildId)" = 171-lod-viewer ] && ok "PWLiveCloudDiagnosticBuildId 171-lod-viewer" || bad "PWLiveCloudDiagnosticBuildId $(p PWLiveCloudDiagnosticBuildId)"
echo "     PWProductSourceManifestSHA256 $(p PWProductSourceManifestSHA256)"
/usr/libexec/PlistBuddy -c 'Print :UISupportedInterfaceOrientations' "$APP/Info.plist" | grep -c Interface | grep -qx 1 && ok "iPhone portrait lock kept" || bad "orientation not portrait-only"

# 7 other frameworks == 168 (signature removed)
for fw in Flutter PWDense PWOfficialSfm PWOnnxRuntime thermion_dart; do
  a=$(unsigned_sha "$BASE/Frameworks/$fw.framework/$fw"); b=$(unsigned_sha "$APP/Frameworks/$fw.framework/$fw")
  [ "$a" = "$b" ] && ok "$fw == 168 (unsigned ${a:0:12})" || bad "$fw differs from 168 ${a:0:12} ${b:0:12}"
done

rm -rf "$T"
echo "FAILS=$fails"
