#!/usr/bin/env python3
"""Populate a database with demo data for manual/visual testing.

    python scripts/dev_seed.py                 # 12 OSTs, all fully rated
    python scripts/dev_seed.py --osts 50       # full competition size
    python scripts/dev_seed.py --partial       # leave gaps (locked-reveal state)
    python scripts/dev_seed.py --covers        # also fetch real cover art (slow, online)

Point it at a scratch DB so it never touches real data:
    OST_TRACKER_HOME=/tmp/ost-demo python scripts/dev_seed.py
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ost_tracker.db import ost_repo, people_repo, rating_repo  # noqa: E402

SAMPLE = [
    ("Aerith's Theme", "Final Fantasy VII"),
    ("Snake Eater", "Metal Gear Solid 3"),
    ("Megalovania", "Undertale"),
    ("Corridors of Time", "Chrono Trigger"),
    ("One-Winged Angel", "Final Fantasy VII"),
    ("Baba Yetu", "Civilization IV"),
    ("Rules of Nature", "Metal Gear Rising"),
    ("Lifelight", "Super Smash Bros. Ultimate"),
    ("Battle Theme", "Pokemon Red/Blue"),
    ("City Ruins", "NieR: Automata"),
    ("The Moon", "DuckTales"),
    ("Green Greens", "Kirby's Dream Land"),
    ("Dearly Beloved", "Kingdom Hearts"),
    ("Gerudo Valley", "The Legend of Zelda: Ocarina of Time"),
    ("Time's Scar", "Chrono Cross"),
    ("Still Alive", "Portal"),
    ("Ken's Theme", "Street Fighter II"),
    ("Frog's Theme", "Chrono Trigger"),
    ("Vampire Killer", "Castlevania"),
    ("His World", "Sonic the Hedgehog"),
]


def _pseudo_score(o_idx: int, r_idx: int) -> int:
    # Deterministic, varied scores in 0..10. Some OSTs are broadly liked, some
    # divisive — enough spread to make the stats interesting.
    base = (o_idx * 3 + r_idx * 7) % 11
    swing = (o_idx * r_idx) % 4 - 2
    return max(0, min(10, base + swing))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--osts", type=int, default=12)
    parser.add_argument("--partial", action="store_true", help="leave some cells unrated")
    parser.add_argument("--covers", action="store_true", help="fetch real cover art (online)")
    args = parser.parse_args()

    names = ["Alice", "Bob", "Cara", "Dan", "Evan", "Faye", "Gwen", "Hugo", "Iris", "Jack"]
    people = []
    for n in names:
        existing = next((p for p in people_repo.list_people() if p.name == n), None)
        people.append(existing or people_repo.add_person(n))

    count = min(args.osts, len(SAMPLE)) if args.osts <= len(SAMPLE) else args.osts
    for i in range(count):
        title, source = SAMPLE[i % len(SAMPLE)]
        if args.osts > len(SAMPLE):
            title = f"{title} #{i // len(SAMPLE) + 1}"
        submitter = people[i % len(people)]
        ost_id = ost_repo.add_ost(title, source, submitter.id)

        for r_idx, rater in enumerate(people):
            if args.partial and (i + r_idx) % 5 == 0:
                continue  # leave a gap
            rating_repo.upsert_rating(ost_id, rater.id, _pseudo_score(i, r_idx))

        if args.covers:
            from ost_tracker.services import coverart

            res = coverart.fetch_cover(ost_id, title, source)
            if res.found:
                ost_repo.set_cover(ost_id, str(res.path))

    print(f"Seeded {count} OSTs, {people_repo.count_people()} people, "
          f"{rating_repo.total_ratings()} ratings"
          f"{' (partial)' if args.partial else ''}.")


if __name__ == "__main__":
    main()
