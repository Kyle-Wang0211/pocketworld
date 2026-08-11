#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
crate_root="$repo_root/native/lepton_jpeg_ffi"
rust_version=1.95.0
rust_target=aarch64-apple-ios
lepton_revision=90fdc27828676892fbb41777cfcc6bad1e470516
license_sha=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
notice_sha=50d7f80a7af7807747f9571a334ad52e1b00f901e025cec4194bc8e557171c1d
tool_root=${PW_LEPTON_TOOL_ROOT:-/private/tmp/pw-lepton-rust-1.95.0}
output_root=${1:-/private/tmp/pw-lepton-ios-arm64}
rustup_root="$tool_root/rustup"
cargo_root="$tool_root/cargo"
rustup_init="$tool_root/rustup-init"
rustup_checksum="$tool_root/rustup-init.sha256"
target_root=${PW_LEPTON_CARGO_TARGET_ROOT:-$tool_root/cargo-target}
archive="$target_root/$rust_target/release/libpw_lepton_jpeg_ffi.a"

mkdir -p "$tool_root" "$output_root" "$target_root"

if [ ! -x "$rustup_init" ]; then
  /usr/bin/curl --fail --location --retry 3 \
    --output "$rustup_init" \
    https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init
  /usr/bin/curl --fail --location --retry 3 \
    --output "$rustup_checksum" \
    https://static.rust-lang.org/rustup/dist/aarch64-apple-darwin/rustup-init.sha256
  expected=$(/usr/bin/awk '{print $1}' "$rustup_checksum")
  actual=$(/usr/bin/shasum -a 256 "$rustup_init" | /usr/bin/awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "rustup-init checksum mismatch" >&2
    exit 1
  fi
  chmod 700 "$rustup_init"
fi

toolchain_root="$rustup_root/toolchains/$rust_version-aarch64-apple-darwin"
if [ ! -x "$toolchain_root/bin/rustc" ] || \
  [ ! -d "$toolchain_root/lib/rustlib/$rust_target" ]; then
  RUSTUP_INIT_SKIP_PATH_CHECK=yes \
    RUSTUP_HOME="$rustup_root" CARGO_HOME="$cargo_root" \
    "$rustup_init" -y --no-modify-path --profile minimal \
    --default-toolchain "$rust_version" --target "$rust_target"
fi

export RUSTUP_HOME="$rustup_root"
export CARGO_HOME="$cargo_root"
export PATH="$cargo_root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CARGO_TARGET_DIR="$target_root"

if [ ! -f "$crate_root/Cargo.lock" ]; then
  echo "missing locked dependency graph: $crate_root/Cargo.lock" >&2
  exit 1
fi

cd "$crate_root"
cargo build --release --locked --target "$rust_target"

package_info=$(find "$cargo_root/registry/src" \
  -path '*/lepton_jpeg-0.5.8/.cargo_vcs_info.json' -print -quit)
if [ -z "$package_info" ] || \
  ! /usr/bin/grep -q "$lepton_revision" "$package_info"; then
  echo "official lepton_jpeg package revision mismatch" >&2
  exit 1
fi
package_root=$(dirname "$package_info")
if ! /usr/bin/grep -q 'license = "Apache-2.0"' \
  "$package_root/Cargo.toml.orig"; then
  echo "official Lepton package license declaration mismatch" >&2
  exit 1
fi
if [ ! -f "$archive" ]; then
  echo "Lepton static library was not produced" >&2
  exit 1
fi

/usr/bin/lipo -info "$archive" | /usr/bin/grep -q 'arm64'
/usr/bin/nm -gU "$archive" | /usr/bin/grep -q '_pw_lepton_encode_jpeg_file'
/usr/bin/nm -gU "$archive" | /usr/bin/grep -q '_pw_lepton_reconstruct_jpeg_file'
/usr/bin/nm -gU "$archive" | /usr/bin/grep -q '_pw_lepton_cancellation_generation'
/usr/bin/nm -gU "$archive" | /usr/bin/grep -q '_pw_lepton_request_cancel'
/usr/bin/nm -gU "$archive" | /usr/bin/grep -q '_pw_lepton_encode_jpeg_file_cancellable'
/usr/bin/nm -gU "$archive" | /usr/bin/grep -q '_pw_lepton_reconstruct_jpeg_file_cancellable'

/usr/bin/ditto "$archive" "$output_root/libpw_lepton_jpeg_ffi.a"
license_file="$output_root/Lepton-LICENSE.txt"
notice_file="$output_root/Lepton-NOTICE.txt"
/usr/bin/curl --fail --location --retry 3 --output "$license_file" \
  "https://raw.githubusercontent.com/microsoft/lepton_jpeg_rust/$lepton_revision/LICENSE.txt"
/usr/bin/curl --fail --location --retry 3 --output "$notice_file" \
  "https://raw.githubusercontent.com/microsoft/lepton_jpeg_rust/$lepton_revision/NOTICE.txt"
actual_license_sha=$(/usr/bin/shasum -a 256 "$license_file" | \
  /usr/bin/awk '{print $1}')
actual_notice_sha=$(/usr/bin/shasum -a 256 "$notice_file" | \
  /usr/bin/awk '{print $1}')
if [ "$actual_license_sha" != "$license_sha" ] || \
  [ "$actual_notice_sha" != "$notice_sha" ]; then
  echo "official Lepton LICENSE/NOTICE hash mismatch" >&2
  exit 1
fi

echo "LEPTON_RUST_VERSION=$(rustc --version)"
echo "LEPTON_CARGO_VERSION=$(cargo --version)"
echo "LEPTON_TARGET=$rust_target"
echo "LEPTON_PACKAGE_REVISION=$lepton_revision"
echo "LEPTON_LICENSE_SHA256=$actual_license_sha"
echo "LEPTON_NOTICE_SHA256=$actual_notice_sha"
echo "LEPTON_ARCHIVE=$output_root/libpw_lepton_jpeg_ffi.a"
echo "LEPTON_ARCHIVE_SHA256=$(/usr/bin/shasum -a 256 "$output_root/libpw_lepton_jpeg_ffi.a" | /usr/bin/awk '{print $1}')"
