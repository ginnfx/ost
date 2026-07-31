#!/bin/bash
# Build OSTTracker from source and install (or update in place) into /Applications.
#
# This is BOTH the installer and the updater. After changing any code, just run
# ./install.sh again — it rebuilds, re-embeds the Python runtime, ad-hoc signs,
# and atomically swaps the app in /Applications. Your data lives in
# ~/Library/Application Support/OSTTracker and is never touched by an update.
#
# Flags:
#   --launch   Open the app after installing.
#   --clean    Wipe the Xcode build dir first (full rebuild; slower).
#   --deps     Force-refresh bundled Python deps even if already staged.
#
# Free / personal / this-Mac setup: no Apple Developer ID required. Locally built
# apps are not quarantined by Gatekeeper, so ad-hoc signing runs without prompts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# config.sh gives PYTHON_BIN, RUNTIME_DIR, ENTITLEMENTS, etc.
source packaging/config.sh

APP_NAME="OSTTracker"
DEST="/Applications/${APP_NAME}.app"
BUILD_DIR="$REPO_ROOT/OSTTracker/build"
BUILT_APP="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"

LAUNCH=0
FORCE_DEPS=0
for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        --clean)  echo "==> cleaning $BUILD_DIR"; rm -rf "$BUILD_DIR" ;;
        --deps)   FORCE_DEPS=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# --- version stamp -----------------------------------------------------------
# Marketing version comes from the VERSION file; the build number is a UTC
# timestamp so it strictly increases across updates and shows in About OSTTracker.
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
BUILD_NUM="$(date -u +%Y%m%d%H%M)"
echo "==> Building $APP_NAME $VERSION (build $BUILD_NUM)"

# --- 1. stage the embedded Python runtime (idempotent) -----------------------
packaging/01_fetch_runtime.sh

# Only reinstall backend deps when missing (network + slow) unless --deps.
deps_ok=0
if [[ $FORCE_DEPS -eq 0 ]] && "$PYTHON_BIN" -c "import fastapi, uvicorn, yt_dlp, httpx, PIL" 2>/dev/null; then
    deps_ok=1
    echo "bundled deps already present; skipping install (use --deps to refresh)"
fi
if [[ $deps_ok -eq 0 ]]; then
    packaging/02_install_deps.sh
    packaging/03_fix_rpaths.sh
fi

# --- 2. build a Release app (04_copy_runtime.sh runs as an Xcode build phase) -
pushd OSTTracker >/dev/null
xcodegen generate
xcodebuild \
    -project OSTTracker.xcodeproj \
    -scheme OSTTracker \
    -configuration Release \
    -derivedDataPath build \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    build
popd >/dev/null

[[ -d "$BUILT_APP" ]] || { echo "ERROR: build produced no app at $BUILT_APP" >&2; exit 1; }

# --- 3. embed the app icon (assets/icon.icns -> AppIcon.icns) -----------------
cp "$REPO_ROOT/assets/icon.icns" "$BUILT_APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string "AppIcon" "$BUILT_APP/Contents/Info.plist"

# --- 4. ad-hoc deep sign (must come after any plist/resource edits) -----------
CODESIGN_IDENTITY="-" packaging/05_codesign.sh "$BUILT_APP"

# --- 5. atomic install/update into /Applications ------------------------------
# Quit any running copy so the swap is clean, then replace the bundle. mv within
# the same volume is atomic; the running instance (if any) keeps its own inode.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

STAGING="/Applications/.${APP_NAME}.new"
rm -rf "$STAGING"
ditto "$BUILT_APP" "$STAGING"
rm -rf "$DEST"
mv "$STAGING" "$DEST"

# Locally built, but clear quarantine defensively and refresh Launch Services so
# the new icon/version show immediately in Finder and Spotlight.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true

echo "==> Installed $APP_NAME $VERSION (build $BUILD_NUM) to $DEST"
echo "    Data: ~/Library/Application Support/$APP_NAME (preserved across updates)"

if [[ $LAUNCH -eq 1 ]]; then
    echo "==> Launching…"
    open "$DEST"
fi
