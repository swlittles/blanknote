#!/bin/zsh
# Runs the core unit tests (on the Mac) and the iPhone UI tests.
#   scripts/test.sh          everything
#   scripts/test.sh --unit   unit tests only
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
(cd Packages/InkwellCore && swift test 2>&1 | grep -E "✘|Test run|error:" )
[[ ${1:-} == --unit ]] && exit 0
xcodegen generate --quiet
udid=$(xcrun simctl list devices available | { grep "Inkwell iPhone (" || true; } | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -z $udid ]] && udid=$(xcrun simctl create "Inkwell iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-1)
xcodebuild test -project Inkwell.xcodeproj -scheme Inkwell -destination "id=$udid" \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "Test Case .*(passed|failed)|error:|XCTAssert|\*\* TEST" || true
