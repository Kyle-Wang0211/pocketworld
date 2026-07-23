#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${1:-"$ROOT/Frameworks/PWOfficialSfm.xcframework/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm"}
EXPECTED="$ROOT/pwofficial_abi_symbols.txt"
EXPECTED_IO="$ROOT/pwofficial_io_abi_symbols.txt"

if [ ! -f "$BIN" ]; then
  echo "FAIL: official dynamic binary missing: $BIN" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pwofficial-boundary.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

nm -gjU "$BIN" | sed 's/^_//' | LC_ALL=C sort -u > "$TMP_DIR/actual.txt"
LC_ALL=C sort -u "$EXPECTED" "$EXPECTED_IO" > "$TMP_DIR/expected.txt"

if ! diff -u "$TMP_DIR/expected.txt" "$TMP_DIR/actual.txt"; then
  echo "FAIL: dynamic export surface is not the frozen pwofficial ABI" >&2
  exit 1
fi

if nm -gjU "$BIN" | sed 's/^_//' | grep -Eq '^(pwsfm_|aether_|__Z|_Z)'; then
  echo "FAIL: self-pipeline or internal native symbol escaped the framework" >&2
  exit 1
fi

if ! file "$BIN" | grep -q 'dynamically linked shared library'; then
  echo "FAIL: PWOfficialSfm is not a dynamic Mach-O image" >&2
  exit 1
fi

MACH_HEADER=$(otool -hv "$BIN")
if ! echo "$MACH_HEADER" | tail -n 1 | grep -qw 'TWOLEVEL'; then
  echo "FAIL: PWOfficialSfm is not using Mach-O two-level namespace binding" >&2
  exit 1
fi
if ! echo "$MACH_HEADER" | tail -n 1 | grep -qw 'NOUNDEFS'; then
  echo "FAIL: PWOfficialSfm was linked with unresolved definitions" >&2
  exit 1
fi

CUSTOM_UNDEFINED=$(nm -u "$BIN" | grep -E 'pwofficial_|pwsfm_|aether_' || true)
if [ -n "$CUSTOM_UNDEFINED" ]; then
  echo "FAIL: PWOfficialSfm retains custom pipeline undefined symbols:" >&2
  echo "$CUSTOM_UNDEFINED" >&2
  exit 1
fi

INSTALL_NAME=$(otool -D "$BIN" | tail -n 1)
if [ "$INSTALL_NAME" != '@rpath/PWOfficialSfm.framework/PWOfficialSfm' ]; then
  echo "FAIL: unexpected framework install_name: $INSTALL_NAME" >&2
  exit 1
fi

LEGACY_KEYS=$(strings "$BIN" | grep '^AETHER_' | grep -v '^AETHER_SFM_' || true)
if [ -n "$LEGACY_KEYS" ]; then
  echo "FAIL: official runtime still reads self-route AETHER_* keys:" >&2
  echo "$LEGACY_KEYS" >&2
  exit 1
fi

if strings "$BIN" | grep -q 'pwsfm_'; then
  echo "FAIL: official runtime contains a self-route pwsfm_ dependency/label" >&2
  exit 1
fi

if strings "$BIN" | grep -Eq 'AETHER_SFM_ERR_BUSY|AppendRemovedId|RemovedSidecarPath|\.removed|tombstone'; then
  echo "FAIL: official runtime contains b930-only resume/tombstone semantics" >&2
  exit 1
fi

if strings "$BIN" | grep -Eq '^(sfm_fed_frames\.jsonl|finalize_segments\.json(\.tmp)?)$'; then
  echo "FAIL: official runtime contains a self-route sidecar filename" >&2
  exit 1
fi
for SIDECAR in official_sfm_fed_frames.jsonl official_finalize_segments.json; do
  if ! strings "$BIN" | grep -qx "$SIDECAR"; then
    echo "FAIL: official sidecar filename missing: $SIDECAR" >&2
    exit 1
  fi
done

echo "PASS: $(wc -l < "$TMP_DIR/actual.txt" | tr -d ' ') official ABI exports; TWOLEVEL/NOUNDEFS; isolated install_name/config namespace"
