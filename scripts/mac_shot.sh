#!/bin/zsh
# Launches the Mac build with launch arguments and screenshots its window.
#   scripts/mac_shot.sh out.png -demo -open "API design" -theme dark
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; shift
pkill -x Inkwell 2>/dev/null || true
sleep 0.5
open -n build/DerivedData/Build/Products/Debug/Inkwell.app --args "$@"
sleep 1.5
# A launch from a script doesn't always bring up the first window; a reopen does.
open build/DerivedData/Build/Products/Debug/Inkwell.app
sleep ${SHOT_DELAY:-2.5}
if [[ ! -x build/tools/winlist ]]; then
  mkdir -p build/tools
  xcrun swiftc -O scripts/winlist.swift -o build/tools/winlist
fi
# The main window is the on-screen layer-0 window taller than the menu bar.
id=$(build/tools/winlist Inkwell | awk '$2 == 0 && $4 > 100 && $5 == 1 { print $1; exit }')
screencapture -o -l "$id" "$out"
echo "$out (window $id)"
