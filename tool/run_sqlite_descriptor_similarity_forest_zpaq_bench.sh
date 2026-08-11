#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input=/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db
output="$repo_root/experiments/descriptor_similarity_forest_zpaq/results/2026-08-02-descriptor-similarity-forest-zpaq.json"
compile_only=0

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

expected_bytes=198983680
expected_sha256=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
if [ "$(stat -f %z "$input")" != "$expected_bytes" ] ||
   [ "$(shasum -a 256 "$input" | awk '{print $1}')" != "$expected_sha256" ] ||
   [ "$(sqlite3 -readonly "$input" 'PRAGMA integrity_check;')" != "ok" ]; then
  echo "immutable SQLite input identity or integrity mismatch" >&2
  exit 3
fi

faiss_prefix=/opt/homebrew/opt/faiss
actual_faiss_sha=$(shasum -a 256 "$faiss_prefix/lib/libfaiss.dylib" | awk '{print $1}')
if [ "$actual_faiss_sha" != "cbd11b958ff233d4cc1dc0fe010890b4677ef81c2e0a039ff4567d365946e473" ]; then
  echo "pinned Faiss library identity mismatch" >&2
  exit 4
fi

build_dir=$(mktemp -d /private/tmp/pw-similarity-zpaq-build.XXXXXX)
run_dir=$(mktemp -d /private/tmp/pw-similarity-zpaq-run.XXXXXX)
cleanup() {
  rm -rf "$build_dir" "$run_dir"
}
trap cleanup EXIT HUP INT TERM

xcrun clang++ \
  -std=c++17 \
  -O2 \
  -Dunix \
  -DNOJIT \
  -I"$repo_root/tool" \
  -I"$repo_root/ios/Runner" \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  -I"$faiss_prefix/include" \
  "$repo_root/tool/sqlite_descriptor_similarity_forest_zpaq_bench.cpp" \
  "$repo_root/tool/descriptor_similarity_forest.cpp" \
  "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -L"$faiss_prefix/lib" \
  -Wl,-rpath,"$faiss_prefix/lib" \
  -lfaiss \
  -lsqlite3 \
  -framework Security \
  -o "$build_dir/sqlite_descriptor_similarity_forest_zpaq_bench"

if [ "$compile_only" -eq 1 ]; then
  echo '{"compile_ok":1}'
  exit 0
fi

mkdir -p "$(dirname "$output")"
OMP_NUM_THREADS=8 "$build_dir/sqlite_descriptor_similarity_forest_zpaq_bench" \
  "$input" "$run_dir" "$output"

test -s "$output"
shasum -a 256 "$output"
