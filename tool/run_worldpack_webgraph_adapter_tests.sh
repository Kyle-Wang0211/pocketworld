#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_root=${PW_WEBGRAPH_SOURCE:-/private/tmp/pw_worldpack_upstreams.8vBT0j/webgraph-rs}
build_root=${PW_WEBGRAPH_BUILD_ROOT:-/private/tmp/pw_worldpack_webgraph_build.f8698a7}
adapter_bin_dir=${PW_WEBGRAPH_ADAPTER_BIN_DIR:-/private/tmp/pw_worldpack_webgraph_adapter_bin.f8698a7}
shim_dir=/private/tmp/pw_worldpack_cargo_shim.llhttp_9_4_for_9_3
cargo_bin=/opt/homebrew/bin/cargo
llhttp_library=/opt/homebrew/Cellar/llhttp/9.4.1/lib/libllhttp.9.4.1.dylib

test "$(git -C "$source_root" rev-parse HEAD)" = "f8698a7bdda2c4e171017548307179cd5c7a3166"
test -z "$(git -C "$source_root" status --porcelain)"
test -f "$repo_root/experiments/worldpack_official_completion/webgraph-Cargo.lock"
test -x "$cargo_bin"
test -f "$llhttp_library"

mkdir -p "$shim_dir" "$adapter_bin_dir"
ln -sfn "$llhttp_library" "$shim_dir/libllhttp.9.3.dylib"
if ! test -d "$build_root/webgraph"; then
  mkdir -p "$build_root"
  rsync -a --exclude .git "$source_root"/ "$build_root"/
fi
cp "$repo_root/experiments/worldpack_official_completion/webgraph-Cargo.lock" "$build_root/Cargo.lock"
cp "$repo_root/tool/worldpack_webgraph_adapter.rs" \
  "$build_root/webgraph/examples/worldpack_webgraph_adapter.rs"

DYLD_LIBRARY_PATH="$shim_dir" "$cargo_bin" test --locked \
  --manifest-path "$build_root/Cargo.toml" -p webgraph \
  --test test_bvgraph_roundtrip --release
DYLD_LIBRARY_PATH="$shim_dir" "$cargo_bin" build --locked \
  --manifest-path "$build_root/Cargo.toml" -p webgraph \
  --example worldpack_webgraph_adapter --release
cp "$build_root/target/release/examples/worldpack_webgraph_adapter" \
  "$adapter_bin_dir/worldpack_webgraph_adapter"
chmod 755 "$adapter_bin_dir/worldpack_webgraph_adapter"
echo "$adapter_bin_dir/worldpack_webgraph_adapter"
