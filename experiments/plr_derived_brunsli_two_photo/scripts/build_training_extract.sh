#!/bin/sh
set -eu

experiment_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir=/private/tmp/pw-plr-derived-brunsli-source/v0.1
build_dir="$experiment_root/build/v0.1"
commit=8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c

if [ ! -d "$source_dir/.git" ]; then
  echo "pinned Brunsli v0.1 source is missing: $source_dir" >&2
  exit 2
fi
if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$commit" ]; then
  echo "Brunsli source identity mismatch" >&2
  exit 3
fi

cmake \
  -S "$experiment_root/native" \
  -B "$build_dir" \
  -DBRUNSLI_SOURCE_DIR="$source_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$build_dir" --target pw_brunsli_training_extract -j 8

echo "PW_BRUNSLI_TRAINING_EXTRACT_OK commit=$commit binary=$build_dir/pw_brunsli_training_extract"
