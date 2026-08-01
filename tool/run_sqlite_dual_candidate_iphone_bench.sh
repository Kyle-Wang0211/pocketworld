#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input=${1:-}
device=${PW_BENCH_DEVICE_ID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}
bundle_id=com.kyle.PocketWorld.ArchiveBench
repeat_count=3
run_id=$(date -u +%Y%m%dT%H%M%SZ)

if [ -z "$input" ] || [ ! -f "$input" ]; then
  echo "usage: $0 /absolute/path/to/official_sfm_live.db" >&2
  exit 64
fi

input=$(CDPATH= cd -- "$(dirname -- "$input")" && pwd)/$(basename -- "$input")
input_bytes=$(stat -f %z "$input")
input_sha=$(shasum -a 256 "$input" | awk '{print $1}')
task_root=$(mktemp -d /private/tmp/pw-sqlite-dual-iphone.XXXXXX)
config_root="$task_root/config"
derived_data="$task_root/DerivedData"
products="$task_root/products"
downloaded_result="$task_root/database_archive_benchmark_result.json"
mkdir -p "$config_root" "$products"

cd "$repo_root"
XDG_CONFIG_HOME="$config_root" flutter build ios \
  --release \
  --no-pub \
  --config-only \
  --target=lib/database_archive_benchmark_main.dart \
  --dart-define="PW_BENCH_RUN_ID=$run_id" \
  --build-number=2026080102

xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  FLUTTER_TARGET=lib/database_archive_benchmark_main.dart \
  CONFIGURATION_BUILD_DIR="$products" \
  build

app="$products/Runner.app"
if [ ! -d "$app" ]; then
  echo "independent benchmark app was not produced" >&2
  exit 1
fi
actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if [ "$actual_bundle" != "$bundle_id" ]; then
  echo "refusing install: bundle id is $actual_bundle" >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
if ! nm -gU "$app/Runner" | grep -q '_pw_sqlite_descriptor_transform_file_cancellable'; then
  echo "track-delta transform symbol missing from signed app" >&2
  exit 1
fi

xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device copy to \
  --device "$device" \
  --source "$input" \
  --destination Documents/benchmark_input.db \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id"
xcrun devicectl device process launch \
  --terminate-existing \
  --device "$device" \
  "$bundle_id"

attempt=0
while [ "$attempt" -lt 2880 ]; do
  attempt=$((attempt + 1))
  if xcrun devicectl device copy from \
    --device "$device" \
    --source Documents/database_archive_benchmark_result.json \
    --destination "$downloaded_result" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" >/dev/null 2>&1; then
    observed_run=$(/usr/bin/python3 -c \
      'import json,sys; print(json.load(open(sys.argv[1])).get("run_id", ""))' \
      "$downloaded_result" 2>/dev/null || true)
    status=$(/usr/bin/python3 -c \
      'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' \
      "$downloaded_result" 2>/dev/null || true)
    completed=$(/usr/bin/python3 -c \
      'import json,sys; print(len(json.load(open(sys.argv[1])).get("runs", [])))' \
      "$downloaded_result" 2>/dev/null || true)
    if [ "$observed_run" = "$run_id" ]; then
      echo "BENCH_PROGRESS status=$status repeats=$completed/$repeat_count"
      if [ "$status" = passed ]; then
        break
      fi
      if [ "$status" = failed ]; then
        echo "device benchmark failed; result=$downloaded_result" >&2
        exit 1
      fi
    fi
  fi
  sleep 15
done

if [ ! -f "$downloaded_result" ]; then
  echo "device benchmark produced no result" >&2
  exit 1
fi
/usr/bin/python3 - "$downloaded_result" "$run_id" "$input_bytes" "$input_sha" <<'PY'
import json
import sys

path, run_id, expected_bytes, expected_sha = sys.argv[1:]
result = json.load(open(path))
assert result["run_id"] == run_id
assert result["status"] == "passed"
assert result["bundle_id"] == "com.kyle.PocketWorld.ArchiveBench"
assert result["source_bytes"] == int(expected_bytes)
assert result["source_sha256"] == expected_sha
assert result["source_integrity_check"] == "ok"
assert result["deterministic"] is True
assert result["track_wins_every_repeat"] is True
assert len(result["runs"]) == 3
for run in result["runs"]:
    assert run["selected_preprocess"] == "track_delta_v1"
    assert run["source_sha256"] == run["restored_sha256"] == expected_sha
    assert run["byte_equal"] is True
    assert run["integrity_check"] == "ok"
    assert run["source_deleted_after_commit"] is True
    assert run["temporary_leaks"] == []
    assert run["track_archive_bytes"] < run["raw_archive_bytes"]
print("IPHONE_SQLITE_DUAL_CANDIDATE_OK")
PY

echo "BENCH_BUNDLE_ID=$bundle_id"
echo "BENCH_RUN_ID=$run_id"
echo "BENCH_INPUT_BYTES=$input_bytes"
echo "BENCH_INPUT_SHA256=$input_sha"
echo "BENCH_RESULT=$downloaded_result"
