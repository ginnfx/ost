#!/usr/bin/env bash
# Dev loop. Run once (`./dev.sh`) and just edit code:
#   • Python edits (backend/, ost_tracker/) → app relaunches, NO rebuild.
#     Debug builds run the backend straight from this repo (see
#     packaging/04_copy_runtime.sh), so a relaunch picks up Python changes live.
#   • Swift edits (OSTTracker/Sources/) → incremental rebuild + relaunch.
#     Swift is compiled; there is no native hot-reload, so a recompile (a few
#     seconds, automatic) is unavoidable — this just removes every manual step.
#
# The app is always quit BEFORE building so the auto-install phase can replace
# /Applications/OSTTracker.app (it refuses to overwrite a running copy).
# Ctrl-C to stop.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/OSTTracker.app"
STAMP="$(mktemp)"

quit_app() { osascript -e 'tell application "OSTTracker" to quit' >/dev/null 2>&1 || true; sleep 0.4; }
launch()   { open "$APP"; }

build() {
    ( cd "$REPO/OSTTracker" && xcodebuild -project OSTTracker.xcodeproj -scheme OSTTracker \
        -configuration Debug -derivedDataPath build build -quiet ) 2>&1 \
        | grep -E "installed|error:|BUILD (SUCCEEDED|FAILED)" || true
}

cycle_swift() { quit_app; build; launch; }
cycle_python() { quit_app; launch; }   # repo Python is live in Debug — no build

echo "dev: initial build + launch…"
quit_app; build; launch
touch "$STAMP"
echo "dev: watching Sources + backend + ost_tracker (Ctrl-C to stop)"

while sleep 1; do
    changed="$(find "$REPO/OSTTracker/Sources" "$REPO/backend" "$REPO/ost_tracker" \
        \( -name '*.swift' -o -name '*.py' \) -newer "$STAMP" 2>/dev/null || true)"
    [[ -z "$changed" ]] && continue
    touch "$STAMP"
    if grep -q '\.swift$' <<<"$changed"; then
        echo "dev: swift changed → rebuild + relaunch"
        cycle_swift
    else
        echo "dev: python changed → relaunch (no rebuild)"
        cycle_python
    fi
done
