#!/usr/bin/env python3
"""Capture screenshots of every top-level screen for visual QA.

Builds the real app (so the live theme is applied), walks the sidebar, and snaps
each screen plus the whole window. Used to produce a before/after regression set
around the theme refactor.

    OST_TRACKER_HOME=/tmp/ost-home python scripts/capture_screens.py --prefix baseline

Screenshots land in ./_shots/<prefix>_<screen>.png.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ost_tracker.ui import snapshot  # noqa: E402
from ost_tracker.ui.app import build_app  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", default="shot", help="filename prefix for the set")
    ap.add_argument("--size", default="1180x800", help="window size WxH")
    args = ap.parse_args()

    w, h = (int(x) for x in args.size.lower().split("x"))

    app = build_app()  # applies the live theme
    from ost_tracker.db.connection import get_db

    get_db()
    from ost_tracker.ui.main_window import MainWindow

    win = MainWindow()
    win.resize(w, h)
    win.show()
    for _ in range(8):
        app.processEvents()

    # Whole window.
    snapshot.snap(win, f"{args.prefix}_window")

    # Each sidebar screen.
    nav = win.nav
    for row in range(nav.count()):
        label = nav.item(row).text().strip().lower().replace(" ", "-") or f"row{row}"
        nav.setCurrentRow(row)
        for _ in range(6):
            app.processEvents()
        snapshot.snap(win, f"{args.prefix}_{label}")

    print(f"[capture] wrote {nav.count() + 1} shots with prefix {args.prefix!r} to ./_shots")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
