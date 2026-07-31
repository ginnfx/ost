#!/usr/bin/env bash
# Auto-install the freshly-built app into /Applications so the app you launch
# from Spotlight/Launchpad/Dock is ALWAYS the one you just built. Without this,
# the build product lives in DerivedData while a stale copy lingers in
# /Applications — the "my changes vanished / the tab is gone" trap.
#
# Runs as a post-build phase after the runtime embed (see project.yml), so the
# installed app is self-contained (embedded Python runtime + current backend).
#
# Opt out for a one-off build with:  OST_SKIP_INSTALL=1 xcodebuild …
set -euo pipefail

if [[ "${OST_SKIP_INSTALL:-0}" == "1" ]]; then
    echo "OST_SKIP_INSTALL=1 — leaving /Applications untouched"
    exit 0
fi

APP_SRC="${BUILT_PRODUCTS_DIR:?}/${FULL_PRODUCT_NAME:?}"   # …/OSTTracker.app
DEST="/Applications/${FULL_PRODUCT_NAME}"

if [[ ! -d "$APP_SRC" ]]; then
    echo "no built app at $APP_SRC; skipping install"
    exit 0
fi

if [[ ! -w /Applications ]]; then
    echo "warning: /Applications not writable; skipping auto-install"
    exit 0
fi

# Refuse to overwrite a running copy — replacing a live bundle's files can crash
# the running app mid-session. Quit it first, then re-run the build.
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null 2>&1; then
    echo "warning: $DEST is running; quit it and rebuild to update the installed app"
    exit 0
fi

echo "installing $FULL_PRODUCT_NAME into /Applications"
# ditto preserves the bundle exactly (perms, symlinks, xattrs) and replaces the
# destination atomically enough for LaunchServices to re-index cleanly.
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"

# This script phase can run before Xcode's own CodeSign step finishes signing
# $APP_SRC (both are post-build phases; ordering between them isn't guaranteed),
# which would install an unsigned binary that recent macOS refuses to launch at
# all ("Security policy would not allow process"). Ad-hoc re-sign the installed
# copy directly so it's always launchable regardless of that race.
codesign --force --deep --sign - "$DEST"

echo "installed $DEST ($CONFIGURATION build)"
