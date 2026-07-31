#!/bin/bash
# Xcode Run Script build phase: copy the staged Python runtime plus the
# unchanged Python backend into the built app's Contents/Resources.
# Skips (successfully) when the runtime is not staged so plain dev builds
# that run against the repo venv keep working.
source "$(dirname "$0")/config.sh"

APP_RES="${BUILT_PRODUCTS_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

# Debug = live dev loop: DON'T embed. The sidecar's development() config then
# runs the backend straight from the repo checkout, so Python edits are live on
# the next launch with no rebuild. Strip any runtime a prior Release build left
# in this bundle so packaged() reliably returns nil in Debug.
if [[ "${CONFIGURATION:-}" == "Debug" ]]; then
    echo "Debug build: running backend from repo (no embed); stripping any stale runtime"
    rm -rf "$APP_RES/python-runtime" "$APP_RES/bin/uv" "$APP_RES/backend" "$APP_RES/ost_tracker"
    exit 0
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "packaging runtime not staged; skipping embed (dev build)"
    exit 0
fi

echo "embedding python runtime + backend into $APP_RES"
mkdir -p "$APP_RES/bin"
rsync -a --delete "$PYTHON_DIR/" "$APP_RES/python-runtime/"
rsync -a "$RUNTIME_DIR/uv" "$APP_RES/bin/uv"
rsync -a --delete --exclude "__pycache__" "$REPO_ROOT/backend/" "$APP_RES/backend/"
rsync -a --delete --exclude "__pycache__" "$REPO_ROOT/ost_tracker/" "$APP_RES/ost_tracker/"
