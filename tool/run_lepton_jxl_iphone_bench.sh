#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input=${1:-}
device=${PW_BENCH_DEVICE_ID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}
bundle_id=com.kyle.PocketWorld.LeptonBench
team_id=${PW_BENCH_TEAM_ID:-26AH7V448L}
signing_identity=${PW_BENCH_CODE_SIGN_IDENTITY:-1C30FFB54D965CA96917C5EC0DC4B34F9EDDA775}
provisioning_profile=${PW_BENCH_PROVISIONING_PROFILE:-/Users/kaidongwang/Library/Developer/Xcode/UserData/Provisioning Profiles/edc53ec5-7583-45da-8044-de6a9a1885c2.mobileprovision}
run_id=$(date -u +%Y%m%dT%H%M%SZ)
expected_input_bytes=2725495
expected_input_sha=a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138

if [ -z "$input" ] || [ ! -f "$input" ]; then
  echo "usage: $0 /absolute/path/to/frozen-original.jpg" >&2
  exit 64
fi

input=$(CDPATH= cd -- "$(dirname -- "$input")" && pwd)/$(basename -- "$input")
input_bytes=$(stat -f %z "$input")
input_sha=$(/usr/bin/shasum -a 256 "$input" | /usr/bin/awk '{print $1}')
if [ "$input_bytes" -ne "$expected_input_bytes" ] || \
  [ "$input_sha" != "$expected_input_sha" ]; then
  echo "refusing wrong benchmark input: bytes=$input_bytes sha256=$input_sha" >&2
  exit 1
fi

task_root=$(mktemp -d /private/tmp/pw-lepton-jxl-iphone.XXXXXX)
config_root="$task_root/config"
derived_data="$task_root/DerivedData"
build_dir="$task_root/build"
obj_root="$task_root/obj"
lepton_build_root="$task_root/lepton-arm64"
decoded_profile="$task_root/provisioning-profile.plist"
benchmark_entitlements="$task_root/LeptonBench.entitlements"
downloaded_result="$task_root/lepton_jxl_benchmark_result.json"
mkdir -p "$config_root" "$build_dir" "$obj_root" "$lepton_build_root"

if [ ! -f "$provisioning_profile" ]; then
  echo "independent benchmark provisioning profile is missing" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | \
  /usr/bin/grep -q "$signing_identity"; then
  echo "independent benchmark signing identity is unavailable" >&2
  exit 1
fi

cd "$repo_root"
./tool/build_lepton_ios.sh "$lepton_build_root"
lepton_archive="$lepton_build_root/libpw_lepton_jpeg_ffi.a"
lepton_archive_sha=$(/usr/bin/shasum -a 256 "$lepton_archive" | \
  /usr/bin/awk '{print $1}')

XDG_CONFIG_HOME="$config_root" flutter build ios \
  --release \
  --no-pub \
  --config-only \
  --target=lib/lepton_jxl_benchmark_main.dart \
  --dart-define="PW_LEPTON_BENCH_RUN_ID=$run_id" \
  --build-number=2026080201

xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  FLUTTER_TARGET=lib/lepton_jxl_benchmark_main.dart \
  "OTHER_LDFLAGS=\$(inherited) -force_load $lepton_archive -Wl,-u,_pw_lepton_version -Wl,-u,_pw_lepton_revision -Wl,-u,_pw_lepton_error_message -Wl,-u,_pw_lepton_encode_jpeg_file -Wl,-u,_pw_lepton_reconstruct_jpeg_file -Wl,-u,_pw_lepton_cancellation_generation -Wl,-u,_pw_lepton_request_cancel -Wl,-u,_pw_lepton_encode_jpeg_file_cancellable -Wl,-u,_pw_lepton_reconstruct_jpeg_file_cancellable" \
  BUILD_DIR="$build_dir" \
  OBJROOT="$obj_root" \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGNING_ALLOWED=NO \
  build

app="$build_dir/Release-iphoneos/Runner.app"
if [ ! -d "$app" ]; then
  echo "independent benchmark app was not produced" >&2
  exit 1
fi
actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$app/Info.plist")
if [ "$actual_bundle" != "$bundle_id" ]; then
  echo "refusing install: bundle id is $actual_bundle" >&2
  exit 1
fi
/usr/libexec/PlistBuddy \
  -c "Add :PWLeptonBenchmarkRunID string $run_id" \
  "$app/Info.plist"
mkdir -p "$app/LeptonLicenses"
/usr/bin/ditto "$lepton_build_root/Lepton-LICENSE.txt" \
  "$app/LeptonLicenses/LICENSE.txt"
/usr/bin/ditto "$lepton_build_root/Lepton-NOTICE.txt" \
  "$app/LeptonLicenses/NOTICE.txt"
/usr/bin/lipo -info "$app/Runner" | /usr/bin/grep -q 'arm64'
/usr/bin/nm -gU "$app/Runner" | \
  /usr/bin/grep -q '_pw_lepton_encode_jpeg_file'
/usr/bin/nm -gU "$app/Runner" | \
  /usr/bin/grep -q '_pw_lepton_reconstruct_jpeg_file'
/usr/bin/nm -gU "$app/Runner" | \
  /usr/bin/grep -q '_pw_jxl_encode_jpeg_file'
/usr/bin/nm -gU "$app/Runner" | \
  /usr/bin/grep -q '_pw_jxl_reconstruct_jpeg_file'

security cms -D -i "$provisioning_profile" > "$decoded_profile"
profile_app_id=$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:application-identifier' \
  "$decoded_profile")
if [ "$profile_app_id" != "$team_id.*" ]; then
  echo "refusing sign: benchmark profile is not the expected wildcard profile" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.developer.kernel.extended-virtual-addressing' \
  "$decoded_profile" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.kernel.increased-memory-limit' \
    "$decoded_profile" >/dev/null 2>&1; then
  echo "refusing sign: benchmark profile grants production memory entitlements" >&2
  exit 1
fi
plutil -extract Entitlements xml1 -o "$benchmark_entitlements" \
  "$decoded_profile"
/usr/libexec/PlistBuddy \
  -c "Set :application-identifier $team_id.$bundle_id" \
  "$benchmark_entitlements"
/usr/libexec/PlistBuddy \
  -c "Set :keychain-access-groups:0 $team_id.$bundle_id" \
  "$benchmark_entitlements"
/usr/bin/ditto "$provisioning_profile" "$app/embedded.mobileprovision"
find "$app/Frameworks" -type f -name '*.dylib' -print0 | \
  while IFS= read -r -d '' binary; do
    codesign --force --sign "$signing_identity" --timestamp=none "$binary"
  done
find "$app/Frameworks" -type d -name '*.framework' -print0 | \
  while IFS= read -r -d '' framework; do
    codesign --force --sign "$signing_identity" --timestamp=none "$framework"
  done
codesign \
  --force \
  --sign "$signing_identity" \
  --entitlements "$benchmark_entitlements" \
  --timestamp=none \
  "$app"
codesign --verify --deep --strict "$app"

app_binary_sha=$(/usr/bin/shasum -a 256 "$app/Runner" | \
  /usr/bin/awk '{print $1}')
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device copy to \
  --device "$device" \
  --source "$input" \
  --destination Documents/benchmark_input.jpg \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id"
xcrun devicectl device process launch \
  --terminate-existing \
  --device "$device" \
  "$bundle_id"

attempt=0
while [ "$attempt" -lt 180 ]; do
  attempt=$((attempt + 1))
  if xcrun devicectl device copy from \
    --device "$device" \
    --source Documents/lepton_jxl_benchmark_result.json \
    --destination "$downloaded_result" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" >/dev/null 2>&1; then
    observed_run=$(/usr/bin/python3 -c \
      'import json,sys; print(json.load(open(sys.argv[1])).get("run_id", ""))' \
      "$downloaded_result" 2>/dev/null || true)
    status=$(/usr/bin/python3 -c \
      'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' \
      "$downloaded_result" 2>/dev/null || true)
    if [ "$observed_run" = "$run_id" ]; then
      echo "BENCH_PROGRESS status=$status attempt=$attempt/180"
      if [ "$status" = passed ] || [ "$status" = not_eligible ] || \
        [ "$status" = failed ]; then
        break
      fi
    fi
  else
    echo "BENCH_PROGRESS status=starting attempt=$attempt/180"
  fi
  sleep 10
done

if [ ! -f "$downloaded_result" ]; then
  echo "physical-iPhone benchmark produced no result" >&2
  exit 1
fi

validation_status=0
/usr/bin/python3 - \
  "$downloaded_result" "$run_id" "$device" "$input_bytes" "$input_sha" <<'PY' || validation_status=$?
import json
import sys

result_path, run_id, device, expected_bytes, expected_sha = sys.argv[1:]
result = json.load(open(result_path))
assert result["run_id"] == run_id
assert result["bundle_id"] == "com.kyle.PocketWorld.LeptonBench"
assert result["source_bytes"] == int(expected_bytes) == 2725495
assert result["source_sha256"] == expected_sha
assert expected_sha == "a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138"
for name in ("jxl", "lepton"):
    arm = result[name]
    assert arm["restored_bytes"] == int(expected_bytes)
    assert arm["restored_sha256"] == expected_sha
    assert arm["byte_equal"] is True
    assert arm["sha256_equal"] is True
    assert arm["exact"] is True
jxl_archive_bytes = result["jxl"]["archive_bytes"]
lepton_archive_bytes = result["lepton"]["archive_bytes"]
assert result["lepton"]["codec_version"] == "0.5.8"
assert result["lepton"]["codec_revision"] == "90fdc27828676892fbb41777cfcc6bad1e470516"
assert result["jxl"]["codec_version"] == "0.12.0"
if not (lepton_archive_bytes < jxl_archive_bytes):
    assert result["production_eligible"] is False
    print("IPHONE_LEPTON_JXL_AB_NOT_ELIGIBLE")
    sys.exit(3)
assert result["status"] == "passed"
assert result["production_eligible"] is True
assert result["winner"] == "lepton"
print("IPHONE_LEPTON_JXL_AB_OK")
PY

echo "BENCH_BUNDLE_ID=$bundle_id"
echo "BENCH_RUN_ID=$run_id"
echo "BENCH_DEVICE=$device"
echo "BENCH_INPUT_BYTES=$input_bytes"
echo "BENCH_INPUT_SHA256=$input_sha"
echo "BENCH_LEPTON_ARCHIVE_SHA256=$lepton_archive_sha"
echo "BENCH_APP_BINARY_SHA256=$app_binary_sha"
echo "BENCH_RESULT=$downloaded_result"
if [ "$validation_status" -ne 0 ]; then
  exit "$validation_status"
fi
