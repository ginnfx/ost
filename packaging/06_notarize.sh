#!/bin/bash
# Notarize + staple a signed app. Requires a stored notarytool profile:
#   xcrun notarytool store-credentials ost-notary --apple-id … --team-id … --password <app-specific>
# Usage: ./06_notarize.sh <path/to/OSTTracker.app>
source "$(dirname "$0")/config.sh"

APP="${1:?usage: 06_notarize.sh <app bundle>}"
ZIP="$(mktemp -d)/OSTTracker.zip"

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
