#!/bin/zsh
# Archives Release builds and uploads them to App Store Connect for TestFlight.
#   scripts/testflight.sh [ios|mac|all] [--no-upload]    (default all; --no-upload stops after the archives)
#
# Needs your own signing setup, none of which lives in the repo:
#   - Config/Local.xcconfig with BUNDLE_ID_PREFIX and DEVELOPMENT_TEAM (see Config/Signing.xcconfig).
#   - An "Apple Distribution" certificate in the login keychain (and for the Mac, a "Mac Installer
#     Distribution" one), plus App Store provisioning profiles for the app's bundle ID with the iCloud
#     container iCloud.<bundle ID>: "BlankNote App Store" (iOS) and "BlankNote Mac App Store" (Mac), or
#     set APPSTORE_PROFILE / MAC_APPSTORE_PROFILE.
#   - Auth for the upload: Xcode signed in to the team's Apple ID, or an App Store Connect API key in
#     ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH.
# Signing is manual, so no registered test device is needed. The build number is a timestamp, so
# every upload is unique and increasing.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."

which=all upload=1
for arg in "$@"; do
  case $arg in
    ios|mac|all) which=$arg ;;
    --no-upload) upload=0 ;;
    *) echo "Usage: scripts/testflight.sh [ios|mac|all] [--no-upload]"; exit 1 ;;
  esac
done

setting() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p" Config/Local.xcconfig 2>/dev/null | tail -1; }
prefix=$(setting BUNDLE_ID_PREFIX) team=$(setting DEVELOPMENT_TEAM)
if [[ -z $prefix || -z $team ]]; then
  echo "Set BUNDLE_ID_PREFIX and DEVELOPMENT_TEAM in Config/Local.xcconfig first."; exit 1
fi
bundle=$prefix.blanknote

BUILD_NUMBER=$(date +%Y%m%d%H%M)
auth=()
if [[ -n ${ASC_KEY_ID:-} ]]; then
  auth=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi
xcodegen generate --quiet

# ship <ios|mac>: archive, then upload unless --no-upload.
ship() {
  local platform=$1 destination profile installer=""
  if [[ $platform == ios ]]; then
    destination='generic/platform=iOS' profile=${APPSTORE_PROFILE:-BlankNote App Store}
  else
    destination='generic/platform=macOS' profile=${MAC_APPSTORE_PROFILE:-BlankNote Mac App Store}
    installer="<key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>"
  fi
  local archive=build/BlankNote-$platform-$BUILD_NUMBER.xcarchive
  echo "Archiving $bundle for $platform, build $BUILD_NUMBER…"
  xcodebuild -project BlankNote.xcodeproj -scheme BlankNote -configuration Release \
    -destination "$destination" -archivePath "$archive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="$profile" \
    $auth archive | grep -E "error:|warning: .*signing|ARCHIVE (SUCCEEDED|FAILED)"
  if (( ! upload )); then
    echo "Archive at $archive (not uploaded)."
    return
  fi
  local export_options=build/ExportOptions-$platform.plist
  cat > $export_options <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  $installer
  <key>provisioningProfiles</key>
  <dict><key>$bundle</key><string>$profile</string></dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  echo "Uploading the $platform build to App Store Connect…"
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist $export_options \
    -exportPath build/export-$platform -allowProvisioningUpdates $auth | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)"
}

[[ $which == mac ]] || ship ios
[[ $which == ios ]] || ship mac
(( upload )) && echo "Done. Build $BUILD_NUMBER shows up in App Store Connect › TestFlight after processing (usually 5–30 min)."
true
