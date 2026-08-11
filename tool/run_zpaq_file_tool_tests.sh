#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d /private/tmp/pw-zpaq-tool-build.XXXXXX)
run_dir=$(mktemp -d /private/tmp/pw-zpaq-tool-test.XXXXXX)
cleanup() {
  find "$build_dir" -mindepth 1 -delete
  find "$run_dir" -mindepth 1 -delete
  rmdir "$build_dir" "$run_dir"
}
trap cleanup EXIT HUP INT TERM

common_flags="-std=c++17 -O2 -Dunix -DNOJIT"
xcrun clang++ \
  -std=c++17 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-unused-parameter \
  -Wno-null-pointer-subtraction \
  -Dunix \
  -DNOJIT \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  -c "$repo_root/tool/zpaq_file_tool.cpp" \
  -o "$build_dir/zpaq_file_tool.o"
xcrun clang++ \
  $common_flags \
  -I"$repo_root/ios/Vendor/Zpaq/include" \
  -c \
  "$repo_root/ios/Vendor/Zpaq/src/libzpaq.cpp" \
  -o "$build_dir/libzpaq.o"
xcrun clang++ \
  "$build_dir/zpaq_file_tool.o" \
  "$build_dir/libzpaq.o" \
  -framework Security \
  -o "$build_dir/zpaq_file_tool"

python3 - "$run_dir/input.bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
payload = bytearray()
for index in range(200000):
    payload.extend(((index // 97) & 0xff, index & 0x07, 0, 0))
path.write_bytes(payload)
PY

"$build_dir/zpaq_file_tool" version >"$run_dir/version.txt"
grep -q '^7.15 e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418$' "$run_dir/version.txt"
"$build_dir/zpaq_file_tool" compress "$run_dir/input.bin" "$run_dir/archive.zpaq"
"$build_dir/zpaq_file_tool" decompress "$run_dir/archive.zpaq" "$run_dir/restored.bin"
cmp "$run_dir/input.bin" "$run_dir/restored.bin"

python3 - "$run_dir/archive.zpaq" "$run_dir/corrupt.zpaq" <<'PY'
from pathlib import Path
import sys

source = bytearray(Path(sys.argv[1]).read_bytes())
source[len(source) // 2] ^= 0x80
Path(sys.argv[2]).write_bytes(source)
PY
if "$build_dir/zpaq_file_tool" decompress "$run_dir/corrupt.zpaq" "$run_dir/corrupt.out"; then
  if cmp -s "$run_dir/input.bin" "$run_dir/corrupt.out"; then
    echo "corrupt archive unexpectedly restored the original" >&2
    exit 1
  fi
fi

echo "PW_ZPAQ_FILE_TOOL_TESTS_OK"
