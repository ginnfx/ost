#!/usr/bin/env bash
# Build the LAN companion for iOS. A simulator build needs no paid account.
# For a personal iPhone, open the generated Xcode project, choose your Personal
# Team for OSTTrackerIOS, select the device, and press Run.
# --archive keeps the TestFlight path for paid Apple Developer Program members.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
cd "$REPO_ROOT/OSTTracker"
xcodegen generate

if [[ "${1:-}" == "--archive" ]]; then
  if [[ -z "${TEAM_ID:-}" ]]; then
    echo "TEAM_ID is required for a signed TestFlight archive" >&2
    exit 2
  fi
  ARCHIVE="$HERE/runtime/OSTTrackerIOS.xcarchive"
  EXPORT_DIR="$HERE/runtime/export"
  mkdir -p "$HERE/runtime" "$EXPORT_DIR"
  xcodebuild -project OSTTracker.xcodeproj -scheme OSTTrackerIOS \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" archive
  cat > "$EXPORT_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM_ID}</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR"
  echo "IPA: $EXPORT_DIR/OSTTrackerIOS.ipa"
else
  xcodebuild -project OSTTracker.xcodeproj -scheme OSTTrackerIOS \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
fi
