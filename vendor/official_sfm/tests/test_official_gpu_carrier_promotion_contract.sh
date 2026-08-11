#!/bin/sh
set -eu

MODE=${1:-}
if { [ "$MODE" != "--source-only" ] && [ "$MODE" != "--fixture" ]; } ||
   [ "$#" -ne 1 ]; then
  echo "usage: $0 {--source-only|--fixture}" >&2
  exit 64
fi

if [ -n "${PWOFFICIAL_PRODUCT_ROOT:-}" ]; then
  PRODUCT_ROOT=$PWOFFICIAL_PRODUCT_ROOT
else
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  PRODUCT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
fi

OFFICIAL_ROOT="$PRODUCT_ROOT/vendor/official_sfm"
REBUILD="$OFFICIAL_ROOT/scripts/rebuild_native.sh"
BUILD_FRAMEWORK="$OFFICIAL_ROOT/scripts/build_xcframework.sh"
PROMOTE="$OFFICIAL_ROOT/scripts/promote_official_pair.py"
PARITY="$OFFICIAL_ROOT/scripts/verify_source_parity.py"

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

pass() {
  echo "PASS: $*"
}

require_file() {
  path=$1
  label=$2
  if [ ! -f "$path" ]; then
    fail "missing $label: $path"
  fi
}

require_executable() {
  path=$1
  label=$2
  if [ ! -x "$path" ]; then
    fail "$label is not executable: $path"
  fi
}

require_text() {
  path=$1
  needle=$2
  label=$3
  if [ ! -f "$path" ] || ! grep -Fq -- "$needle" "$path"; then
    fail "$label"
  fi
}

require_text_before() {
  path=$1
  earlier=$2
  later=$3
  label=$4
  if [ ! -f "$path" ]; then
    fail "$label"
    return
  fi
  earlier_line=$(grep -Fnm 1 -- "$earlier" "$path" | cut -d: -f1 || true)
  later_line=$(grep -Fnm 1 -- "$later" "$path" | cut -d: -f1 || true)
  if [ -z "$earlier_line" ] || [ -z "$later_line" ] ||
     [ "$earlier_line" -ge "$later_line" ]; then
    fail "$label"
  fi
}

require_text_count_at_least() {
  path=$1
  needle=$2
  minimum=$3
  label=$4
  if [ ! -f "$path" ]; then
    fail "$label"
    return
  fi
  count=$(grep -Fc -- "$needle" "$path" || true)
  if [ "$count" -lt "$minimum" ]; then
    fail "$label (found $count, need at least $minimum)"
  fi
}

forbid_text() {
  path=$1
  needle=$2
  label=$3
  if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then
    fail "$label"
  fi
}

run_source_contract() {
  require_file "$REBUILD" "official rebuild script"
  require_file "$BUILD_FRAMEWORK" "official framework build script"
  require_file "$PROMOTE" "journaled pair-promotion helper"
  require_file "$PARITY" "official source-parity gate"
  require_executable "$REBUILD" "official rebuild script"
  require_executable "$BUILD_FRAMEWORK" "official framework build script"
  require_executable "$PARITY" "official source-parity gate"

  require_text "$REBUILD" "PWOFFICIAL_P3_PRODUCT_PROMOTION_V1" \
    "rebuild script lacks the durable promotion contract marker"
  require_text "$REBUILD" "b930ab185135dfbd172aef7c2bbeed67ef315f75" \
    "rebuild script does not pin the accepted algorithm revision"
  require_text "$REBUILD" "mktemp -d /private/tmp/" \
    "rebuild script does not isolate candidate work under /private/tmp"
  require_text "$REBUILD" "-G Xcode" \
    "rebuild script does not select the accepted Xcode CMake generator"
  require_text "$REBUILD" "CMAKE_SYSTEM_NAME=iOS" \
    "rebuild script does not configure the physical-iOS toolchain"
  require_text "$REBUILD" "CMAKE_OSX_ARCHITECTURES=arm64" \
    "rebuild script does not freeze arm64"
  require_text "$REBUILD" "CMAKE_OSX_DEPLOYMENT_TARGET=14.0" \
    "rebuild script does not freeze the iOS deployment target"
  require_text "$REBUILD" "pwofficial_gpu_extract" \
    "rebuild script does not build the algorithm-owned official carrier target"
  require_text "$REBUILD" "--config Release" \
    "rebuild script does not build the accepted Release configuration"
  require_text "$REBUILD" "DAWN_FETCH_DEPENDENCIES=OFF" \
    "rebuild script does not fail closed on Dawn dependency fetching"
  require_text "$REBUILD" "AETHER_ALLOW_TEST_ASSET_DOWNLOADS=OFF" \
    "rebuild script does not disable optional configure-time test downloads"
  require_text "$REBUILD" "verify_pwofficial_gpu_extract_artifact.sh" \
    "rebuild script does not invoke the algorithm-owned carrier verifier"
  require_text "$REBUILD" "PWOFFICIAL_GPU_CARRIER" \
    "rebuild script does not pass an explicit candidate carrier"
  require_text "$REBUILD" "PWOFFICIAL_XCFRAMEWORK_OUT" \
    "rebuild script does not pass an explicit candidate framework output"
  require_text "$REBUILD" "PWOFFICIAL_DAWN_ARCHIVE" \
    "rebuild script does not pass the absolute pinned Dawn archive"
  require_text "$REBUILD" \
    "625cf65dded708ad1abd3dc92f3b47c3c90c384f508676b56303f9341d301b42" \
    "rebuild script does not hash-pin the framework-linked Dawn archive"
  require_text "$REBUILD" \
    "6c6a0aa0c5abf5eda79c50ef367f04c67838326b5f7c42e09f6649f8906eb88e" \
    "rebuild script does not pin the accepted old official carrier"
  require_text "$REBUILD" \
    "0b69ca576a624972f0b95993d8f1e217a1f0bfe54fe1b1ac0890a37531520485" \
    "rebuild script does not pin the accepted old official framework tree"
  require_text "$REBUILD" \
    "cb15b6201e76b5ef1fd9a522265da823ff16498c2b7760a032317e8b04214eaa" \
    "rebuild script does not pin the frozen self carrier"
  require_text "$REBUILD" \
    "1ac64d0a138f47f6285c36e6b4b257832ac3932264b8df664797cbeb2217bb04" \
    "rebuild script does not pin the accepted official core"
  require_text "$REBUILD" \
    "ac61cdcf32f5948fec0bb8892b22803c9752787da57de68b959137bb19e87dd6" \
    "rebuild script does not pin the linked Ceres archive"
  require_text "$REBUILD" \
    "dc35639b7b1b9d7d9603f13bbf9d4c883cd64099d8e537595cce69edf8ac3b03" \
    "rebuild script does not pin the linked glog archive"
  require_text "$REBUILD" \
    "a6c7fdd47be427d45dcf1cf00adf290018285776b53136cd3e501a485c3ff279" \
    "rebuild script does not pin the iPhoneOS SDK sqlite3 stub"
  require_text "$REBUILD" "PWOFFICIAL_LINK_MAP" \
    "rebuild script does not retain the product framework link map"
  require_text "$REBUILD" "PWOFFICIAL_TASK_ROOT" \
    "rebuild script does not bind all candidates to one task-owned root"
  require_text "$REBUILD" "PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST" \
    "rebuild script does not require a fresh-review accepted product manifest"
  require_text "$REBUILD" "PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST_SHA256" \
    "rebuild script does not freeze the accepted product manifest digest"
  require_text "$REBUILD" "PWOFFICIAL_IDENTITY_OBSERVER" \
    "rebuild script does not invoke the accepted complete-identity observer"
  require_text "$REBUILD" \
    "eb493fd4e097e58809d8b228f30ad4d91319a419bd5045787a384fb01eff934a" \
    "rebuild script does not pin the accepted observer implementation"
  require_text "$REBUILD" "product-identity-before-build.manifest" \
    "rebuild script lacks the pre-build complete-identity recheck"
  require_text "$REBUILD" "product-identity-before-promotion.manifest" \
    "rebuild script lacks the immediate pre-promotion identity recheck"
  require_text "$REBUILD" "promote_official_pair.py" \
    "rebuild script does not call the one journaled transaction owner"
  require_text "$REBUILD" "--recover-only" \
    "rebuild script does not recover an interrupted transaction before building"
  require_text "$REBUILD" "PWOFFICIAL_EXPECTED_PROMOTE_HELPER_SHA256" \
    "rebuild script does not pin the recovery helper before early recovery"
  require_text_before "$REBUILD" "product promotion helper SHA-256 mismatch" "--recover-only" \
    "rebuild script does not authenticate the helper before early recovery"
  require_text_before "$REBUILD" "--recover-only" "PWOFFICIAL_ACCEPTED_PRODUCT_MANIFEST" \
    "rebuild script lets manifest preflight veto crash recovery"
  require_text_before "$REBUILD" "--recover-only" "xcrun --sdk iphoneos" \
    "rebuild script lets SDK discovery veto crash recovery"
  require_text_before "$REBUILD" "--recover-only" "cmake --build" \
    "rebuild script does not recover before the first candidate build"
  require_text "$REBUILD" "--preserve-path" \
    "rebuild script does not hash-gate the read-only self carrier"
  require_text "$REBUILD" "--expected-preserve-sha256" \
    "rebuild script does not freeze the self carrier before promotion"
  require_text "$REBUILD" "--expected-old-carrier-sha256" \
    "rebuild script does not freeze the old official carrier"
  require_text "$REBUILD" "--expected-old-framework-sha256" \
    "rebuild script does not freeze the old official framework"
  require_text "$REBUILD" "--expected-candidate-carrier-sha256" \
    "rebuild script does not freeze the candidate official carrier"
  require_text "$REBUILD" "--expected-candidate-framework-sha256" \
    "rebuild script does not freeze the candidate official framework"
  require_text "$REBUILD" "--expected-core-sha256" \
    "rebuild script does not ask the transaction owner to freeze the core"
  for immutable_flag in \
    --dawn-archive \
    --expected-dawn-sha256 \
    --ceres-archive \
    --expected-ceres-sha256 \
    --glog-archive \
    --expected-glog-sha256 \
    --sqlite-tbd \
    --expected-sqlite-tbd-sha256
  do
    require_text "$REBUILD" "$immutable_flag" \
      "rebuild script does not pass immutable dependency flag $immutable_flag to the transaction owner"
    require_text "$PROMOTE" "$immutable_flag" \
      "promotion helper does not accept immutable dependency flag $immutable_flag"
  done
  require_text "$REBUILD" "--assert-ready" \
    "rebuild script does not verify the committed-pair readiness gate"

  require_text "$BUILD_FRAMEWORK" "PWOFFICIAL_P3_CANDIDATE_BUILD_V1" \
    "framework script lacks the candidate-only build contract marker"
  require_text "$BUILD_FRAMEWORK" "PWOFFICIAL_PATH_SCOPE_V1" \
    "framework script lacks canonical task-root containment"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_TASK_ROOT:?' \
    "framework script does not require one task-owned root"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_GPU_CARRIER:?' \
    "framework script does not require an explicit candidate carrier"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_XCFRAMEWORK_OUT:?' \
    "framework script does not require an explicit candidate output"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_DAWN_ARCHIVE:?' \
    "framework script does not require an explicit Dawn archive"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_DAWN_SHA256:?' \
    "framework script does not require the Dawn archive digest"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_LINK_MAP:?' \
    "framework script does not require a retained device link map"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_CERES_ARCHIVE:?' \
    "framework script does not require the exact Ceres archive"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_CERES_SHA256:?' \
    "framework script does not require the Ceres archive digest"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_GLOG_ARCHIVE:?' \
    "framework script does not require the exact glog archive"
  require_text "$BUILD_FRAMEWORK" \
    ': "${PWOFFICIAL_GLOG_SHA256:?' \
    "framework script does not require the glog archive digest"
  require_text "$BUILD_FRAMEWORK" "-Wl,-map," \
    "framework device link does not emit the retained link map"
  require_text "$BUILD_FRAMEWORK" "refusing existing output" \
    "framework script does not fail closed when candidate output exists"
  forbid_text "$BUILD_FRAMEWORK" \
    '"$ROOT/libs/ios-arm64/libpwofficial_gpu_extract.a"' \
    "framework script still binds the live official carrier path"
  forbid_text "$BUILD_FRAMEWORK" \
    'build-ios-device-dawn/third_party/dawn/src/dawn/native/Debug-iphoneos/libwebgpu_dawn.a' \
    "framework script still binds an implicit Dawn archive path"
  forbid_text "$BUILD_FRAMEWORK" 'rm -rf "$OUT"' \
    "framework script still deletes its output path"
  forbid_text "$BUILD_FRAMEWORK" "-lceres" \
    "framework script still lets the linker choose a Ceres library by name"
  forbid_text "$BUILD_FRAMEWORK" "-lglog" \
    "framework script still lets the linker choose a glog library by name"
  require_text "$BUILD_FRAMEWORK" \
    'grep -Fq -- "$PWOFFICIAL_CERES_ARCHIVE" "$PWOFFICIAL_LINK_MAP"' \
    "framework script does not prove the exact Ceres archive in the link map"
  require_text "$BUILD_FRAMEWORK" \
    'grep -Fq -- "$PWOFFICIAL_GLOG_ARCHIVE" "$PWOFFICIAL_LINK_MAP"' \
    "framework script does not prove the exact glog archive in the link map"

  require_text "$PROMOTE" "PWOFFICIAL_P3_PAIR_TRANSACTION_V1" \
    "promotion helper lacks the fixed transaction schema marker"
  require_text "$PROMOTE" "--recover-only" \
    "promotion helper lacks next-process recovery-only mode"
  require_text "$PROMOTE" "--assert-ready" \
    "promotion helper lacks a consumer readiness gate"
  require_text "$PROMOTE" "--task-root" \
    "promotion helper does not confine candidates to one task-owned root"
  require_text "$PROMOTE" ".pwofficial_pair_transaction_v1.json" \
    "promotion helper lacks the fixed journal path"
  require_text "$PROMOTE" "libpwofficial_gpu_extract.a.p3candidate" \
    "promotion helper lacks the fixed carrier staging path"
  require_text "$PROMOTE" "PWOfficialSfm.xcframework.p3candidate" \
    "promotion helper lacks the fixed framework staging path"
  require_text "$PROMOTE" "journal_persisted" \
    "promotion helper lacks the durable-journal crash checkpoint"
  require_text "$PROMOTE" "live_carrier_renamed" \
    "promotion helper lacks the live-carrier crash checkpoint"
  require_text "$PROMOTE" "live_framework_renamed" \
    "promotion helper lacks the live-framework crash checkpoint"
  require_text "$PROMOTE" "final_verified_before_commit" \
    "promotion helper lacks the final pre-commit crash checkpoint"
  require_text "$PROMOTE" "carrier_stage_fsynced" \
    "promotion helper lacks a journaled carrier-staging crash checkpoint"
  require_text "$PROMOTE" "framework_stage_fsynced" \
    "promotion helper lacks a journaled framework-staging crash checkpoint"
  require_text "$PROMOTE" "journal_tmp_fsynced" \
    "promotion helper lacks a journal-temporary crash checkpoint"
  require_text "$PROMOTE" "os._exit" \
    "promotion helper lacks a handler-bypassing crash-test seam"
  require_text "$PROMOTE" "os.fsync" \
    "promotion helper does not durably fsync journal/data directories"
  require_text "$PROMOTE" "json.dump" \
    "promotion helper does not persist a structured journal"
  require_text "$PROMOTE" "fcntl.flock" \
    "promotion helper does not serialize concurrent pair transactions"
  require_text "$PROMOTE" "--preserve-path" \
    "promotion helper does not verify the read-only self carrier"
  require_text "$PROMOTE" "--expected-preserve-sha256" \
    "promotion helper does not verify the expected self-carrier digest"
  require_text "$PROMOTE" "--expected-core-sha256" \
    "promotion helper does not verify the accepted official core"
  require_text_count_at_least "$PROMOTE" "verify_immutable_inputs(" 4 \
    "promotion helper does not hold dependency identities through entry, pre-rename, commit, and readiness"

  require_text "$PARITY" \
    "71d0e0b1da2c4d2caf09da33900e5abd0c193033f10f4c8197c6a18f8504ec6d" \
    "source-parity gate still pins the pre-timestamp official endpoint"
  require_text "$PARITY" "GPU-TIMESTAMP-PROBE V1" \
    "source-parity pin lacks timestamp-writer provenance"

  for path in "$REBUILD" "$BUILD_FRAMEWORK" "$PROMOTE"; do
    forbid_text "$path" "flutter drive" \
      "carrier integration must not invoke flutter drive"
    forbid_text "$path" "uninstall" \
      "carrier integration must not contain an uninstall path"
    forbid_text "$path" "devicectl" \
      "carrier integration must not perform a device action"
  done

  if [ "$failures" -ne 0 ]; then
    echo "PWOFFICIAL_PROMOTION_SOURCE_CONTRACT_RED failures=$failures" >&2
    return 1
  fi
  pass "official carrier/framework promotion source contract"
}

sha256_path() {
  python3 - "$1" <<'PY'
from __future__ import annotations
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
if root.is_file():
    print(hashlib.sha256(root.read_bytes()).hexdigest())
    raise SystemExit
if not root.is_dir():
    raise SystemExit(f"not a file or directory: {root}")
h = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    rel = path.relative_to(root).as_posix().encode()
    if path.is_symlink():
        h.update(b"L\0" + rel + b"\0" + path.readlink().as_posix().encode() + b"\n")
    elif path.is_file():
        h.update(b"F\0" + rel + b"\0")
        h.update(hashlib.sha256(path.read_bytes()).digest())
        h.update(b"\n")
print(h.hexdigest())
PY
}

make_fixture() {
  case_name=$1
  CASE_ROOT="$SUITE_ROOT/$case_name"
  OFFICIAL_CASE_ROOT="$CASE_ROOT/vendor/official_sfm"
  LIVE_CARRIER="$OFFICIAL_CASE_ROOT/libs/ios-arm64/libpwofficial_gpu_extract.a"
  LIVE_FRAMEWORK="$OFFICIAL_CASE_ROOT/Frameworks/PWOfficialSfm.xcframework"
  SELF_CARRIER="$CASE_ROOT/vendor/aether_ffi/libs/ios-arm64/sfm/libpwsfm_gpu_extract.a"
  CORE_ARCHIVE="$OFFICIAL_CASE_ROOT/libs/ios-arm64/libpwofficial_core.a"
  TASK_ROOT="$CASE_ROOT/candidate"
  CANDIDATE_CARRIER="$CASE_ROOT/candidate/libpwofficial_gpu_extract.a"
  CANDIDATE_FRAMEWORK="$CASE_ROOT/candidate/PWOfficialSfm.xcframework"
  IMMUTABLE_ROOT="$CASE_ROOT/frozen-inputs"
  DAWN_ARCHIVE="$IMMUTABLE_ROOT/libwebgpu_dawn.a"
  CERES_ARCHIVE="$IMMUTABLE_ROOT/libceres.a"
  GLOG_ARCHIVE="$IMMUTABLE_ROOT/libglog.a"
  SQLITE_TBD="$IMMUTABLE_ROOT/libsqlite3.tbd"

  mkdir -p "$(dirname "$LIVE_CARRIER")" \
    "$LIVE_FRAMEWORK/ios-arm64/PWOfficialSfm.framework" \
    "$(dirname "$SELF_CARRIER")" \
    "$(dirname "$CORE_ARCHIVE")" \
    "$(dirname "$CANDIDATE_CARRIER")" \
    "$CANDIDATE_FRAMEWORK/ios-arm64/PWOfficialSfm.framework" \
    "$IMMUTABLE_ROOT"
  : > "$CASE_ROOT/.pwofficial-promotion-fixture-v1"
  printf '%s\n' "old official carrier $case_name" > "$LIVE_CARRIER"
  printf '%s\n' "old framework info $case_name" > "$LIVE_FRAMEWORK/Info.plist"
  printf '%s\n' "old framework binary $case_name" \
    > "$LIVE_FRAMEWORK/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm"
  printf '%s\n' "preserved self carrier $case_name" > "$SELF_CARRIER"
  printf '%s\n' "frozen official core $case_name" > "$CORE_ARCHIVE"
  printf '%s\n' "new official carrier $case_name" > "$CANDIDATE_CARRIER"
  printf '%s\n' "new framework info $case_name" > "$CANDIDATE_FRAMEWORK/Info.plist"
  printf '%s\n' "new framework binary $case_name" \
    > "$CANDIDATE_FRAMEWORK/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm"
  printf '%s\n' "frozen Dawn $case_name" > "$DAWN_ARCHIVE"
  printf '%s\n' "frozen Ceres $case_name" > "$CERES_ARCHIVE"
  printf '%s\n' "frozen glog $case_name" > "$GLOG_ARCHIVE"
  printf '%s\n' "frozen SDK sqlite stub $case_name" > "$SQLITE_TBD"

  OLD_CARRIER_SHA=$(sha256_path "$LIVE_CARRIER")
  OLD_FRAMEWORK_SHA=$(sha256_path "$LIVE_FRAMEWORK")
  SELF_SHA=$(sha256_path "$SELF_CARRIER")
  CORE_SHA=$(sha256_path "$CORE_ARCHIVE")
  NEW_CARRIER_SHA=$(sha256_path "$CANDIDATE_CARRIER")
  NEW_FRAMEWORK_SHA=$(sha256_path "$CANDIDATE_FRAMEWORK")
  DAWN_SHA=$(sha256_path "$DAWN_ARCHIVE")
  CERES_SHA=$(sha256_path "$CERES_ARCHIVE")
  GLOG_SHA=$(sha256_path "$GLOG_ARCHIVE")
  SQLITE_TBD_SHA=$(sha256_path "$SQLITE_TBD")
  JOURNAL="$OFFICIAL_CASE_ROOT/.pwofficial_pair_transaction_v1.json"
}

invoke_promote() {
  PWOFFICIAL_TEST_MODE=1 \
    PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
    PWOFFICIAL_TEST_FAIL_AFTER="${FAIL_AFTER:-}" \
    PWOFFICIAL_TEST_CRASH_AFTER="${CRASH_AFTER:-}" \
    PWOFFICIAL_TEST_DRIFT_IMMUTABLE_AT="${DRIFT_IMMUTABLE_AT:-}" \
    python3 "$PROMOTE" \
      --task-root "$TASK_ROOT" \
      --candidate-carrier "$CANDIDATE_CARRIER" \
      --candidate-framework "$CANDIDATE_FRAMEWORK" \
      --expected-old-carrier-sha256 "$OLD_CARRIER_SHA" \
      --expected-old-framework-sha256 "$OLD_FRAMEWORK_SHA" \
      --expected-candidate-carrier-sha256 "$NEW_CARRIER_SHA" \
      --expected-candidate-framework-sha256 "$NEW_FRAMEWORK_SHA" \
      --preserve-path "$SELF_CARRIER" \
      --expected-preserve-sha256 "$SELF_SHA" \
      --expected-core-sha256 "$CORE_SHA" \
      --dawn-archive "$DAWN_ARCHIVE" \
      --expected-dawn-sha256 "$DAWN_SHA" \
      --ceres-archive "$CERES_ARCHIVE" \
      --expected-ceres-sha256 "$CERES_SHA" \
      --glog-archive "$GLOG_ARCHIVE" \
      --expected-glog-sha256 "$GLOG_SHA" \
      --sqlite-tbd "$SQLITE_TBD" \
      --expected-sqlite-tbd-sha256 "$SQLITE_TBD_SHA"
}

invoke_ready() {
  ready_carrier_sha=$1
  ready_framework_sha=$2
  PWOFFICIAL_TEST_MODE=1 \
    PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
    python3 "$PROMOTE" \
      --assert-ready \
      --expected-ready-carrier-sha256 "$ready_carrier_sha" \
      --expected-ready-framework-sha256 "$ready_framework_sha" \
      --preserve-path "$SELF_CARRIER" \
      --expected-preserve-sha256 "$SELF_SHA" \
      --expected-core-sha256 "$CORE_SHA" \
      --dawn-archive "$DAWN_ARCHIVE" \
      --expected-dawn-sha256 "$DAWN_SHA" \
      --ceres-archive "$CERES_ARCHIVE" \
      --expected-ceres-sha256 "$CERES_SHA" \
      --glog-archive "$GLOG_ARCHIVE" \
      --expected-glog-sha256 "$GLOG_SHA" \
      --sqlite-tbd "$SQLITE_TBD" \
      --expected-sqlite-tbd-sha256 "$SQLITE_TBD_SHA"
}

assert_official_old_pair() {
  label=$1
  [ "$(sha256_path "$LIVE_CARRIER")" = "$OLD_CARRIER_SHA" ] ||
    fail "$label did not restore the old official carrier"
  [ "$(sha256_path "$LIVE_FRAMEWORK")" = "$OLD_FRAMEWORK_SHA" ] ||
    fail "$label did not restore the old official framework"
}

assert_no_transaction_debris() {
  label=$1
  for debris in \
    "$JOURNAL" \
    "$JOURNAL.tmp" \
    "$LIVE_CARRIER.p3candidate" \
    "$LIVE_CARRIER.p3backup" \
    "$LIVE_CARRIER.p3discard" \
    "$LIVE_FRAMEWORK.p3candidate" \
    "$LIVE_FRAMEWORK.p3backup" \
    "$LIVE_FRAMEWORK.p3discard"
  do
    [ ! -e "$debris" ] || fail "$label left transaction debris: $debris"
  done
}

assert_old_pair() {
  label=$1
  assert_official_old_pair "$label"
  [ "$(sha256_path "$SELF_CARRIER")" = "$SELF_SHA" ] ||
    fail "$label modified the frozen self carrier"
  [ "$(sha256_path "$CORE_ARCHIVE")" = "$CORE_SHA" ] ||
    fail "$label modified the frozen official core"
  assert_no_transaction_debris "$label"
}

assert_new_pair() {
  label=$1
  [ "$(sha256_path "$LIVE_CARRIER")" = "$NEW_CARRIER_SHA" ] ||
    fail "$label did not promote the candidate carrier"
  [ "$(sha256_path "$LIVE_FRAMEWORK")" = "$NEW_FRAMEWORK_SHA" ] ||
    fail "$label did not promote the candidate framework"
  [ "$(sha256_path "$SELF_CARRIER")" = "$SELF_SHA" ] ||
    fail "$label modified the frozen self carrier"
  [ "$(sha256_path "$CORE_ARCHIVE")" = "$CORE_SHA" ] ||
    fail "$label modified the frozen official core"
  assert_no_transaction_debris "$label"
}

run_fixture_contract() {
  if [ ! -f "$PROMOTE" ]; then
    fail "fixture cannot run because the promotion helper is absent"
    echo "PWOFFICIAL_PROMOTION_FIXTURE_RED failures=$failures" >&2
    return 1
  fi

  SUITE_ROOT=$(mktemp -d /private/tmp/pwofficial-promotion-fixture.XXXXXX)
  if [ "${PWOFFICIAL_KEEP_FIXTURE:-0}" = "1" ]; then
    echo "PWOFFICIAL_FIXTURE_ROOT=$SUITE_ROOT"
  else
    trap 'rm -rf "$SUITE_ROOT"' EXIT HUP INT TERM
  fi

  make_fixture success
  FAIL_AFTER=
  CRASH_AFTER=
  DRIFT_IMMUTABLE_AT=
  if invoke_promote > "$CASE_ROOT/promote.log" 2>&1; then
    assert_new_pair "successful promotion"
    if ! invoke_ready "$NEW_CARRIER_SHA" "$NEW_FRAMEWORK_SHA" \
      > "$CASE_ROOT/ready.log" 2>&1; then
      fail "committed candidate pair did not pass the readiness gate"
    fi
    pass "successful pair promotion preserved the self carrier"
  else
    fail "successful promotion arm returned non-zero"
    sed -n '1,120p' "$CASE_ROOT/promote.log" >&2
  fi

  make_fixture immutable-entry-drift
  FAIL_AFTER=
  CRASH_AFTER=
  DRIFT_IMMUTABLE_AT=
  printf '%s\n' "external Dawn drift before entry" > "$DAWN_ARCHIVE"
  set +e
  invoke_promote > "$CASE_ROOT/immutable-entry-drift.log" 2>&1
  immutable_entry_rc=$?
  set -e
  [ "$immutable_entry_rc" -ne 0 ] ||
    fail "immutable dependency drift at transaction entry was accepted"
  assert_old_pair "immutable entry-drift rejection"
  pass "immutable dependency drift rejected at transaction entry"

  make_fixture immutable-pre-rename-drift
  FAIL_AFTER=
  CRASH_AFTER=
  DRIFT_IMMUTABLE_AT=before_first_live_rename
  set +e
  invoke_promote > "$CASE_ROOT/immutable-pre-rename-drift.log" 2>&1
  immutable_pre_rename_rc=$?
  set -e
  [ "$immutable_pre_rename_rc" -ne 0 ] ||
    fail "immutable dependency drift immediately before the first live rename was accepted"
  assert_old_pair "immutable pre-rename drift rejection"
  pass "immutable dependency drift rejected immediately before live promotion"

  make_fixture immutable-readiness-drift
  FAIL_AFTER=
  CRASH_AFTER=
  DRIFT_IMMUTABLE_AT=
  if ! invoke_promote > "$CASE_ROOT/immutable-readiness-promote.log" 2>&1; then
    fail "readiness-drift setup promotion failed"
  else
    printf '%s\n' "external glog drift after commit" > "$GLOG_ARCHIVE"
    set +e
    invoke_ready "$NEW_CARRIER_SHA" "$NEW_FRAMEWORK_SHA" \
      > "$CASE_ROOT/immutable-readiness-drift.log" 2>&1
    immutable_ready_rc=$?
    set -e
    [ "$immutable_ready_rc" -ne 0 ] ||
      fail "readiness admitted a pair after immutable dependency drift"
    pass "readiness rejects immutable dependency drift after commit"
  fi

  for checkpoint in \
    candidate_carrier_validated \
    candidate_framework_validated \
    staging_complete \
    live_carrier_renamed \
    live_framework_renamed \
    final_pair_verified
  do
    make_fixture "handled-$checkpoint"
    FAIL_AFTER=$checkpoint
    CRASH_AFTER=
    DRIFT_IMMUTABLE_AT=
    set +e
    invoke_promote > "$CASE_ROOT/promote.log" 2>&1
    arm_rc=$?
    set -e
    [ "$arm_rc" -ne 0 ] ||
      fail "handled-failure arm $checkpoint unexpectedly returned zero"
    assert_old_pair "handled-failure arm $checkpoint"
    pass "handled rollback: $checkpoint"
  done

  for checkpoint in \
    carrier_stage_fsynced \
    framework_stage_fsynced \
    journal_tmp_fsynced
  do
    make_fixture "staging-crash-$checkpoint"
    FAIL_AFTER=
    CRASH_AFTER=$checkpoint
    DRIFT_IMMUTABLE_AT=
    set +e
    invoke_promote > "$CASE_ROOT/crash.log" 2>&1
    crash_rc=$?
    set -e
    [ "$crash_rc" -eq 86 ] ||
      {
        fail "staging/journal-temp crash $checkpoint returned $crash_rc instead of 86"
        sed -n '1,80p' "$CASE_ROOT/crash.log" >&2
      }

    set +e
    PWOFFICIAL_TEST_MODE=1 \
      PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
      python3 "$PROMOTE" --recover-only > "$CASE_ROOT/recover.log" 2>&1
    recover_rc=$?
    set -e
    [ "$recover_rc" -eq 0 ] ||
      fail "fresh-process staging/journal-temp recovery failed after $checkpoint"
    assert_old_pair "staging/journal-temp crash recovery arm $checkpoint"
    pass "fresh-process staging/journal-temp recovery: $checkpoint"
  done

  for checkpoint in \
    journal_persisted \
    live_carrier_renamed \
    live_framework_renamed \
    final_verified_before_commit
  do
    make_fixture "crash-$checkpoint"
    FAIL_AFTER=
    CRASH_AFTER=$checkpoint
    DRIFT_IMMUTABLE_AT=
    set +e
    invoke_promote > "$CASE_ROOT/crash.log" 2>&1
    crash_rc=$?
    set -e
    [ "$crash_rc" -eq 86 ] ||
      {
        fail "hard-crash arm $checkpoint returned $crash_rc instead of immediate-exit 86"
        sed -n '1,80p' "$CASE_ROOT/crash.log" >&2
      }
    [ -e "$JOURNAL" ] ||
      fail "hard-crash arm $checkpoint did not leave a recoverable journal"
    set +e
    invoke_ready "$NEW_CARRIER_SHA" "$NEW_FRAMEWORK_SHA" \
      > "$CASE_ROOT/not-ready.log" 2>&1
    ready_during_crash_rc=$?
    set -e
    [ "$ready_during_crash_rc" -ne 0 ] ||
      fail "readiness gate admitted active crash state at $checkpoint"

    set +e
    PWOFFICIAL_TEST_MODE=1 \
      PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
      python3 "$PROMOTE" --recover-only > "$CASE_ROOT/recover.log" 2>&1
    recover_rc=$?
    set -e
    [ "$recover_rc" -eq 0 ] ||
      fail "fresh-process recovery failed after $checkpoint"
    assert_old_pair "hard-crash recovery arm $checkpoint"
    if ! invoke_ready "$OLD_CARRIER_SHA" "$OLD_FRAMEWORK_SHA" \
      > "$CASE_ROOT/ready-after-recovery.log" 2>&1; then
      fail "restored pair did not pass readiness after $checkpoint"
    fi
    pass "fresh-process crash recovery: $checkpoint"
  done

  make_fixture self-drift-after-carrier-crash
  FAIL_AFTER=
  CRASH_AFTER=live_carrier_renamed
  DRIFT_IMMUTABLE_AT=
  set +e
  invoke_promote > "$CASE_ROOT/crash.log" 2>&1
  drift_crash_rc=$?
  set -e
  [ "$drift_crash_rc" -eq 86 ] ||
    fail "self-drift setup did not crash at live_carrier_renamed"
  printf '%s\n' "external self-carrier drift" > "$SELF_CARRIER"
  set +e
  PWOFFICIAL_TEST_MODE=1 \
    PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
    python3 "$PROMOTE" --recover-only > "$CASE_ROOT/recover.log" 2>&1
  drift_recover_rc=$?
  set -e
  [ "$drift_recover_rc" -ne 0 ] ||
    fail "self drift was not reported after official-pair rollback"
  assert_official_old_pair "self-drift recovery"
  pass "self drift cannot veto official-pair rollback"

  make_fixture immutable-missing-after-carrier-crash
  FAIL_AFTER=
  CRASH_AFTER=live_carrier_renamed
  DRIFT_IMMUTABLE_AT=
  set +e
  invoke_promote > "$CASE_ROOT/crash.log" 2>&1
  immutable_missing_crash_rc=$?
  set -e
  [ "$immutable_missing_crash_rc" -eq 86 ] ||
    fail "immutable-missing setup did not crash at live_carrier_renamed"
  rm -f "$DAWN_ARCHIVE"
  set +e
  PWOFFICIAL_TEST_MODE=1 \
    PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
    python3 "$PROMOTE" --recover-only > "$CASE_ROOT/recover.log" 2>&1
  immutable_missing_recover_rc=$?
  set -e
  [ "$immutable_missing_recover_rc" -ne 0 ] ||
    fail "missing immutable input was not reported after official-pair rollback"
  assert_old_pair "immutable-missing recovery"
  pass "missing dependency cannot veto official-pair rollback"

  for rebuild_drift_mode in missing symlink digest
  do
    make_fixture "rebuild-entry-$rebuild_drift_mode-after-carrier-crash"
    FAIL_AFTER=
    CRASH_AFTER=live_carrier_renamed
    DRIFT_IMMUTABLE_AT=
    set +e
    invoke_promote > "$CASE_ROOT/crash.log" 2>&1
    rebuild_entry_crash_rc=$?
    set -e
    [ "$rebuild_entry_crash_rc" -eq 86 ] ||
      fail "rebuild-entry $rebuild_drift_mode setup did not crash at live_carrier_renamed"
    case "$rebuild_drift_mode" in
      missing)
        rm -f "$DAWN_ARCHIVE"
        ;;
      symlink)
        mv "$DAWN_ARCHIVE" "$DAWN_ARCHIVE.original"
        ln -s "$DAWN_ARCHIVE.original" "$DAWN_ARCHIVE"
        ;;
      digest)
        printf '%s\n' "external Dawn digest drift" >> "$DAWN_ARCHIVE"
        ;;
    esac
    set +e
    PWOFFICIAL_TEST_MODE=1 \
      PWOFFICIAL_TEST_PRODUCT_ROOT="$CASE_ROOT" \
      sh "$REBUILD" > "$CASE_ROOT/rebuild-entry.log" 2>&1
    rebuild_entry_rc=$?
    set -e
    [ "$rebuild_entry_rc" -ne 0 ] ||
      fail "rebuild entry unexpectedly passed preflight after $rebuild_drift_mode dependency drift"
    assert_old_pair "rebuild-entry $rebuild_drift_mode recovery"
    pass "rebuild entry restores old pair before $rebuild_drift_mode dependency preflight"
  done

  make_fixture path-scope-guards
  for scope_case in traversal symlink output_escape
  do
    case "$scope_case" in
      traversal)
        scope_carrier=/private/tmp/../../etc/hosts
        scope_output="$TASK_ROOT/scope-output.xcframework"
        ;;
      symlink)
        ln -s /etc/hosts "$TASK_ROOT/alias-carrier"
        scope_carrier="$TASK_ROOT/alias-carrier"
        scope_output="$TASK_ROOT/scope-output.xcframework"
        ;;
      output_escape)
        scope_carrier="$CANDIDATE_CARRIER"
        scope_output="$TASK_ROOT/../../escaped-output.xcframework"
        ;;
    esac
    set +e
    PWOFFICIAL_TASK_ROOT="$TASK_ROOT" \
      PWOFFICIAL_GPU_CARRIER="$scope_carrier" \
      PWOFFICIAL_XCFRAMEWORK_OUT="$scope_output" \
      PWOFFICIAL_DAWN_ARCHIVE=/etc/hosts \
      PWOFFICIAL_DAWN_SHA256=invalid-by-design \
      PWOFFICIAL_CERES_ARCHIVE=/etc/hosts \
      PWOFFICIAL_CERES_SHA256=invalid-by-design \
      PWOFFICIAL_GLOG_ARCHIVE=/etc/hosts \
      PWOFFICIAL_GLOG_SHA256=invalid-by-design \
      PWOFFICIAL_LINK_MAP="$TASK_ROOT/scope-link.map" \
      "$BUILD_FRAMEWORK" > "$CASE_ROOT/scope-$scope_case.log" 2>&1
    scope_rc=$?
    set -e
    [ "$scope_rc" -ne 0 ] ||
      fail "path-scope guard admitted $scope_case"
    pass "canonical path-scope rejection: $scope_case"
  done
  [ ! -e "$SUITE_ROOT/escaped-output.xcframework" ] ||
    fail "output traversal created an escaped artifact"

  valid_candidate_carrier=$CANDIDATE_CARRIER
  CANDIDATE_CARRIER="$TASK_ROOT/../candidate/libpwofficial_gpu_extract.a"
  set +e
  invoke_promote > "$CASE_ROOT/helper-traversal.log" 2>&1
  helper_traversal_rc=$?
  set -e
  [ "$helper_traversal_rc" -ne 0 ] ||
    fail "promotion helper admitted a traversal alias"
  assert_old_pair "helper traversal rejection"
  CANDIDATE_CARRIER=$valid_candidate_carrier

  ln -s "$LIVE_CARRIER" "$TASK_ROOT/helper-alias-carrier"
  CANDIDATE_CARRIER="$TASK_ROOT/helper-alias-carrier"
  set +e
  invoke_promote > "$CASE_ROOT/helper-symlink.log" 2>&1
  helper_symlink_rc=$?
  set -e
  [ "$helper_symlink_rc" -ne 0 ] ||
    fail "promotion helper admitted a symlink alias"
  assert_old_pair "helper symlink rejection"
  CANDIDATE_CARRIER=$valid_candidate_carrier
  pass "promotion helper canonical path-scope rejection"

  if [ "$failures" -ne 0 ]; then
    echo "PWOFFICIAL_PROMOTION_FIXTURE_RED failures=$failures" >&2
    return 1
  fi
  pass "handled rollback and fresh-process crash recovery fixture"
}

if [ "$MODE" = "--source-only" ]; then
  run_source_contract
else
  run_fixture_contract
fi
