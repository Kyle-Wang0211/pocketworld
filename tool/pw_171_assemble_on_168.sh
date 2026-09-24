#!/bin/bash
# assemble171.sh — build 171 on the carrier 168, the ledger's minimal-change form.
#
# Steps are pw_ship.sh cmd_assemble (~/Developer/pw_backups/pw102_20260906/pw_ship.sh:61-141)
# generalised from ONE replaced binary to the three this build changes, because the Runner could
# not be reproduced byte-for-byte from source (evidence in the ledger entry):
#   cp -R base → dst; replace Runner, Frameworks/App.framework, Info.plist from the candidate
#   build; App.framework file set must equal the base's (pw_ship :88-93); CFBundleVersion 171
#   (pw_ship :98); every framework re-signed with SIGN_ID --timestamp=none (pw_ship :99-101);
#   then — as for 170 (ledger: 「身份章按包内最终字节」) — PWDartAOTSHA256 / PWOfficialSfmSHA256 are
#   set to the hashes of the bytes that are actually in this bundle after signing; top level
#   signed with the entitlements (pw_ship :102); codesign --verify --deep --strict (pw_ship :103).
set -uo pipefail
BUILDS=~/Developer/pw_builds_20260904
BASE="$BUILDS/Runner-168-feature-reuse.app"
CAND="${1:?candidate Runner.app}"
DST="$BUILDS/Runner-171-lod-viewer.app"
SIGN_ID="Apple Development: wkd20040211@gmail.com (8N5Z34UK5Y)"
ENT=~/Developer/pw_backups/pw102_20260906/entitlements.plist
die() { echo "🔴 $*" >&2; exit 1; }

[ -d "$BASE" ] || die "carrier missing: $BASE"
[ -d "$CAND" ] || die "candidate missing: $CAND"
[ ! -e "$DST" ] || die "$DST already exists (not overwriting)"

cp -R "$BASE" "$DST" || die "copy carrier failed"
cp "$CAND/Runner" "$DST/Runner" || die "Runner"
rm -rf "$DST/Frameworks/App.framework"
cp -R "$CAND/Frameworks/App.framework" "$DST/Frameworks/App.framework" || die "App.framework"
echo "=== App.framework file set == carrier's (except the binary) ==="
diff <(cd "$BASE/Frameworks/App.framework" && find . -type f | grep -v '^./App$' | grep -v _CodeSignature | sort) \
     <(cd "$DST/Frameworks/App.framework" && find . -type f | grep -v '^./App$' | grep -v _CodeSignature | sort) \
  && echo "  SAME" || die "App.framework file set differs"
cp "$CAND/Info.plist" "$DST/Info.plist" || die "Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 171" "$DST/Info.plist" || die "CFBundleVersion"

for fw in "$DST"/Frameworks/*.framework; do
  codesign --force --sign "$SIGN_ID" --timestamp=none "$fw" >/dev/null 2>&1 || die "sign $fw"
done
app_sha=$(shasum -a 256 "$DST/Frameworks/App.framework/App" | cut -d' ' -f1)
sfm_sha=$(shasum -a 256 "$DST/Frameworks/PWOfficialSfm.framework/PWOfficialSfm" | cut -d' ' -f1)
/usr/libexec/PlistBuddy -c "Set :PWDartAOTSHA256 $app_sha" "$DST/Info.plist" || die "PWDartAOTSHA256"
/usr/libexec/PlistBuddy -c "Set :PWOfficialSfmSHA256 $sfm_sha" "$DST/Info.plist" || die "PWOfficialSfmSHA256"
codesign --force --sign "$SIGN_ID" --entitlements "$ENT" --timestamp=none "$DST" >/dev/null 2>&1 || die "sign app"
codesign --verify --deep --strict "$DST" || die "codesign verify"
# the stamps still equal the final bytes after the top-level signature
[ "$(shasum -a 256 "$DST/Frameworks/App.framework/App" | cut -d' ' -f1)" = "$app_sha" ] || die "App changed after top-level sign"
[ "$(/usr/libexec/PlistBuddy -c 'Print :PWDartAOTSHA256' "$DST/Info.plist")" = "$app_sha" ] || die "PWDartAOTSHA256 stale"
echo "ASSEMBLED $DST app=$app_sha sfm=$sfm_sha"
