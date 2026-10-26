#!/bin/zsh
# Builds BlankNote for the Mac and the iOS simulator.
#   scripts/build.sh            both
#   scripts/build.sh mac|ios    one
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodegen generate --quiet
which=${1:-all}
if [[ $which == all || $which == mac ]]; then
  xcodebuild -project BlankNote.xcodeproj -scheme BlankNote -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData -configuration Debug build -quiet
  echo "Mac: build/DerivedData/Build/Products/Debug/BlankNote.app"
fi
if [[ $which == all || $which == ios ]]; then
  xcodebuild -project BlankNote.xcodeproj -scheme BlankNote -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData -configuration Debug build -quiet CODE_SIGNING_ALLOWED=NO
  echo "iOS: build/DerivedData/Build/Products/Debug-iphonesimulator/BlankNote.app"
fi
