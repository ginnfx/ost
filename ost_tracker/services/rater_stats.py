"""Per-rater statistics — the "leniency" indicator (average score a person
gives across all their ratings)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from ost_tracker.db.connection import get_db


@dataclass(frozen=True)
class RaterStat:
    person_id: int
    name: str
    rating_count: int
    average_given: Optional[float]


def rater_leniency() -> list[RaterStat]:
    """Every person with the average score they hand out, most lenient first.

    People who have rated nothing appear last with a ``None`` average.
    """
    rows = get_db().query(
        """
        SELECT p.id, p.name, COUNT(r.id) AS n, AVG(r.score) AS avg_given
        FROM people p
        LEFT JOIN ratings r ON r.rater_id = p.id
        GROUP BY p.id
        ORDER BY (avg_given IS NULL), avg_given DESC, p.name COLLATE NOCASE
        """
    )
    return [
        RaterStat(
            person_id=r["id"],
            name=r["name"],
            rating_count=r["n"],
            average_given=r["avg_given"],
        )
        for r in rows
    ]
