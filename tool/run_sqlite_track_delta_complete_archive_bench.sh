#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input=
expected_bytes=
expected_sha256=
repeat_count=3
repeat_start=1
compile_only=0
selected_arm=both

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      shift
      ;;
    --input)
      input=$2
      shift 2
      ;;
    --expected-bytes)
      expected_bytes=$2
      shift 2
      ;;
    --expected-sha256)
      expected_sha256=$2
      shift 2
      ;;
    --repeat-count)
      repeat_count=$2
      shift 2
      ;;
    --repeat-start)
      repeat_start=$2
      shift 2
      ;;
    --arm)
      selected_arm=$2
      shift 2
      ;;
    --compile-only)
      compile_only=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$input" ]; then
  input=/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db
fi
if [ -z "$expected_bytes" ]; then
  expected_bytes=198983680
fi
if [ -z "$expected_sha256" ]; then
  expected_sha256=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
fi
if [ "$selected_arm" != "both" ] && [ "$selected_arm" != "raw" ] &&
   [ "$selected_arm" != "track_delta_v1" ] &&
   [ "$selected_arm" != "exact_transform_v2" ]; then
  echo "invalid arm: $selected_arm" >&2
  exit 2
fi

actual_bytes=$(stat -f %z "$input")
actual_sha256=$(shasum -a 256 "$input" | awk '{print $1}')
if [ "$actual_bytes" != "$expected_bytes" ] ||
   [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "immutable SQLite input identity mismatch" >&2
  exit 3
fi
if [ "$(sqlite3 -readonly "$input" 'PRAGMA integrity_check;')" != "ok" ]; then
  echo "immutable SQLite input failed integrity_check" >&2
  exit 4
fi

build_dir=$(mktemp -d /private/tmp/pw-sqlite-track-build.XXXXXX)
cleanup() {
  rm -rf "$build_dir"
}
trap cleanup EXIT HUP INT TERM

xcrun clang++ \
  -std=c++17 \
  -O2 \
  -DPW_SQLITE_EXACT_TRANSFORM_V2_BENCH=1 \
  -Dunix \
  -DNOJIT \
  -I"$repo_root/ios/Runner" \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  "$repo_root/tool/sqlite_track_delta_complete_archive_bench.cpp" \
  "$repo_root/ios/Runner/pw_zpaq_bridge.cpp" \
  "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -lsqlite3 \
  -framework Security \
  -o "$build_dir/sqlite_track_delta_complete_archive_bench"

if [ "$compile_only" -eq 1 ]; then
  echo '{"compile_ok":1}'
  exit 0
fi

evidence_dir="$repo_root/.context/compound-engineering/ce-optimize/sqlite-track-delta-complete-archive"
mkdir -p "$evidence_dir"
results="$evidence_dir/results.ndjson"

for repeat in $(jot "$repeat_count" "$repeat_start"); do
  if [ "$selected_arm" = "both" ]; then
    arms="raw track_delta_v1"
  else
    arms=$selected_arm
  fi
  for arm in $arms; do
    run_dir=$(mktemp -d /private/tmp/pw-sqlite-track-run.XXXXXX)
    "$build_dir/sqlite_track_delta_complete_archive_bench" \
      "$arm" "$input" "$run_dir" "$repeat" "$results"
    if ! tail -n 1 "$results" | grep -q "\"repeat\":$repeat,\"arm\":\"$arm\""; then
      echo "result persistence verification failed for $arm repeat $repeat" >&2
      exit 5
    fi
    rm -rf "$run_dir"
  done
done

if [ "$selected_arm" != "both" ]; then
  tail -n 1 "$results"
  exit 0
fi

python3 - "$results" "$repeat_count" <<'PY'
import json
import statistics
import sys

path = sys.argv[1]
repeat_count = int(sys.argv[2])
records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
records = records[-2 * repeat_count :]
raw = [record for record in records if record["arm"] == "raw"]
track = [record for record in records if record["arm"] == "track_delta_v1"]
if len(raw) != repeat_count or len(track) != repeat_count:
    raise SystemExit("incomplete benchmark result set")
raw_bytes = [record["archive_bytes"] for record in raw]
track_bytes = [record["archive_bytes"] for record in track]
all_exact = all(
    record["source_unchanged"]
    and record["byte_equal"]
    and record["sha256_equal"]
    and record["integrity_ok"]
    for record in records
)
deterministic = (
    len(set(raw_bytes)) == 1
    and len({record["archive_sha256"] for record in raw}) == 1
    and len(set(track_bytes)) == 1
    and len({record["archive_sha256"] for record in track}) == 1
    and len({record["transformed_sha256"] for record in track}) == 1
)
raw_median = int(statistics.median(raw_bytes))
track_median = int(statistics.median(track_bytes))
gain = (raw_median - track_median) / raw_median
print(json.dumps({
    "archive_bytes": track_median,
    "source_unchanged": int(all_exact),
    "byte_equal": int(all_exact),
    "sha256_equal": int(all_exact),
    "integrity_ok": int(all_exact),
    "deterministic": int(deterministic),
    "source_bytes": records[0]["source_bytes"],
    "raw_archive_bytes": raw_median,
    "track_archive_bytes": track_median,
    "gain_fraction": gain,
    "elapsed_ms": sum(record["elapsed_ms"] for record in records),
    "peak_rss_bytes": max(record["peak_rss_bytes"] for record in records),
    "peak_temp_bytes": max(record["peak_temp_bytes"] for record in records),
}, separators=(",", ":")))
PY
