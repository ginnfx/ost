#!/usr/bin/env python3
"""One-off: seed a self-rating (submitter → their own OST, score 10) for every
existing OST that doesn't already have one.

The app runs this automatically at startup the first time (see
``ost_tracker.db.migrations``); this script is the manual equivalent, handy for
running against a specific database without launching the UI.

Usage:
    python scripts/backfill_self_ratings.py
    OST_TRACKER_HOME=/path/to/dir python scripts/backfill_self_ratings.py
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ost_tracker.config import database_path  # noqa: E402
from ost_tracker.db import migrations  # noqa: E402


def main() -> int:
    print(f"Database: {database_path()}")
    added = migrations.backfill_self_ratings()
    if added:
        print(f"Seeded {added} self-rating(s).")
    else:
        print("Nothing to do — every submitted OST already has a self-rating.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
