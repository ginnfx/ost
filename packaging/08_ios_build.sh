#!/usr/bin/env bash
# Build the iOS app (in-process sidecar) and export an .ipa for TestFlight.
#
# Steps: stage an embedded CPython for iOS, xcodegen, archive, export, upload.
# Requires: Xcode + an Apple Developer Program account; a DEVELOPMENT_TEAM set
# either in project.yml or passed via -xcconfig/team.
#
# Usage:
#   ./08_ios_build.sh                     # archive + export ipa (dev signing)
#   TEAM_ID=ABCDE12345 ./08_ios_build.sh  # provision via team, TestFlight-ready
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
IOS_RUNTIME="$HERE/runtime/ios"
TEAM_ID="${TEAM_ID:-}"

# --- 1) Embedded CPython for iOS ----------------------------------------------
# BeeWare Python-Apple-support ships Python.xcframework (dynamic, arm64 device
# + arm64+x86_64 simulator slice), which Xcode embeds and signs automatically.
# python-build-standalone does not publish iOS builds, so we use BeeWare instead.
BEEWARE_TAG="3.11-b9"
BEEWARE_ASSET="Python-3.11-iOS-support.b9.tar.gz"
BEEWARE_URL="https://github.com/beeware/Python-Apple-support/releases/download/${BEEWARE_TAG}/${BEEWARE_ASSET}"
mkdir -p "$IOS_RUNTIME"
if [ ! -d "$IOS_RUNTIME/Python.xcframework" ]; then
  echo "fetching $BEEWARE_ASSET"
  curl -L -o "$HERE/runtime/$BEEWARE_ASSET" "$BEEWARE_URL"
  tar -xzf "$HERE/runtime/$BEEWARE_ASSET" -C "$IOS_RUNTIME"
  rm -f "$HERE/runtime/$BEEWARE_ASSET"
fi

# --- 2) Generate the Xcode project ---------------------------------------------
cd "$REPO_ROOT/OSTTracker"
xcodegen generate

# --- 3) Archive ------------------------------------------------------------------
ARCHIVE="$HERE/runtime/OSTTrackerIOS.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project OSTTracker.xcodeproj -scheme OSTTrackerIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" archive \
  ${TEAM_ID:+-allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID"} \
  -quiet

# --- 4) Export .ipa ----------------------------------------------------------------
EXPORT_DIR="$HERE/runtime/export"
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
cat > "$EXPORT_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" -quiet

echo "ipa at: $EXPORT_DIR/OSTTrackerIOS.ipa"
echo "upload: xcrun altool --upload-app -f $EXPORT_DIR/OSTTrackerIOS.ipa -t ios"
echo "        (or fastlane pilot upload / TestFlight via App Store Connect)"
