#!/bin/sh
set -eu

experiment_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=v0.1
scratch_root=/private/tmp/pw-plr-derived-brunsli-source

while [ "$#" -gt 0 ]; do
  case "$1" in
    --revision)
      revision=$2
      shift 2
      ;;
    --scratch-root)
      scratch_root=$2
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$revision" in
  v0.1)
    commit=8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c
    ;;
  master)
    commit=c9128f43994c1ca830dd079777d85f16736d6ba7
    ;;
  *)
    echo "revision must be v0.1 or master" >&2
    exit 2
    ;;
esac

source_dir="$scratch_root/$revision"
build_dir="$experiment_root/build/$revision"

mkdir -p "$scratch_root" "$experiment_root/build"
if [ ! -d "$source_dir/.git" ]; then
  git clone https://github.com/google/brunsli.git "$source_dir"
fi

git -C "$source_dir" fetch origin "$commit"
git -C "$source_dir" checkout --detach "$commit"
if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$commit" ]; then
  echo "Brunsli checkout identity mismatch" >&2
  exit 3
fi
git -C "$source_dir" submodule sync
git -C "$source_dir" submodule update --init --depth 1

cmake \
  -S "$experiment_root/native" \
  -B "$build_dir" \
  -DBRUNSLI_SOURCE_DIR="$source_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$build_dir" --target pw_brunsli_side_adapter -j 8

actual_commit=$(git -C "$source_dir" rev-parse HEAD)
echo "PW_BRUNSLI_BUILD_OK revision=$revision commit=$actual_commit binary=$build_dir/pw_brunsli_side_adapter"
