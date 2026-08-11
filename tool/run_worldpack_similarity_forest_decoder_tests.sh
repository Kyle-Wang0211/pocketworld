#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
faiss_prefix=/opt/homebrew/opt/faiss
build_root=${PW_WORLDPACK_SIMILARITY_DECODER_BUILD:-/private/tmp/pw_worldpack_similarity_decoder.build.v1}
binary="$build_root/worldpack_similarity_forest_decoder"
archive=${PW_WORLDPACK_SIMILARITY_ARCHIVE:-/private/tmp/pw_worldpack_similarity_export.run.v1/similarity_forest_v1.zpaq}
expected_sha=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0

mkdir -p "$build_root"
xcrun clang++ -std=c++17 -O2 -Dunix -DNOJIT \
  -I"$repo_root/tool" -I"$repo_root/ios/Runner" \
  -I"$repo_root/ios/Vendor/Zpaq/include" -I"$faiss_prefix/include" \
  "$repo_root/tool/worldpack_similarity_forest_decoder.cpp" \
  "$repo_root/tool/descriptor_similarity_forest.cpp" \
  "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -L"$faiss_prefix/lib" -Wl,-rpath,"$faiss_prefix/lib" \
  -lfaiss -lsqlite3 -framework Security -o "$binary"

if test "${1:-}" = "--compile-only"; then
  echo '{"compile_ok":1}'
  exit 0
fi
test -f "$archive"
restored="$build_root/restored.db"
"$binary" "$archive" "$restored" "$expected_sha"
test "$(stat -f %z "$restored")" = 198983680
test "$(shasum -a 256 "$restored" | awk '{print $1}')" = "$expected_sha"
test "$(sqlite3 "$restored" 'PRAGMA query_only=ON; PRAGMA integrity_check;')" = ok
echo '{"decoder_roundtrip_ok":1}'
