#!/usr/bin/env bash
# Build, ad-hoc code-sign, and verify the OST Tracker macOS .app bundle.
#
# Usage:  ./scripts/build_app.sh
# Produces: dist/OST Tracker.app  (double-clickable, no terminal, no Gatekeeper
# "damaged" prompt on first launch).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PY="${PYTHON:-$ROOT/.venv/bin/python}"
APP="dist/OST Tracker.app"

echo "==> Generating app icon"
"$PY" scripts/make_icon.py || echo "   (icon generation skipped)"

echo "==> Cleaning previous build"
rm -rf build/OSTTracker dist/OSTTracker "dist/OST Tracker.app"

echo "==> Running PyInstaller"
"$PY" -m PyInstaller --noconfirm --clean build/OSTTracker.spec

if [[ ! -d "$APP" ]]; then
  echo "!! Build failed: $APP not found" >&2
  exit 1
fi

echo "==> Ad-hoc code-signing (no Apple Developer account required)"
codesign --sign - --force --deep --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Verifying the bundle boots (offscreen self-test)"
SELFTEST_HOME="$(mktemp -d)"
if QT_QPA_PLATFORM=offscreen OST_TRACKER_SELFTEST=1 OST_TRACKER_HOME="$SELFTEST_HOME" \
     "$APP/Contents/MacOS/OSTTracker"; then
  echo "   Bundle launched and built all screens cleanly."
else
  echo "!! Bundle self-test failed" >&2
  rm -rf "$SELFTEST_HOME"
  exit 1
fi
rm -rf "$SELFTEST_HOME"

echo ""
echo "Done. Built: $APP"
echo "Double-click it in Finder, or: open \"$APP\""
