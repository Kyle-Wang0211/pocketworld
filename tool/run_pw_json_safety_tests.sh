#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d /private/tmp/pw_json_safety_tests.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

xcrun swiftc \
  "$repo_root/ios/Runner/PWJSONSafety.swift" \
  "$repo_root/tool/PWJSONSafetyStandaloneTests.swift" \
  -o "$test_root/pw_json_safety_tests"

"$test_root/pw_json_safety_tests"
