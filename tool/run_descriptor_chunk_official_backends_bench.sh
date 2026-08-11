#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
input=/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db
output="$repo_root/experiments/descriptor_chunk_official_backends/results/2026-08-02-minimal-chunk.json"
descriptor_count=16384
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

: "${PW_DESCRIPTOR_BACKENDS_SRC:?set PW_DESCRIPTOR_BACKENDS_SRC to the pinned source root}"
: "${PW_DESCRIPTOR_BACKENDS_BUILD:?set PW_DESCRIPTOR_BACKENDS_BUILD to the temporary build root}"
source_root=$PW_DESCRIPTOR_BACKENDS_SRC
build_root=$PW_DESCRIPTOR_BACKENDS_BUILD

openzl_commit=3dceb64867840201fb8f57a29d179995f700c9b8
blosc2_commit=7265419b23872707b1b52298d5f1469c9ea7b9e7
pcodec_commit=2d8555888b21bbaa19326580b740fa24b7da6bd3

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
    echo "pinned official source identity mismatch: $checkout" >&2
    exit 5
  fi
}

expected_source_bytes=198983680
expected_source_sha=0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0
if [ "$(stat -f %z "$input")" != "$expected_source_bytes" ] ||
   [ "$(shasum -a 256 "$input" | awk '{print $1}')" != "$expected_source_sha" ] ||
   [ "$(sqlite3 "file:$input?immutable=1" 'PRAGMA integrity_check;')" != ok ]; then
  echo "immutable SQLite source identity or integrity mismatch" >&2
  exit 3
fi

verify_checkout "$source_root/openzl" v0.2.0 "$openzl_commit" \
  371ed262b7969ba0a52f009588c0215df0e455c86b88356e8753748fad8296a5
verify_checkout "$source_root/c-blosc2" v3.3.0 "$blosc2_commit" \
  22623131a9b9f6a86a4dc6b9bccbb1d2aeb390df86bca00fc727af24735c2fae
verify_checkout "$source_root/pcodec" v1.0.2 "$pcodec_commit" \
  c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4

openzl_build="$build_root/openzl"
blosc_build="$build_root/c-blosc2"
zli="$openzl_build/cli/zli"
cpcodec="$source_root/pcodec/target/release/libcpcodec.dylib"
for artifact in \
  "$zli" \
  "$openzl_build/libopenzl.a" \
  "$blosc_build/blosc/libblosc2.a" \
  "$cpcodec"; do
  if [ ! -s "$artifact" ]; then
    echo "required pinned build artifact is missing: $artifact" >&2
    exit 6
  fi
done

faiss_prefix=/opt/homebrew/opt/faiss
expected_faiss_sha=cbd11b958ff233d4cc1dc0fe010890b4677ef81c2e0a039ff4567d365946e473
if [ "$(shasum -a 256 "$faiss_prefix/lib/libfaiss.dylib" | awk '{print $1}')" != "$expected_faiss_sha" ]; then
  echo "pinned Faiss library identity mismatch" >&2
  exit 7
fi

build_dir="$(mktemp -d /private/tmp/pw-descriptor-chunk-bench-build.XXXXXX)"
run_dir="$(mktemp -d /private/tmp/pw-descriptor-chunk-bench-run.XXXXXX)"
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  find "$run_dir" -mindepth 1 -delete
  rmdir "$build_dir" "$run_dir"
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
  -I"$source_root/pcodec/pco_c/include" \
  -I"$source_root/c-blosc2/include" \
  -I"$source_root/openzl/include" \
  -I"$openzl_build/include" \
  -I"$faiss_prefix/include" \
  "$repo_root/tool/descriptor_chunk_official_backends_bench.cpp" \
  "$repo_root/tool/descriptor_chunk_archive.cpp" \
  "$repo_root/tool/descriptor_similarity_forest.cpp" \
  "$repo_root/tool/pwa2_official_codec_backend.cpp" \
  "$repo_root/ios/Runner/pw_zpaq_bridge.cpp" \
  "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  "$cpcodec" \
  "$blosc_build/blosc/libblosc2.a" \
  "$openzl_build/libopenzl.a" \
  "$openzl_build/zstd_build/lib/libzstd.a" \
  "$openzl_build/lz4_build/liblz4.a" \
  "$blosc_build/_deps/zfp-build/lib/libzfp.a" \
  -L"$faiss_prefix/lib" \
  -Wl,-rpath,"$faiss_prefix/lib" \
  -Wl,-rpath,"$source_root/pcodec/target/release" \
  -lfaiss \
  -lsqlite3 \
  -framework Security \
  -lm \
  -o "$build_dir/descriptor_chunk_official_backends_bench"

if [ "$compile_only" -eq 1 ]; then
  echo '{"compile_ok":1}'
  exit 0
fi

mkdir -p "$(dirname "$output")"
OMP_NUM_THREADS=8 "$build_dir/descriptor_chunk_official_backends_bench" \
  "$input" "$zli" "$run_dir" "$output"

if [ "$(stat -f %z "$input")" != "$expected_source_bytes" ] ||
   [ "$(shasum -a 256 "$input" | awk '{print $1}')" != "$expected_source_sha" ]; then
  echo "source changed during descriptor chunk benchmark" >&2
  exit 8
fi

test -s "$output"
echo "PW_DESCRIPTOR_CHUNK_OFFICIAL_BACKENDS_RUN_OK descriptor_count=$descriptor_count"
shasum -a 256 "$output"
