#!/bin/zsh
# Launches the Mac build with launch arguments and screenshots its window.
#   scripts/mac_shot.sh out.png -demo -open "API design" -theme dark
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; shift
# A separate copy with its own bundle ID, so it never touches an installed BlankNote (TestFlight):
# same-ID copies share settings and notes, and macOS won't give a second one a window.
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodebuild -project BlankNote.xcodeproj -scheme BlankNote -destination 'platform=macOS' \
  -derivedDataPath build/ShotData -configuration Debug build -quiet BUNDLE_ID_PREFIX=org.example.shot
app="$PWD/build/ShotData/Build/Products/Debug/BlankNote.app"
pkill -f "$app/" 2>/dev/null || true
sleep 0.5
open -n "$app" --args "$@"
sleep 2
# A launch from a script doesn't always bring up the first window; a reopen does.
open "$app"
sleep ${SHOT_DELAY:-3}
if [[ ! -x build/tools/winlist || scripts/winlist.swift -nt build/tools/winlist ]]; then
  mkdir -p build/tools
  xcrun swiftc -O scripts/winlist.swift -o build/tools/winlist
fi
# Its main window: the on-screen layer-0 window taller than the menu bar.
pid=$(pgrep -f "$app/Contents/MacOS/BlankNote" | head -1)
id=$(build/tools/winlist "pid:$pid" | awk '$2 == 0 && $4 > 100 && $5 == 1 { print $1; exit }')
screencapture -o -l "$id" "$out"
echo "$out (window $id)"
kill "$pid" 2>/dev/null || true
