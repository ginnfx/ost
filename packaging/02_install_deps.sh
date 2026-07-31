#!/bin/bash
# Install the backend deps directly into the standalone runtime's
# site-packages. python-build-standalone is fully relative internally, so the
# populated tree is relocatable into Contents/Resources as-is — no venv, no
# pyvenv.cfg with baked absolute paths.
source "$(dirname "$0")/config.sh"

[[ -x "$PYTHON_BIN" ]] || { echo "run 01_fetch_runtime.sh first" >&2; exit 1; }

"$RUNTIME_DIR/uv" pip install --python "$PYTHON_BIN" --upgrade "${BUNDLE_DEPS[@]}"

"$PYTHON_BIN" - <<'EOF'
import fastapi, httpx, PIL, uvicorn, yt_dlp
print("bundled deps import OK:",
      "fastapi", fastapi.__version__, "| yt-dlp", yt_dlp.version.__version__)
EOF
