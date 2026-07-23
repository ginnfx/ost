"""PyInstaller entry point. Kept at the project root so the spec has a simple
script target. Delegates to the app bootstrap."""

from __future__ import annotations

import sys

from ost_tracker.ui.app import run

if __name__ == "__main__":
    sys.exit(run())
