#!/bin/bash
# Deep-sign the app: every Mach-O inside Resources first (codesign --deep is
# deprecated and misses nested .so files), then the main executable + bundle.
# Usage: [CODESIGN_IDENTITY="Developer ID Application: …"] ./05_codesign.sh <path/to/OSTTracker.app>
source "$(dirname "$0")/config.sh"

APP="${1:?usage: 05_codesign.sh <app bundle>}"

TIMESTAMP_FLAG="--timestamp"
[[ "$CODESIGN_IDENTITY" == "-" ]] && TIMESTAMP_FLAG="--timestamp=none"

sign() {
    codesign --force --options runtime $TIMESTAMP_FLAG \
        --sign "$CODESIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$@"
}

echo "signing nested Mach-O files with identity: $CODESIGN_IDENTITY"
find "$APP/Contents/Resources" -type f \
    \( -name "*.so" -o -name "*.dylib" -o -perm +111 \) -print0 \
    | while IFS= read -r -d '' f; do
        file "$f" | grep -q "Mach-O" && sign "$f"
    done

sign "$APP/Contents/MacOS/"*
sign "$APP"

echo "--- verification ---"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>&1 | grep -E "unsigned-executable-memory|disable-library-validation" \
    || { echo "ERROR: entitlements missing" >&2; exit 1; }
echo "codesign OK"
