#!/bin/bash
# Fetch and unpack the pinned python-build-standalone CPython (arm64) plus a
# standalone uv binary (used at first run to update yt-dlp in the writable
# layer). Idempotent: skips anything already staged.
source "$(dirname "$0")/config.sh"

mkdir -p "$RUNTIME_DIR"

if [[ -x "$PYTHON_BIN" ]]; then
    echo "python runtime already staged: $("$PYTHON_BIN" --version)"
else
    echo "fetching $PBS_ASSET"
    curl -fsSL "$PBS_URL" -o "$RUNTIME_DIR/$PBS_ASSET"
    tar -xzf "$RUNTIME_DIR/$PBS_ASSET" -C "$RUNTIME_DIR"
    rm "$RUNTIME_DIR/$PBS_ASSET"
    [[ -x "$PYTHON_BIN" ]] || { echo "ERROR: $PYTHON_BIN missing after unpack" >&2; exit 1; }
    echo "staged $("$PYTHON_BIN" --version)"
fi

if [[ -x "$RUNTIME_DIR/uv" ]]; then
    echo "uv already staged: $("$RUNTIME_DIR/uv" --version)"
else
    echo "fetching uv (aarch64-apple-darwin)"
    curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz" \
        | tar -xzf - -C "$RUNTIME_DIR" --strip-components=1 uv-aarch64-apple-darwin/uv
    echo "staged uv $("$RUNTIME_DIR/uv" --version)"
fi
