#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input_dir=${1:-}
device=${PW_PTOL_BENCH_DEVICE_ID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}
bundle_id="com.kyle.PocketWorld.PtolBench"
team_id=${PW_PTOL_BENCH_TEAM_ID:-26AH7V448L}
signing_identity=${PW_PTOL_BENCH_CODE_SIGN_IDENTITY:-1C30FFB54D965CA96917C5EC0DC4B34F9EDDA775}
provisioning_profile=${PW_PTOL_BENCH_PROVISIONING_PROFILE:-/Users/kaidongwang/Library/Developer/Xcode/UserData/Provisioning\ Profiles/edc53ec5-7583-45da-8044-de6a9a1885c2.mobileprovision}
production_app=${PW_PTOL_PRODUCTION_APP:-/private/tmp/pw-splash-solving-20260825T043900Z/flutter-build/ios/iphoneos/Runner.app}
run_id=$(date -u +%Y%m%dT%H%M%SZ)

expected_archive_bytes=7286278
expected_archive_sha=9114ec5e078f1730fe4f399789e26994bd26cbaacecb4f6c19f3c3120f2fc3f4
expected_manifest_bytes=638
expected_manifest_sha=3e0757b9f3ae3a9e69c087c9a2f7c5d7c0ad0fc47f2e59531634ba8d19874f7e
expected_pose_bytes=14176
expected_pose_sha=d4f6d3c079cf9993cee9dceb7b5e3445ac990f1f2626986b95acbdcb35b615c1
expected_fed_bytes=97133
expected_fed_sha=659e4ac8d4bf4f976956e71b801c74ea0b68a87348734f66c9ddb62067f24f61
expected_policy_bytes=252
expected_policy_sha=b381512431f6416bf11fbe667c77e4d027dc60ad48a1ea276a39ee1096dead03
expected_sqlite_sha=f829c281aea6ed7956e3afb134959b663cf35cfee633956029c09d3b2af3290d
expected_native_sha=bd1220f12b84b6de06319bda28e2902d375b59b9150d3dd947bc1d04afc34062
expected_native_cdhash=c6bc8bdb8502d9a75738ce41bfa3066e77a40500ce3499799aac146dd263b61a
expected_source_head=a8b94ca0e35158c8aca7c2e3f66f11269fa385f6
expected_source_manifest_sha=e89bcbcf2f2301986865a55625907d65821b3ee8f1715f6c1d4514c13740d5d1
expected_runner_sha=${PW_PTOL_EXPECTED_RUNNER_SHA256:-}
expected_identity_receipt_sha=${PW_PTOL_EXPECTED_IDENTITY_RECEIPT_SHA256:-}
identity_receipt="$repo_root/experiments/global_ptol_phone_ab_20260825/candidate-identity.yaml"

if [ -z "$expected_runner_sha" ] || [ -z "$expected_identity_receipt_sha" ]; then
  echo "runner and candidate-identity literal SHA-256 values are required" >&2
  exit 64
fi
actual_runner_sha=$(/usr/bin/shasum -a 256 "$repo_root/tool/run_global_ptol_phone_ab.sh" | /usr/bin/awk '{print $1}')
if [ "$actual_runner_sha" != "$expected_runner_sha" ]; then
  echo "refusing changed device runner: expected=$expected_runner_sha actual=$actual_runner_sha" >&2
  exit 1
fi
actual_identity_receipt_sha=$(/usr/bin/shasum -a 256 "$identity_receipt" | /usr/bin/awk '{print $1}')
if [ "$actual_identity_receipt_sha" != "$expected_identity_receipt_sha" ]; then
  echo "refusing changed candidate identity receipt" >&2
  exit 1
fi
receipt_runner_sha=$(/usr/bin/awk '/^runner_sha256:/ {print $2}' "$identity_receipt")
receipt_source_sha=$(/usr/bin/awk '/^source_manifest_sha256:/ {print $2}' "$identity_receipt")
if [ "$receipt_runner_sha" != "$expected_runner_sha" ] || [ "$receipt_source_sha" != "$expected_source_manifest_sha" ]; then
  echo "candidate identity receipt does not match the pinned runner/source pair" >&2
  exit 1
fi

if [ -z "$input_dir" ] || [ ! -d "$input_dir" ]; then
  echo "usage: $0 /absolute/path/to/cap_1787545807521946" >&2
  exit 64
fi
input_dir=$(CDPATH= cd -- "$input_dir" && pwd)

verify_file() {
  file=$1
  expected_bytes=$2
  expected_sha=$3
  if [ ! -f "$file" ]; then
    echo "missing frozen benchmark input: $file" >&2
    exit 1
  fi
  actual_bytes=$(stat -f %z "$file")
  actual_sha=$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')
  if [ "$actual_bytes" -ne "$expected_bytes" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo "refusing wrong benchmark input: $file bytes=$actual_bytes sha256=$actual_sha" >&2
    exit 1
  fi
}

verify_file "$input_dir/official_sfm_live.db.zpaq" "$expected_archive_bytes" "$expected_archive_sha"
verify_file "$input_dir/official_database_archive.json" "$expected_manifest_bytes" "$expected_manifest_sha"
verify_file "$input_dir/official_sfm_live.db.arkit_pose_v1" "$expected_pose_bytes" "$expected_pose_sha"
verify_file "$input_dir/official_sfm_fed_frames.jsonl" "$expected_fed_bytes" "$expected_fed_sha"
verify_file "$input_dir/official_database_archive_policy.json" "$expected_policy_bytes" "$expected_policy_sha"

task_root=$(mktemp -d /private/tmp/pw-global-ptol-phone-ab.XXXXXX)
config_root="$task_root/config"
derived_data="$task_root/DerivedData"
build_dir="$task_root/build"
obj_root="$task_root/obj"
decoded_profile="$task_root/provisioning-profile.plist"
benchmark_entitlements="$task_root/PtolBench.entitlements"
downloaded_result="$task_root/global_ptol_benchmark_result.json"
downloaded_artifacts="$task_root/artifacts"
device_receipt="$task_root/device-details.json"
staged_input="$task_root/frozen-benchmark-input"
mkdir -p "$config_root" "$build_dir" "$obj_root" "$downloaded_artifacts" "$staged_input"

# Stage only the five contract-listed inputs. Unverified files that happen to
# share the source directory never cross the device boundary.
for frozen_name in \
  official_sfm_live.db.zpaq \
  official_database_archive.json \
  official_sfm_live.db.arkit_pose_v1 \
  official_sfm_fed_frames.jsonl \
  official_database_archive_policy.json
do
  /usr/bin/ditto "$input_dir/$frozen_name" "$staged_input/$frozen_name"
done

cd "$repo_root"
source_head=$(git rev-parse HEAD)
source_branch=$(git branch --show-current)
if [ "$source_head" != "$expected_source_head" ] || [ "$source_branch" != "codex/ptol-phone-ab-20260825" ]; then
  echo "refusing changed source revision: head=$source_head branch=$source_branch" >&2
  exit 1
fi
git status --porcelain=v1 -uall > "$task_root/source-status.txt"
git diff --binary > "$task_root/unstaged.patch"
git diff --cached --binary > "$task_root/staged.patch"
git ls-files -co --exclude-standard -z | while IFS= read -r -d '' path; do
  case "$path" in
    # The runner is pinned independently by the caller-provided literal hash.
    # Its candidate receipt is externally pinned because including either here
    # would create a self-referential digest. Brainstorm preview state is a
    # transient UI cache, not product/build input. Every contract, threshold,
    # input receipt, and actual product source remains inside this gate.
    tool/run_global_ptol_phone_ab.sh|\
    experiments/global_ptol_phone_ab_20260825/candidate-identity.yaml|\
    .superpowers/brainstorm/*) continue ;;
  esac
  test -f "$path" && shasum -a 256 "$path"
done | LC_ALL=C sort > "$task_root/source-content.sha256"
source_manifest_sha=$(/usr/bin/shasum -a 256 "$task_root/source-content.sha256" | /usr/bin/awk '{print $1}')
if [ "$source_manifest_sha" != "$expected_source_manifest_sha" ]; then
  echo "refusing changed dirty product tree: manifest=$source_manifest_sha" >&2
  exit 1
fi

flutter_version=$(flutter --version | /usr/bin/head -n 1)
dart_version=$(dart --version 2>&1)
case "$flutter_version" in
  'Flutter 3.47.1 '*) ;;
  *) echo "refusing unpinned Flutter: $flutter_version" >&2; exit 1 ;;
esac
case "$dart_version" in
  'Dart SDK version: 3.13.1 '*) ;;
  *) echo "refusing unpinned Dart: $dart_version" >&2; exit 1 ;;
esac

xcrun devicectl device info details --device "$device" --json-output "$device_receipt" >/dev/null
/usr/bin/python3 -I - "$device_receipt" "$device" <<'PY'
import json
import sys

def require(condition, message):
    if not condition:
        raise SystemExit(message)

receipt, expected_identifier = sys.argv[1:]
result = json.load(open(receipt))["result"]
hardware = result["hardwareProperties"]
require(result["identifier"] == expected_identifier == "1B290474-D354-5B4C-AAB0-0805AC5DC832", "wrong CoreDevice identifier")
require(hardware["marketingName"] == "iPhone 14 Pro", "wrong device model")
require(hardware["productType"] == "iPhone15,2", "wrong device product type")
require(hardware["udid"] == "00008120-00146C4A1AEBC01E", "wrong device UDID")
require(hardware["reality"] == "physical", "benchmark device is not physical")
PY

if [ ! -f "$provisioning_profile" ]; then
  echo "independent benchmark provisioning profile is missing" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | /usr/bin/grep -q "$signing_identity"; then
  echo "independent benchmark signing identity is unavailable" >&2
  exit 1
fi

production_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$production_app/Info.plist" 2>/dev/null || true)
production_native="$production_app/Frameworks/PWOfficialSfm.framework/PWOfficialSfm"
if [ "$production_bundle" != "com.kyle.PocketWorld" ] || [ ! -f "$production_native" ]; then
  echo "verified build-32 production artifact is unavailable" >&2
  exit 1
fi
production_native_sha=$(/usr/bin/shasum -a 256 "$production_native" | /usr/bin/awk '{print $1}')
if [ "$production_native_sha" != "$expected_native_sha" ]; then
  echo "verified build-32 framework identity changed: $production_native_sha" >&2
  exit 1
fi
production_native_cdhash=$(codesign -d --verbose=4 "$production_app/Frameworks/PWOfficialSfm.framework" 2>&1 | /usr/bin/sed -n 's/^CandidateCDHashFull sha256=//p')
if [ "$production_native_cdhash" != "$expected_native_cdhash" ]; then
  echo "verified build-32 code directory changed: $production_native_cdhash" >&2
  exit 1
fi

XDG_CONFIG_HOME="$config_root" flutter build ios \
  --release \
  --no-pub \
  --config-only \
  --target=lib/global_ptol_benchmark_main.dart \
  --dart-define="PW_GLOBAL_PTOL_RUN_ID=$run_id" \
  --build-number=2026082501

xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
  FLUTTER_TARGET=lib/global_ptol_benchmark_main.dart \
  BUILD_DIR="$build_dir" \
  OBJROOT="$obj_root" \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGNING_ALLOWED=NO \
  build

app="$build_dir/Release-iphoneos/Runner.app"
if [ ! -d "$app" ]; then
  echo "independent PTOL benchmark app was not produced" >&2
  exit 1
fi
actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if [ "$actual_bundle" != "$bundle_id" ]; then
  echo "refusing install: bundle id is $actual_bundle" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Add :PWGlobalPtolBenchmarkRunID string $run_id" "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName PocketWorld PTOL Bench' "$app/Info.plist"
/usr/bin/lipo -info "$app/Runner" | /usr/bin/grep -q 'arm64'

native_binary="$app/Frameworks/PWOfficialSfm.framework/PWOfficialSfm"
if [ ! -f "$native_binary" ]; then
  echo "PWOfficialSfm framework is missing from benchmark app" >&2
  exit 1
fi
# The dirty product tree contains later native work. Stage the exact framework
# from the verified build-32 artifact so PTOL is the only native variable in
# this benchmark; the destination is the isolated /private/tmp app bundle.
mv "$app/Frameworks/PWOfficialSfm.framework" "$task_root/current-vendor-PWOfficialSfm.framework"
/usr/bin/ditto "$production_app/Frameworks/PWOfficialSfm.framework" "$app/Frameworks/PWOfficialSfm.framework"
native_binary="$app/Frameworks/PWOfficialSfm.framework/PWOfficialSfm"
native_sha=$(/usr/bin/shasum -a 256 "$native_binary" | /usr/bin/awk '{print $1}')
if [ "$native_sha" != "$expected_native_sha" ]; then
  echo "refusing install: PWOfficialSfm sha256=$native_sha" >&2
  exit 1
fi
if ! /usr/bin/strings "$native_binary" | /usr/bin/grep -q 'OFFICIAL_AETHER_GLOBAL_PTOL'; then
  echo "refusing install: PTOL hook is absent from PWOfficialSfm" >&2
  exit 1
fi

security cms -D -i "$provisioning_profile" > "$decoded_profile"
profile_app_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$decoded_profile")
if [ "$profile_app_id" != "$team_id.*" ]; then
  echo "refusing sign: benchmark profile is not the expected wildcard profile" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.kernel.extended-virtual-addressing' "$decoded_profile" >/dev/null 2>&1 || \
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.kernel.increased-memory-limit' "$decoded_profile" >/dev/null 2>&1; then
  echo "refusing sign: benchmark profile grants production memory entitlements" >&2
  exit 1
fi
plutil -extract Entitlements xml1 -o "$benchmark_entitlements" "$decoded_profile"
/usr/libexec/PlistBuddy -c "Set :application-identifier $team_id.$bundle_id" "$benchmark_entitlements"
/usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 $team_id.$bundle_id" "$benchmark_entitlements"
/usr/bin/ditto "$provisioning_profile" "$app/embedded.mobileprovision"
find "$app/Frameworks" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' binary; do
  codesign --force --sign "$signing_identity" --timestamp=none "$binary"
done
find "$app/Frameworks" -type d -name '*.framework' -print0 | while IFS= read -r -d '' framework; do
  codesign --force --sign "$signing_identity" --timestamp=none "$framework"
done
codesign --force --sign "$signing_identity" --entitlements "$benchmark_entitlements" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
signed_native_sha=$(/usr/bin/shasum -a 256 "$native_binary" | /usr/bin/awk '{print $1}')
signed_native_cdhash=$(codesign -d --verbose=4 "$app/Frameworks/PWOfficialSfm.framework" 2>&1 | /usr/bin/sed -n 's/^CandidateCDHashFull sha256=//p')
if [ "$signed_native_cdhash" != "$expected_native_cdhash" ]; then
  echo "refusing install: signed PTOL framework code directory changed" >&2
  exit 1
fi

app_binary_sha=$(/usr/bin/shasum -a 256 "$app/Runner" | /usr/bin/awk '{print $1}')
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device copy to --device "$device" --source "$staged_input" --destination Documents/benchmark_input --domain-type appDataContainer --domain-identifier "$bundle_id"
xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle_id"

attempt=0
while [ "$attempt" -lt 720 ]; do
  attempt=$((attempt + 1))
  if xcrun devicectl device copy from --device "$device" --source Documents/global_ptol_benchmark_result.json --destination "$downloaded_result" --domain-type appDataContainer --domain-identifier "$bundle_id" >/dev/null 2>&1; then
    observed_run=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run_id", ""))' "$downloaded_result" 2>/dev/null || true)
    status=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$downloaded_result" 2>/dev/null || true)
    if [ "$observed_run" = "$run_id" ]; then
      echo "PTOL_BENCH_PROGRESS status=$status attempt=$attempt/720"
      if [ "$status" = passed ] || [ "$status" = not_eligible ] || [ "$status" = failed ]; then
        break
      fi
    fi
  else
    echo "PTOL_BENCH_PROGRESS status=starting attempt=$attempt/360"
  fi
  sleep 10
done

if [ ! -f "$downloaded_result" ]; then
  echo "physical-iPhone PTOL benchmark produced no result" >&2
  echo "IPHONE_GLOBAL_PTOL_AB_FAILED"
  exit 1
fi

if ! xcrun devicectl device copy from --device "$device" --source "Documents/global_ptol_benchmark/$run_id" --destination "$downloaded_artifacts" --domain-type appDataContainer --domain-identifier "$bundle_id"; then
  echo "PTOL_BENCH_ARTIFACT_PULL=unavailable"
fi

validation_status=0
 /usr/bin/python3 -I - "$downloaded_result" "$downloaded_artifacts" "$run_id" "$expected_native_sha" <<'PY' || validation_status=$?
import hashlib
import json
from pathlib import Path
import sys

def require(condition, message):
    if not condition:
        raise SystemExit(message)

result_path, artifacts_root, run_id, expected_native_sha = sys.argv[1:]
result = json.load(open(result_path))
require(result["run_id"] == run_id, "result run ID mismatch")
require(result["bundle_id"] == "com.kyle.PocketWorld.PtolBench", "result bundle mismatch")
identity = result["input_identity"]
require(identity["archive_sha256"] == "9114ec5e078f1730fe4f399789e26994bd26cbaacecb4f6c19f3c3120f2fc3f4", "archive identity mismatch")
require(identity["archive_manifest_sha256"] == "3e0757b9f3ae3a9e69c087c9a2f7c5d7c0ad0fc47f2e59531634ba8d19874f7e", "archive manifest identity mismatch")
require(identity["pose_sha256"] == "d4f6d3c079cf9993cee9dceb7b5e3445ac990f1f2626986b95acbdcb35b615c1", "ARKit pose identity mismatch")
require(identity["materialized_sqlite_sha256"] == "f829c281aea6ed7956e3afb134959b663cf35cfee633956029c09d3b2af3290d", "SQLite identity mismatch")
require(identity["native_framework_sha256"] == expected_native_sha, "native framework identity mismatch")
if result["status"] == "failed":
    raise SystemExit(1)
arms = result["arms"]
require([(a["label"], a["ptol"]) for a in arms] == [
    ("A1", "0"), ("B1", "1e-8"), ("A2", "0"), ("B2", "1e-8")], "arm order/value mismatch")
for arm in arms:
    require(arm["succeeded"] is True, "arm did not succeed")
    require(arm["elapsed_ms"] > 0, "arm elapsed time is not positive")
    require(arm["registered"] > 0, "arm registered count is not positive")
    require(arm["delivered_points"] > 0, "arm point count is not positive")
    require(arm["ply_bytes"] > 0, "arm PLY is empty")
    require(len(arm["ply_sha256"]) == 64, "arm PLY digest is malformed")
    label = arm["label"]
    matches = [p for p in Path(artifacts_root).rglob("official_sfm_sparse.ply") if p.parent.name == label]
    require(len(matches) == 1, f"expected exactly one PLY for {label}: {matches}")
    ply = matches[0]
    payload = ply.read_bytes()
    require(len(payload) == arm["ply_bytes"], f"PLY size mismatch for {label}")
    require(hashlib.sha256(payload).hexdigest() == arm["ply_sha256"], f"PLY digest mismatch for {label}")
    meta = ply.with_name("official_sfm_sparse_meta.json")
    require(meta.is_file(), f"missing sparse metadata for {label}")
    meta_payload = meta.read_bytes()
    require(len(meta_payload) == arm["sparse_meta"]["bytes"], f"metadata size mismatch for {label}")
    require(hashlib.sha256(meta_payload).hexdigest() == arm["sparse_meta"]["sha256"], f"metadata digest mismatch for {label}")
    arm_result = ply.with_name("global_ptol_arm_result.json")
    require(arm_result.is_file(), f"missing arm JSON for {label}")
    pulled_arm = json.load(open(arm_result))
    require(pulled_arm == arm, f"arm JSON mismatch for {label}")
    segments = arm.get("finalize_segments")
    if segments is not None:
        segment_file = ply.with_name("official_finalize_segments.json")
        require(segment_file.is_file(), f"missing finalize segments for {label}")
        segment_payload = segment_file.read_bytes()
        require(len(segment_payload) == segments["bytes"], f"segment size mismatch for {label}")
        require(hashlib.sha256(segment_payload).hexdigest() == segments["sha256"], f"segment digest mismatch for {label}")

def spread(x, y):
    return abs(x - y) / min(x, y)

def quality(control, candidate):
    return (
        control["registered"] == candidate["registered"]
        and abs(candidate["delivered_points"] - control["delivered_points"]) / control["delivered_points"] <= 0.01 + 1e-12
        and candidate["reprojection_error_px"] <= control["reprojection_error_px"] + 0.01 + 1e-12
    )

a1, b1, a2, b2 = arms
a_median = (a1["elapsed_ms"] + a2["elapsed_ms"]) / 2
b_median = (b1["elapsed_ms"] + b2["elapsed_ms"]) / 2
noise = max(spread(a1["elapsed_ms"], a2["elapsed_ms"]), spread(b1["elapsed_ms"], b2["elapsed_ms"]))
improvement = (a_median - b_median) / a_median
eligible = (
    quality(a1, b1) and quality(a2, b2)
    and noise <= 0.10 + 1e-12
    and a1["registered"] == a2["registered"]
    and b1["registered"] == b2["registered"]
    and b_median < a_median
    and improvement > max(0.05, noise) + 1e-12
)
require(result["winner"]["eligible"] is eligible, "winner recomputation mismatch")
require(result["advance_to_end_to_end_candidate"] is eligible, "advance decision mismatch")
require(result["production_eligible"] is False, "diagnostic result claimed production eligibility")
if result["status"] == "passed":
    require(eligible is True, "passed status without an eligible winner")
    print("IPHONE_GLOBAL_PTOL_AB_OK")
    raise SystemExit(0)
if result["status"] == "not_eligible":
    require(result["winner"]["eligible"] is False, "not_eligible status with eligible winner")
    print("IPHONE_GLOBAL_PTOL_AB_NOT_ELIGIBLE")
    raise SystemExit(3)
raise SystemExit(1)
PY

echo "PTOL_BENCH_BUNDLE_ID=$bundle_id"
echo "PTOL_BENCH_RUN_ID=$run_id"
echo "PTOL_BENCH_DEVICE=$device"
echo "PTOL_BENCH_NATIVE_SHA256=$native_sha"
echo "PTOL_BENCH_SIGNED_NATIVE_SHA256=$signed_native_sha"
echo "PTOL_BENCH_NATIVE_CDHASH_FULL=$signed_native_cdhash"
echo "PTOL_BENCH_APP_BINARY_SHA256=$app_binary_sha"
echo "PTOL_BENCH_RESULT=$downloaded_result"
echo "PTOL_BENCH_ARTIFACTS=$downloaded_artifacts"
echo "PTOL_BENCH_TASK_ROOT=$task_root"
echo "PTOL_BENCH_SOURCE_HEAD=$source_head"
echo "PTOL_BENCH_SOURCE_MANIFEST_SHA256=$source_manifest_sha"
echo "PTOL_BENCH_RUNNER_SHA256=$actual_runner_sha"
echo "PTOL_BENCH_IDENTITY_RECEIPT_SHA256=$actual_identity_receipt_sha"
case "$validation_status" in
  0) ;;
  3) exit 3 ;;
  *) echo "IPHONE_GLOBAL_PTOL_AB_FAILED"; exit "$validation_status" ;;
esac
