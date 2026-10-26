#!/bin/zsh
# Archives a Release build for iPhone and iPad and uploads it to App Store Connect for TestFlight.
#   scripts/testflight.sh [--no-upload]    (--no-upload stops after the signed archive)
#
# Needs your own signing setup, none of which lives in the repo:
#   - Config/Local.xcconfig with BUNDLE_ID_PREFIX and DEVELOPMENT_TEAM (see Config/Signing.xcconfig).
#   - An "Apple Distribution" certificate in the login keychain, and an App Store provisioning profile
#     for the app's bundle ID, named "BlankNote App Store" (or set APPSTORE_PROFILE).
#   - Auth for the upload: Xcode signed in to the team's Apple ID, or an App Store Connect API key in
#     ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH.
# Signing is manual, so no registered test device is needed. The build number is a timestamp, so
# every upload is unique and increasing.
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."

setting() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p" Config/Local.xcconfig 2>/dev/null | tail -1; }
prefix=$(setting BUNDLE_ID_PREFIX) team=$(setting DEVELOPMENT_TEAM)
if [[ -z $prefix || -z $team ]]; then
  echo "Set BUNDLE_ID_PREFIX and DEVELOPMENT_TEAM in Config/Local.xcconfig first."; exit 1
fi
bundle=$prefix.blanknote
profile=${APPSTORE_PROFILE:-BlankNote App Store}

BUILD_NUMBER=$(date +%Y%m%d%H%M)
ARCHIVE=build/BlankNote-$BUILD_NUMBER.xcarchive
auth=()
if [[ -n ${ASC_KEY_ID:-} ]]; then
  auth=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

xcodegen generate --quiet
echo "Archiving $bundle build $BUILD_NUMBER…"
xcodebuild -project BlankNote.xcodeproj -scheme BlankNote -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="$profile" \
  $auth archive | grep -E "error:|warning: .*signing|ARCHIVE (SUCCEEDED|FAILED)"

if [[ ${1:-} == --no-upload ]]; then
  echo "Archive at $ARCHIVE (not uploaded)."
  exit 0
fi

export_options=build/ExportOptions.plist
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
  <key>provisioningProfiles</key>
  <dict><key>$bundle</key><string>$profile</string></dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist $export_options \
  -exportPath build/export -allowProvisioningUpdates $auth | grep -E "error:|Upload|EXPORT (SUCCEEDED|FAILED)"
echo "Done. Build $BUILD_NUMBER shows up in App Store Connect › TestFlight after processing (usually 5–30 min)."
