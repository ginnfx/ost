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
# python-build-standalone publishes aarch64-apple-ios builds; the install_only
# asset carries the stdlib + a static libpython. If a framework layout is
# needed instead, fall back to BeeWare python-ios-support.
mkdir -p "$IOS_RUNTIME"
if [ ! -d "$IOS_RUNTIME/Python.framework" ] && [ ! -f "$IOS_RUNTIME/lib/libpython3.11.a" ]; then
  TAG="20260623"
  ASSET="cpython-3.11.15+${TAG}-aarch64-apple-ios-install_only.tar.gz"
  URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${ASSET}"
  echo "fetching $ASSET"
  curl -L -o "$HERE/runtime/$ASSET" "$URL"
  mkdir -p "$IOS_RUNTIME"
  tar -xzf "$HERE/runtime/$ASSET" -C "$IOS_RUNTIME" --strip-components=1
  # Layout expected by the Xcode target: lib/libpython3.11.a + include/ headers.
  # (python-build-standalone ships python/lib — adjust paths if the layout
  # differs on the pinned tag; BeeWare's python-ios-support yields a framework
  # that plugs into FRAMEWORK_SEARCH_PATHS instead.)
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
