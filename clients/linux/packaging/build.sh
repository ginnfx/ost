#!/usr/bin/env bash
# Stage the Linux client + embedded python-build-standalone runtime into a
# portable bundle, mirroring the macOS packaging scripts.
# Usage: ./build.sh [x86_64|aarch64]   (default: host arch)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT_DIR="$(dirname "$HERE")"          # clients/linux
REPO_ROOT="$(dirname "$(dirname "$HERE")")"
ARCH="${1:-$(uname -m)}"
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
echo "AppImage/.deb/.rpm packaging: wrap this bundle with linuxdeploy or"
echo "fpm (out of scope of this script) — the bundle is plain and portable."
