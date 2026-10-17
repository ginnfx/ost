#!/usr/bin/env bash
# Stage the Linux client + embedded python-build-standalone runtime into a
# portable bundle (or an AppImage, with --appimage), mirroring the macOS
# packaging scripts. .deb/.rpm remain an fpm follow-up.
# Usage: ./build.sh [x86_64|aarch64] [--appimage]   (default: host arch)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="$(dirname "$HERE")"                 # clients/linux
REPO_ROOT="$(dirname "$(dirname "$(dirname "$HERE")")")"   # repo root
ARGS=()
WANT_APPIMAGE=0
for arg in "$@"; do
  case "$arg" in
    --appimage) WANT_APPIMAGE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
ARCH="${ARGS[0]:-$(uname -m)}"
OUT="$CLIENT_DIR/out/app-$ARCH"
RUNTIME_DIR="$CLIENT_DIR/runtime"

mkdir -p "$OUT" "$RUNTIME_DIR"

# 1) python-build-standalone runtime (same pinned release as macOS packaging).
TAG="20260623"
case "$ARCH" in
  x86_64|amd64) TRIPLET="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64) TRIPLET="aarch64-unknown-linux-gnu" ;;
  *) echo "unsupported arch: $ARCH"; exit 1 ;;
esac
ASSET="cpython-3.11.15+${TAG}-${TRIPLET}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${TAG}/${ASSET}"
ARCHIVE="$RUNTIME_DIR/$ASSET"

if [ ! -f "$ARCHIVE" ]; then
  echo "fetching $ASSET"
  curl -L -o "$ARCHIVE" "$URL"
fi

rm -rf "$OUT/python-runtime"
mkdir -p "$OUT/python-runtime"
tar -xzf "$ARCHIVE" -C "$OUT/python-runtime" --strip-components=1

# 2) Python deps into the runtime (httpx, websockets; PyGObject must match the
#    system GTK — install system python3-gi on target instead).
"$OUT/python-runtime/bin/python3.11" -m pip install -q --no-warn-script-location \
  -r "$CLIENT_DIR/requirements.txt" \
  fastapi "uvicorn[standard]" httpx Pillow yt-dlp

# 3) Sidecar (backend + domain) next to the runtime.
rm -rf "$OUT/backend" "$OUT/ost_tracker"
cp -R "$REPO_ROOT/backend" "$OUT/backend"
cp -R "$REPO_ROOT/ost_tracker" "$OUT/ost_tracker"

# 4) The client itself + launcher.
rm -rf "$OUT/ost_tracker_gtk" "$OUT/main.py"
cp -R "$CLIENT_DIR/ost_tracker_gtk" "$OUT/ost_tracker_gtk"
cp "$CLIENT_DIR/main.py" "$OUT/main.py"

cat > "$OUT/OSTTracker" <<EOF
#!/usr/bin/env bash
exec "\$(dirname "\$0")/python-runtime/bin/python3.11" "\$(dirname "\$0")/main.py"
EOF
chmod +x "$OUT/OSTTracker"

echo "bundle ready at $OUT (run ./OSTTracker)"

if [ "$WANT_APPIMAGE" -ne 1 ]; then
  echo "add --appimage to also build an AppImage"
  exit 0
fi

# 5) Optional AppImage wrap: appimagetool (per-arch build) packs the bundle
#    with a .desktop + icon so the app shows up in launchers too. The tool is
#    downloaded to the runtime dir and run with --appimage-extract-and-run so
#    CI/containers without FUSE still work.
case "$TRIPLET" in
  x86_64-unknown-linux-gnu) APPIMAGE_TOOL="appimagetool-x86_64.AppImage" ;;
  aarch64-unknown-linux-gnu) APPIMAGE_TOOL="appimagetool-aarch64.AppImage" ;;
esac
TOOL_PATH="$RUNTIME_DIR/$APPIMAGE_TOOL"
if [ ! -f "$TOOL_PATH" ]; then
  TOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/${APPIMAGE_TOOL}"
  echo "fetching $APPIMAGE_TOOL"
  # --fail so a 404 error page never lands on disk pretending to be the tool
  curl --fail -L -o "$TOOL_PATH" "$TOOL_URL"
fi
chmod +x "$TOOL_PATH"

APPDIR="$CLIENT_DIR/out/OSTTracker.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps" "$APPDIR/usr/bin"
cp -R "$OUT" "$APPDIR/usr/bin/app"

cat > "$APPDIR/usr/share/applications/ost-tracker.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OST Tracker
Comment=Rate game soundtracks with friends
Exec=OSTTracker
Icon=ost-tracker
Categories=Audio;AudioVideo;
EOF

# appimagetool puts $APPDIR/usr/bin on PATH, so expose the bundle's launcher
# there for the desktop Exec above.
ln -sf app/OSTTracker "$APPDIR/usr/bin/OSTTracker"

if [ -f "$REPO_ROOT/assets/icon.png" ]; then
  # appimagetool validation looks in the AppDir root; launchers look in
  # hicolor — provide both.
  cp "$REPO_ROOT/assets/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/ost-tracker.png"
  cp "$REPO_ROOT/assets/icon.png" "$APPDIR/ost-tracker.png"
else
  echo "warning: no assets/icon.png found — AppImage will fail validation or use a default icon"
fi
cp "$APPDIR/usr/share/applications/ost-tracker.desktop" "$APPDIR/ost-tracker.desktop"

APPIMAGE="$CLIENT_DIR/out/OSTTracker-linux-${ARCH}.AppImage"
"$TOOL_PATH" --appimage-extract-and-run "$APPDIR" "$APPIMAGE"
echo "appimage ready at $APPIMAGE"
