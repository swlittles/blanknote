#!/bin/zsh
# Installs the simulator build on Inkwell's own simulators and screenshots it.
#   scripts/sim_shot.sh iphone|ipad out.png [launch args…]
# Example: scripts/sim_shot.sh iphone build/phone.png -demo -open "API design" -appearance dark
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
kind=$1 out=$2; shift 2
case $kind in
  iphone) name="Inkwell iPhone"; type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro ;;
  ipad) name="Inkwell iPad"; type=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB ;;
  *) echo "iphone or ipad"; exit 1 ;;
esac
udid=$(xcrun simctl list devices available | { grep "$name (" || true; } | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [[ -z $udid ]]; then
  udid=$(xcrun simctl create "$name" $type com.apple.CoreSimulator.SimRuntime.iOS-26-1)
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged 2>/dev/null || true
xcrun simctl install "$udid" build/DerivedData/Build/Products/Debug-iphonesimulator/Inkwell.app
xcrun simctl terminate "$udid" com.example.inkwell 2>/dev/null || true
xcrun simctl launch "$udid" com.example.inkwell "$@" >/dev/null
sleep ${SHOT_DELAY:-3}
xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1
echo "$out ($name $udid)"
