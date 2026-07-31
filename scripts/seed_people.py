#!/usr/bin/env python3
"""One-time setup: seed the ``people`` table with the 10 competitors.

Run once after first launch (or any time — it's idempotent, skipping names that
already exist). Names are editable later from the in-app Settings screen (⌘,).

    python scripts/seed_people.py                 # use the default 10 names
    python scripts/seed_people.py Alice Bob Cara   # provide your own names
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ost_tracker.db import people_repo  # noqa: E402

DEFAULT_NAMES = [
    "Alice", "Bob", "Cara", "Dan", "Evan",
    "Faye", "Gwen", "Hugo", "Iris", "Jack",
]


def seed(names: list[str]) -> None:
    existing = {p.name.lower() for p in people_repo.list_people()}
    added = 0
    for name in names:
        if name.lower() in existing:
            print(f"  skip  {name} (already exists)")
            continue
        people_repo.add_person(name)
        existing.add(name.lower())
        added += 1
        print(f"  add   {name}")
    print(f"\nDone. {added} added, {len(names) - added} skipped. "
          f"Total people: {people_repo.count_people()}.")


if __name__ == "__main__":
    seed(sys.argv[1:] or DEFAULT_NAMES)
