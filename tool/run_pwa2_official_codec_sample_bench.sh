#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
input=/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db
expected_bytes=198983680
expected_sha256=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
: "${PW_OFFICIAL_CODEC_SOURCE_ROOT:?set PW_OFFICIAL_CODEC_SOURCE_ROOT to the pinned source checkout root}"
source_root="$PW_OFFICIAL_CODEC_SOURCE_ROOT"
blosc_build="${PW_BLOSC2_BUILD_DIR:-$source_root/c-blosc2-build}"
openzl_build="${PW_OPENZL_BUILD_DIR:-$source_root/openzl-build-default}"
build_dir="$(mktemp -d /private/tmp/pw-codec-sample-build.XXXXXX)"
run_parent="$(mktemp -d /private/tmp/pw-codec-sample-run.XXXXXX)"
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  find "$run_parent" -mindepth 1 -delete
  rmdir "$build_dir" "$run_parent"
}
trap cleanup EXIT HUP INT TERM

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

common_flags=(
  -std=c++17
  -O2
  -Dunix
  -DNOJIT
  -I"$repo_root/tool"
  -I"$repo_root/ios/Runner"
  -I"$repo_root/ios/Vendor/Zpaq/include"
  -I"$source_root/pcodec/pco_c/include"
  -I"$source_root/c-blosc2/include"
  -I"$source_root/openzl/include"
  -I"$openzl_build/include"
)

xcrun clang++ "${common_flags[@]}" -Wall -Wextra -Werror \
  -c "$repo_root/tool/pwa2_official_codec_backends_bench.cpp" \
  -o "$build_dir/sample.o"
xcrun clang++ "${common_flags[@]}" -Wall -Wextra -Werror \
  -c "$repo_root/tool/pwa2_official_codec_backend.cpp" \
  -o "$build_dir/backend.o"
xcrun clang++ "${common_flags[@]}" -Wall -Wextra -Werror \
  -c "$repo_root/tool/pwa2_sqlite_logical_archive.cpp" \
  -o "$build_dir/pwa2.o"
# The two pinned upstream ZPAQ files retain warnings under current AppleClang.
xcrun clang++ "${common_flags[@]}" \
  -c "$repo_root/ios/Runner/pw_zpaq_bridge.cpp" \
  -o "$build_dir/zpaq_bridge.o"
xcrun clang++ "${common_flags[@]}" \
  -c "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -o "$build_dir/libzpaq.o"
xcrun clang++ \
  "$build_dir/sample.o" \
  "$build_dir/backend.o" \
  "$build_dir/pwa2.o" \
  "$build_dir/zpaq_bridge.o" \
  "$build_dir/libzpaq.o" \
  "$source_root/pcodec/target/release/libcpcodec.dylib" \
  "$blosc_build/blosc/libblosc2.a" \
  "$openzl_build/libopenzl.a" \
  "$openzl_build/zstd_build/lib/libzstd.a" \
  "$openzl_build/lz4_build/liblz4.a" \
  "$blosc_build/_deps/zfp-build/lib/libzfp.a" \
  -lsqlite3 \
  -framework Security \
  -lm \
  -o "$build_dir/sample_bench"

"$build_dir/sample_bench" "$input" "$run_parent/run" "$@"
