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
# Inkwell's own simulators: "Inkwell iPhone" runs every UI test; "Inkwell iPad" adds the
# hardware-keyboard shortcut tests (they skip on iPhone).
sim() {
  local name=$1 type=$2 udid
  udid=$(xcrun simctl list devices available | { grep "$name (" || true; } | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [[ -z $udid ]] && udid=$(xcrun simctl create "$name" "$type" com.apple.CoreSimulator.SimRuntime.iOS-26-1)
  echo $udid
}
run() {
  echo "== $1"
  xcodebuild test -project Inkwell.xcodeproj -scheme Inkwell -destination "id=$2" \
    -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO "${@:3}" 2>&1 \
    | grep -E "Test Case .*(passed|failed|skipped)|error:|\*\* TEST" | grep -v simctl || true
}
run "iPhone" "$(sim "Inkwell iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)"
run "iPad" "$(sim "Inkwell iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB)" \
  -only-testing:InkwellUITests/ShortcutsAndToastsUITests
