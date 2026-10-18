#!/usr/bin/env bash
# Stage the Linux client + embedded python-build-standalone runtime into a
# portable bundle, AppImage, or Debian package.
# Usage: ./build.sh [x86_64|aarch64] [--appimage] [--deb]   (default: host arch)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="$(dirname "$HERE")"                 # clients/linux
REPO_ROOT="$(dirname "$(dirname "$(dirname "$HERE")")")"   # repo root
ARGS=()
WANT_APPIMAGE=0
WANT_DEB=0
for arg in "$@"; do
  case "$arg" in
    --appimage) WANT_APPIMAGE=1 ;;
    --deb) WANT_DEB=1 ;;
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
  x86_64|amd64) TRIPLET="x86_64-unknown-linux-gnu"; DEB_ARCH="amd64" ;;
  aarch64|arm64) TRIPLET="aarch64-unknown-linux-gnu"; DEB_ARCH="arm64" ;;
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

# 2) Bundle the backend dependencies plus Linux websocket support. GTK and
#    PyGObject use the matching system packages.
"$OUT/python-runtime/bin/python3.11" -m pip install -q --no-warn-script-location \
  -r "$REPO_ROOT/requirements.txt" \
  -r "$CLIENT_DIR/requirements.txt"

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
# GTK's PyGObject bindings must match the distribution's GTK installation.
# Keep system Python for the UI and the embedded runtime for the sidecar.
if ! python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Gst", "1.0"); from gi.repository import Gtk, Gst' >/dev/null 2>&1; then
  cat >&2 <<'MSG'
OST Tracker needs the system GTK4 and GStreamer Python bindings.
On Debian or Ubuntu, install them with:
  sudo apt install python3 python3-gi gir1.2-gtk-4.0 gir1.2-gstreamer-1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good
MSG
  exit 1
fi
APP_DIR="\$(cd -- "\$(dirname -- "\$(readlink -f -- "\$0")")" && pwd)"
exec python3 "\$APP_DIR/main.py" "\$@"
EOF
chmod +x "$OUT/OSTTracker"

echo "bundle ready at $OUT (run ./OSTTracker)"

if [ "$WANT_DEB" -eq 1 ]; then
  DEB_ROOT="$CLIENT_DIR/out/deb-$ARCH"
  DEB_PACKAGE="$CLIENT_DIR/out/OSTTracker-linux-${ARCH}.deb"
  rm -rf "$DEB_ROOT"
  mkdir -p "$DEB_ROOT/DEBIAN" "$DEB_ROOT/opt/ost-tracker" \
    "$DEB_ROOT/usr/bin" "$DEB_ROOT/usr/share/applications"
  cp -R "$OUT"/. "$DEB_ROOT/opt/ost-tracker/"

  cat > "$DEB_ROOT/usr/bin/ost-tracker" <<'EOF'
#!/bin/sh
exec /opt/ost-tracker/OSTTracker "$@"
EOF
  chmod +x "$DEB_ROOT/usr/bin/ost-tracker"

  cat > "$DEB_ROOT/usr/share/applications/ost-tracker.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=OST Tracker
Comment=Rate game soundtracks with friends
Exec=ost-tracker
Icon=ost-tracker
Categories=Audio;AudioVideo;
EOF

  if [ -f "$REPO_ROOT/assets/icon.png" ]; then
    mkdir -p "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"
    cp "$REPO_ROOT/assets/icon.png" \
      "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/ost-tracker.png"
  fi

  VERSION="${OST_TRACKER_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always 2>/dev/null || true)}"
  VERSION="${VERSION:-0.0.0}"
  VERSION="${VERSION#v}"
  cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: ost-tracker
Version: $VERSION
Section: sound
Priority: optional
Architecture: $DEB_ARCH
Depends: python3, python3-gi, gir1.2-gtk-4.0, gir1.2-gstreamer-1.0, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good
Maintainer: OST Tracker maintainers <noreply@github.com>
Description: Desktop app for rating game soundtracks with friends
EOF

  dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_PACKAGE"
  echo "Debian package ready at $DEB_PACKAGE"
fi

if [ "$WANT_APPIMAGE" -ne 1 ]; then
  if [ "$WANT_DEB" -ne 1 ]; then
    echo "add --appimage and/or --deb to build a distributable package"
  fi
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

# AppImage requires an executable entry point at the AppDir root. Some
# appimagetool versions do not synthesize this from the desktop Exec field.
cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/OSTTracker" "$@"
EOF
chmod +x "$APPDIR/AppRun"

APPIMAGE="$CLIENT_DIR/out/OSTTracker-linux-${ARCH}.AppImage"
"$TOOL_PATH" --appimage-extract-and-run "$APPDIR" "$APPIMAGE"

# Inspect the finished image on its native-architecture runner so a broken
# AppDir cannot be attached to a release unnoticed.
VERIFY_DIR="$CLIENT_DIR/out/verify-appimage-$ARCH"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
(cd "$VERIFY_DIR" && "$APPIMAGE" --appimage-extract >/dev/null)
test -x "$VERIFY_DIR/squashfs-root/AppRun"
test -x "$VERIFY_DIR/squashfs-root/usr/bin/OSTTracker"
test -f "$VERIFY_DIR/squashfs-root/usr/bin/app/python-runtime/bin/python3.11"
rm -rf "$VERIFY_DIR"
echo "appimage ready at $APPIMAGE"
