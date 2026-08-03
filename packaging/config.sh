# Shared packaging configuration. Sourced by every numbered script.
set -euo pipefail

PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$PACKAGING_DIR")"
RUNTIME_DIR="$PACKAGING_DIR/runtime"           # staging area, gitignored
PYTHON_DIR="$RUNTIME_DIR/python"               # unpacked python-build-standalone
PYTHON_BIN="$PYTHON_DIR/bin/python3.11"

# Pinned toolchain. Bump deliberately, never implicitly.
PBS_TAG="20260623"

# Build architecture -> python-build-standalone triplet. macOS scripts default
# to Apple Silicon; set OST_ARCH=x86_64 for an Intel build. The Windows/Linux
# clients use their own scripts (clients/*/packaging) with win/linux triplets.
OST_ARCH="${OST_ARCH:-aarch64}"
case "$OST_ARCH" in
  aarch64) PBS_TRIPLET="aarch64-apple-darwin" ;;
  x86_64)  PBS_TRIPLET="x86_64-apple-darwin" ;;
  *) echo "unknown OST_ARCH: $OST_ARCH" >&2; exit 1 ;;
esac
PBS_ASSET="cpython-3.11.15+${PBS_TAG}-${PBS_TRIPLET}-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_ASSET}"

# Backend deps bundled into the signed runtime. yt-dlp is ALSO bundled as a
# fallback, but the live copy lives in the user-writable layer (see api.py
# sys.path bootstrap) so it can be upgraded without re-signing.
BUNDLE_DEPS=(httpx pillow fastapi "uvicorn[standard]" python-multipart yt-dlp)

# Signing. Override with a real identity for release:
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./05_codesign.sh <app>
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"    # "-" = ad-hoc (local dev verification)
ENTITLEMENTS="$PACKAGING_DIR/entitlements.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-ost-notary}" # xcrun notarytool store-credentials ost-notary
