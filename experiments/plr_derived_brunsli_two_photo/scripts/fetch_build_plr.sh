#!/bin/sh
set -eu

revision=8a65e4d0d3daa9292e40df0541e8f43fcaada2d7
repository=https://github.com/zhuiguangzhe123/PLR.git
experiment_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_directory="$experiment_root/build/plr-upstream"
python="$experiment_root/.venv/bin/python"

if [ ! -d "$source_directory/.git" ]; then
  git clone --filter=blob:none --no-checkout "$repository" "$source_directory"
  git -C "$source_directory" checkout --detach "$revision"
fi

actual_revision=$(git -C "$source_directory" rev-parse HEAD)
if [ "$actual_revision" != "$revision" ]; then
  echo "PLR revision mismatch: expected $revision, got $actual_revision" >&2
  exit 1
fi

for patch_file in \
  "$experiment_root/patches/plr-lazy-import.patch" \
  "$experiment_root/patches/plr-exact-22-stage.patch"
do
  if git -C "$source_directory" apply --reverse --check "$patch_file" 2>/dev/null; then
    :
  elif git -C "$source_directory" apply --check "$patch_file" 2>/dev/null; then
    git -C "$source_directory" apply "$patch_file"
  else
    echo "PLR patch is neither applicable nor already applied: $patch_file" >&2
    exit 1
  fi
done

(cd "$source_directory" && "$python" setup.py build_ext --inplace)

PYTHONPATH="$source_directory" "$python" -c \
  'import compressai.ans, compressai._CXX; from compressai.models.trans_eff import TransJPEGRecompression422; print("PLR_BUILD_OK")'
