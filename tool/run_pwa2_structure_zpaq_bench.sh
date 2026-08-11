#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
input="/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db"
expected_bytes=198983680
expected_sha256=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
baseline_bytes=124401918
maximum_bytes=111961726
compile_only=0
output="$repo_root/experiments/pwa2_structure_zpaq/results/2026-08-02-pwa2-structure-zpaq.json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      input=$2
      shift 2
      ;;
    --output)
      output=$2
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

actual_bytes=$(stat -f %z "$input")
actual_sha256=$(shasum -a 256 "$input" | awk '{print $1}')
if [ "$actual_bytes" != "$expected_bytes" ] ||
   [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "immutable SQLite input identity mismatch" >&2
  exit 3
fi
if [ "$(sqlite3 "file:$input?immutable=1" 'PRAGMA integrity_check;')" != "ok" ]; then
  echo "immutable SQLite input failed PRAGMA integrity_check" >&2
  exit 4
fi

build_dir=$(mktemp -d /private/tmp/pw-pwa2-build.XXXXXX)
run_parent=$(mktemp -d /private/tmp/pw-pwa2-run.XXXXXX)
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  find "$run_parent" -mindepth 1 -delete
  rmdir "$build_dir" "$run_parent"
}
trap cleanup EXIT HUP INT TERM

common_flags=(
  -std=c++17
  -O2
  -Dunix
  -DNOJIT
  -I"$repo_root/tool"
  -I"$repo_root/ios/Runner"
  -I"$repo_root/ios/Vendor/Zpaq/include"
)
strict_flags=(-Wall -Wextra -Werror)

xcrun clang++ "${common_flags[@]}" "${strict_flags[@]}" \
  -c "$repo_root/tool/pwa2_structure_zpaq_bench.cpp" \
  -o "$build_dir/pwa2_structure_zpaq_bench.o"
xcrun clang++ "${common_flags[@]}" "${strict_flags[@]}" \
  -c "$repo_root/tool/pwa2_sqlite_logical_archive.cpp" \
  -o "$build_dir/pwa2_sqlite_logical_archive.o"
# Vendored ZPAQ 7.15 is pinned and has upstream warnings under current clang.
# Compile only the benchmark-owned sources with -Werror.
xcrun clang++ "${common_flags[@]}" \
  -c "$repo_root/ios/Runner/pw_zpaq_bridge.cpp" \
  -o "$build_dir/pw_zpaq_bridge.o"
xcrun clang++ "${common_flags[@]}" \
  -c "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -o "$build_dir/libzpaq.o"
xcrun clang++ \
  "$build_dir/pwa2_structure_zpaq_bench.o" \
  "$build_dir/pwa2_sqlite_logical_archive.o" \
  "$build_dir/pw_zpaq_bridge.o" \
  "$build_dir/libzpaq.o" \
  -lsqlite3 \
  -framework Security \
  -o "$build_dir/pwa2_structure_zpaq_bench"

if [ "$compile_only" -eq 1 ]; then
  echo "PW_PWA2_STRUCTURE_ZPAQ_COMPILE_OK baseline=$baseline_bytes maximum=$maximum_bytes"
  exit 0
fi

mkdir -p "$(dirname "$output")"
"$build_dir/pwa2_structure_zpaq_bench" \
  "$input" \
  "$run_parent/run" \
  "$output"

python3 - "$output" "$maximum_bytes" <<'PY'
import json
import sys

path = sys.argv[1]
maximum = int(sys.argv[2])
with open(path, encoding="utf-8") as stream:
    result = json.load(stream)
required = (
    result["logical_sha256_equal"],
    result["all_cells_equal"],
    result["all_rows_and_order_equal"],
    result["random_reads_exact"],
    result["materialized_sqlite_integrity_ok"],
    result["source_unchanged"],
)
if not all(required):
    raise SystemExit("PWA2 exactness gate failed")
expected = int(result["complete_persisted_bytes"]) <= maximum
if bool(result["size_gate_pass"]) != expected:
    raise SystemExit("PWA2 size verdict mismatch")
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
