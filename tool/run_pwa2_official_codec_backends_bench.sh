#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
input=/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db
expected_bytes=198983680
expected_sha256=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
production_baseline_bytes=124401918
pwa2_all_zpaq_bytes=129567942
maximum_accepted_bytes=111961726
repeat_count=1
reuse_screening=0
if [ "${1:-}" = "--reuse-screening" ]; then
  reuse_screening=1
  shift
fi
if [ "$#" -ne 0 ]; then
  echo "usage: $0 [--reuse-screening]" >&2
  exit 2
fi

openzl_tag=v0.2.0
openzl_commit=3dceb64867840201fb8f57a29d179995f700c9b8
openzl_license_sha256=371ed262b7969ba0a52f009588c0215df0e455c86b88356e8753748fad8296a5
pcodec_tag=v1.0.2
pcodec_commit=2d8555888b21bbaa19326580b740fa24b7da6bd3
pcodec_license_sha256=c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
blosc2_tag=v3.3.0
blosc2_commit=7265419b23872707b1b52298d5f1469c9ea7b9e7
blosc2_license_sha256=22623131a9b9f6a86a4dc6b9bccbb1d2aeb390df86bca00fc727af24735c2fae

: "${PW_OFFICIAL_CODEC_SOURCE_ROOT:?set PW_OFFICIAL_CODEC_SOURCE_ROOT to the pinned source checkout root}"
source_root="$PW_OFFICIAL_CODEC_SOURCE_ROOT"
results_dir="$repo_root/experiments/pwa2_official_codec_backends/results"
mkdir -p "$results_dir"

verify_checkout() {
  checkout=$1
  expected_tag=$2
  expected_commit=$3
  expected_license=$4
  license_path="$checkout/LICENSE"
  if [ ! -f "$license_path" ]; then
    license_path="$checkout/LICENSE.txt"
  fi
  actual_commit="$(git -C "$checkout" rev-parse HEAD)"
  actual_tag_commit="$(git -C "$checkout" rev-parse "$expected_tag^{commit}")"
  actual_license="$(shasum -a 256 "$license_path" | awk '{print $1}')"
  if [ "$actual_commit" != "$expected_commit" ] ||
     [ "$actual_tag_commit" != "$expected_commit" ] ||
     [ "$actual_license" != "$expected_license" ]; then
    echo "pinned official codec identity mismatch: $checkout" >&2
    exit 5
  fi
}

actual_bytes="$(stat -f %z "$input")"
actual_sha256="$(shasum -a 256 "$input" | awk '{print $1}')"
if [ "$actual_bytes" != "$expected_bytes" ] ||
   [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "immutable SQLite input identity mismatch" >&2
  exit 3
fi
if [ "$(sqlite3 "file:$input?immutable=1" 'PRAGMA integrity_check;')" != ok ]; then
  echo "immutable SQLite input failed integrity check" >&2
  exit 4
fi

verify_checkout "$source_root/openzl" "$openzl_tag" "$openzl_commit" \
  "$openzl_license_sha256"
verify_checkout "$source_root/pcodec" "$pcodec_tag" "$pcodec_commit" \
  "$pcodec_license_sha256"
verify_checkout "$source_root/c-blosc2" "$blosc2_tag" "$blosc2_commit" \
  "$blosc2_license_sha256"

PW_OFFICIAL_CODEC_SOURCE_ROOT="$source_root" \
  bash "$repo_root/tool/run_pwa2_official_codec_backend_tests.sh"

sample_log="$(mktemp /private/tmp/pw-official-codec-sample.XXXXXX)"
full_log="$(mktemp /private/tmp/pw-official-codec-full.XXXXXX)"
cleanup() {
  find "$sample_log" "$full_log" -delete
}
trap cleanup EXIT HUP INT TERM

if [ "$reuse_screening" -eq 0 ]; then
  PW_OFFICIAL_CODEC_SOURCE_ROOT="$source_root" \
    bash "$repo_root/tool/run_pwa2_official_codec_sample_bench.sh" |
    tee "$sample_log"
  awk '/^\{/{print; exit}' "$sample_log" > \
    "$results_dir/2026-08-02-real-member-screening.json"
fi

python3 - "$results_dir/2026-08-02-real-member-screening.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
if result["exact"] != 1:
    raise SystemExit("real-member screening exactness failed")
if result["pcodec_numeric_member_wins"] < 1:
    raise SystemExit("Pcodec has no compatible winning stream; stop full arm")
PY

PW_OFFICIAL_CODEC_SOURCE_ROOT="$source_root" \
  bash "$repo_root/tool/run_pwa2_official_codec_sample_bench.sh" \
    --full-pcodec-numeric |
  tee "$full_log"
awk '/^\{/{print; exit}' "$full_log" > \
  "$results_dir/2026-08-02-pcodec-full-numeric-projection.json"

python3 - "$results_dir/2026-08-02-pcodec-full-numeric-projection.json" \
  "$pwa2_all_zpaq_bytes" "$maximum_accepted_bytes" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
baseline = int(sys.argv[2])
maximum = int(sys.argv[3])
projected = result["projected_complete_persisted_bytes"]
if result["pcodec_member_wins"] != result["numeric_member_count"]:
    raise SystemExit("not every reported Pcodec winner was verified")
if projected != baseline + result["numeric_delta_bytes"]:
    raise SystemExit("complete-byte projection accounting mismatch")
if bool(result["size_gate_pass"]) != (projected <= maximum):
    raise SystemExit("size-gate verdict mismatch")
if bool(result["scoped_baseline_accepted"]) != (projected < baseline):
    raise SystemExit("scoped baseline verdict mismatch")
if not all(
    result[field]
    for field in (
        "logical_sha256_equal",
        "all_cells_equal",
        "all_rows_and_order_equal",
        "random_reads_exact",
        "materialized_sqlite_integrity_ok",
        "source_unchanged",
    )
):
    raise SystemExit("one or more exactness gates failed")
PY

final_bytes="$(stat -f %z "$input")"
final_sha256="$(shasum -a 256 "$input" | awk '{print $1}')"
if [ "$final_bytes" != "$expected_bytes" ] ||
   [ "$final_sha256" != "$expected_sha256" ] ||
   [ "$(sqlite3 "file:$input?immutable=1" 'PRAGMA integrity_check;')" != ok ]; then
  echo "source changed during official-codec benchmark" >&2
  exit 6
fi

echo "PW_PWA2_OFFICIAL_CODEC_BACKENDS_RUN_OK repeat_count=$repeat_count production_baseline_bytes=$production_baseline_bytes maximum_accepted_bytes=$maximum_accepted_bytes"
