#!/usr/bin/env bash
# PocketWorld — 16 KB page-size acceptance check.
#
# Google Play, verbatim from developer.android.com/guide/practices/page-sizes:
#   "Starting February 1, 2027, if your app updates don't support 16 KB memory
#    page sizes, you won't be able to release these updates."
#
# TWO INDEPENDENT PROPERTIES, both required, both silently absent on a 4 KB
# device and at build time:
#
#   (A) ELF segment alignment  -- every PT_LOAD in every .so aligned to 16 KB.
#       Produced by the NDK that compiled the library (r28+). This is the one
#       that catches PREBUILTS: xrslam, OpenCV, any Flutter plugin's .so.
#       Checked by check_elf_align.py -- pure Python, no Android SDK needed,
#       so it runs in CI and on a laptop.
#
#   (B) Zip alignment          -- uncompressed .so placed on 16 KB boundaries
#       inside the APK. Produced by AGP 8.5.1+ together with
#       extractNativeLibs="false". Google's own command, verbatim:
#           zipalign -c -P 16 -v 4 APK_NAME.apk
#       Requires Android build-tools. When zipalign is absent this script says
#       so and exits non-zero, rather than reporting a pass it did not perform.
#
# Usage:
#   verify_16kb.sh <app.apk|app.aab>          full check, (A) + (B)
#   verify_16kb.sh <dir-of-.so>               (A) only, for a prebuilt audit
#
# Exit: 0 all checks performed and passed; 1 a check failed; 2 a check could
#       not be performed (which is never reported as a pass).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$HERE/check_elf_align.py"

if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") <app.apk|app.aab|dir-of-so>" >&2
  exit 2
fi

TARGET="$1"
if [ ! -e "$TARGET" ]; then
  echo "no such path: $TARGET" >&2
  exit 2
fi

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "python3 not found; cannot run the ELF check" >&2
  exit 2
fi

rc=0

if [ -d "$TARGET" ]; then
  echo "== (A) ELF PT_LOAD alignment: $TARGET"
  "$PYTHON" "$CHECKER" "$TARGET" || rc=1
  echo
  echo "== (B) zip alignment: not applicable to a directory"
  exit "$rc"
fi

WORK="$(mktemp -d)"
# shellcheck disable=SC2317  # invoked via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "== (A) ELF PT_LOAD alignment inside $TARGET"
if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip not found; cannot open the archive" >&2
  exit 2
fi
# An APK keeps native code under lib/<abi>/; an AAB under base/lib/<abi>/.
unzip -qq -o "$TARGET" 'lib/*' 'base/lib/*' -d "$WORK" 2>/dev/null || true
if [ -z "$(find "$WORK" -name '*.so' -print -quit)" ]; then
  echo "no .so found under lib/ -- either this build ships no native code," >&2
  echo "or the archive layout is unexpected. Not treating that as a pass." >&2
  exit 2
fi
"$PYTHON" "$CHECKER" "$WORK" || rc=1

echo
echo "== (B) zip alignment (Google's documented command)"
ZIPALIGN="${ZIPALIGN:-}"
if [ -z "$ZIPALIGN" ] && command -v zipalign >/dev/null 2>&1; then
  ZIPALIGN="$(command -v zipalign)"
fi
if [ -z "$ZIPALIGN" ] && [ -n "${ANDROID_HOME:-}" ]; then
  # Newest build-tools directory that actually contains zipalign.
  while IFS= read -r cand; do
    [ -x "$cand" ] && ZIPALIGN="$cand" && break
  done < <(find "$ANDROID_HOME/build-tools" -maxdepth 2 -name zipalign 2>/dev/null | sort -r)
fi

case "$TARGET" in
  *.aab)
    echo "SKIP: zipalign checks an APK, not an AAB."
    echo "      Build the universal APK first:"
    echo "        bundletool build-apks --mode=universal --bundle=$TARGET --output=/tmp/u.apks"
    echo "      then re-run this script on the extracted universal.apk."
    # A hard FAIL from (A) outranks "incomplete": never downgrade 1 to 2.
    [ "$rc" -eq 1 ] || rc=2
    ;;
  *)
    if [ -z "$ZIPALIGN" ]; then
      echo "SKIP: zipalign not found (set ZIPALIGN=/path/to/zipalign or ANDROID_HOME)."
      echo "      Check (B) was NOT performed. This is not a pass."
      # A hard FAIL from (A) outranks "incomplete": never downgrade 1 to 2.
      [ "$rc" -eq 1 ] || rc=2
    else
      echo "\$ $ZIPALIGN -c -P 16 -v 4 $TARGET"
      if "$ZIPALIGN" -c -P 16 -v 4 "$TARGET" > "$WORK/zipalign.log" 2>&1; then
        echo "PASS  zip-aligned at 16 KB"
      else
        echo "FAIL  not 16 KB zip-aligned. Offending entries:"
        grep -i 'BAD' "$WORK/zipalign.log" | head -40 || true
        echo "      Fix: AGP >= 8.5.1 and android:extractNativeLibs=\"false\"."
        rc=1
      fi
    fi
    ;;
esac

echo
if [ "$rc" -eq 0 ]; then
  echo "RESULT: 16 KB ready (both checks performed and passed)."
elif [ "$rc" -eq 1 ]; then
  echo "RESULT: FAILED a 16 KB check."
else
  echo "RESULT: INCOMPLETE -- a required check could not be run. Not a pass."
fi
exit "$rc"
