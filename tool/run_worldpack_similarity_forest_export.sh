#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
input=${PW_WORLDPACK_SIMILARITY_INPUT:-/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db}
run_dir=${PW_WORLDPACK_SIMILARITY_RUN_DIR:-/private/tmp/pw_worldpack_similarity_export.run.v1}
result=${PW_WORLDPACK_SIMILARITY_RESULT:-/private/tmp/pw_worldpack_similarity_export.result.v1.json}
build_dir=${PW_WORLDPACK_SIMILARITY_BUILD_DIR:-/private/tmp/pw_worldpack_similarity_export.build.v1}
faiss_prefix=/opt/homebrew/opt/faiss

test "$(stat -f %z "$input")" = 198983680
test "$(shasum -a 256 "$input" | awk '{print $1}')" = \
  0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
test "$(sqlite3 -readonly "$input" 'PRAGMA integrity_check;')" = ok
test "$(shasum -a 256 "$faiss_prefix/lib/libfaiss.dylib" | awk '{print $1}')" = \
  cbd11b958ff233d4cc1dc0fe010890b4677ef81c2e0a039ff4567d365946e473

mkdir -p "$build_dir" "$run_dir" "$(dirname "$result")"
xcrun clang++ \
  -std=c++17 \
  -O2 \
  -Dunix \
  -DNOJIT \
  -I"$repo_root/tool" \
  -I"$repo_root/ios/Runner" \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  -I"$faiss_prefix/include" \
  "$repo_root/tool/worldpack_similarity_forest_export.cpp" \
  "$repo_root/tool/descriptor_similarity_forest.cpp" \
  "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -L"$faiss_prefix/lib" \
  -Wl,-rpath,"$faiss_prefix/lib" \
  -lfaiss \
  -lsqlite3 \
  -framework Security \
  -o "$build_dir/worldpack_similarity_forest_export"

OMP_NUM_THREADS=8 "$build_dir/worldpack_similarity_forest_export" \
  "$input" "$run_dir" "$result"
test -s "$run_dir/similarity_forest_v1.zpaq"
test "$(stat -f %z "$run_dir/similarity_forest_v1.zpaq")" = 116739319
test "$(shasum -a 256 "$run_dir/similarity_forest_v1.zpaq" | awk '{print $1}')" = \
  9b425ddb6751398593c0beba8a387a4f69693c8d5dc4737b16911ce3d3f9b3e1
echo "$run_dir/similarity_forest_v1.zpaq"

