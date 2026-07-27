#!/bin/zsh
set -euo pipefail

DEVICE_ID="1B290474-D354-5B4C-AAB0-0805AC5DC832"
BUNDLE_ID="com.kyle.PocketWorld"
REPO="/Users/kaidongwang/Developer/pocketworld"
EXPECTED_REVISION="fd87494d0fcbecb36623b4568eade6d582774119"
RUN_ROOT="$(mktemp -d /private/tmp/pw_project_delete_update.XXXXXX)"
BACKUP_ROOT="$RUN_ROOT/before"
LOG_PATH="/private/tmp/pw_project_delete_update.log"
ROOT_POINTER="/private/tmp/pw_project_delete_update_root.txt"

: > "$LOG_PATH"
print -r -- "$RUN_ROOT" > "$ROOT_POINTER"
exec > >(tee -a "$LOG_PATH") 2>&1
printf '\033]0;PW Permanent Delete Safe Update\007'

echo "SAFE_UPDATE_ROOT=$RUN_ROOT"
cd "$REPO"

if [[ "$(git rev-parse HEAD)" != "$EXPECTED_REVISION" ]]; then
  echo "ERROR: product revision changed before backup"
  exit 20
fi

mkdir -p "$BACKUP_ROOT/Documents" "$BACKUP_ROOT/Library"
echo "BACKUP_START"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --user mobile \
  --source Documents \
  --destination "$BACKUP_ROOT/Documents" \
  --timeout 1200
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --user mobile \
  --source Library \
  --destination "$BACKUP_ROOT/Library" \
  --timeout 1200

DOCUMENT_COUNT="$(find "$BACKUP_ROOT/Documents" -type f | wc -l | tr -d ' ')"
LIBRARY_COUNT="$(find "$BACKUP_ROOT/Library" -type f | wc -l | tr -d ' ')"
if [[ "$DOCUMENT_COUNT" -lt 1 || "$LIBRARY_COUNT" -lt 1 ]]; then
  echo "ERROR: backup is unexpectedly empty"
  exit 21
fi
(
  cd "$BACKUP_ROOT/Documents"
  find . -type f -exec shasum -a 256 {} +
) > "$RUN_ROOT/Documents.before.sha256"
(
  cd "$BACKUP_ROOT/Library"
  find . -type f ! -path '*/SplashBoard/Snapshots/*' \
    -exec shasum -a 256 {} +
) > "$RUN_ROOT/Library.before.sha256"
(
  cd "$BACKUP_ROOT/Documents"
  shasum -a 256 -c "$RUN_ROOT/Documents.before.sha256"
) >/dev/null
(
  cd "$BACKUP_ROOT/Library"
  shasum -a 256 -c "$RUN_ROOT/Library.before.sha256"
) >/dev/null

echo "BACKUP_VERIFIED documents=$DOCUMENT_COUNT library=$LIBRARY_COUNT"
echo "BACKUP_COMPLETE"
