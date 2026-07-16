"""CRUD and aggregate queries for the ``ratings`` table.

Every write path is an upsert keyed on ``(ost_id, rater_id)``. Re-entering a
score for the same pair corrects the existing row instead of erroring on the
UNIQUE constraint or creating a duplicate. Both the bulk-entry and matrix-entry
screens call :func:`upsert_rating` — there is exactly one write path.
"""

from __future__ import annotations

from typing import Optional

from ost_tracker.config import MAX_SCORE, MIN_SCORE, SELF_RATING_SCORE
from ost_tracker.db.connection import get_db
from ost_tracker.db.models import Rating


def upsert_rating(ost_id: int, rater_id: int, score: float) -> None:
    """Insert or correct a single (ost, rater) score.

    Scores are any value between MIN_SCORE and MAX_SCORE (e.g. 7, 6.7, 8.66),
    stored rounded to 2 decimals. Raises ValueError if the score is out of
    range so callers fail fast rather than tripping the CHECK constraint with
    an opaque sqlite error. Whole scores are stored as integers so pre-existing
    rows and new ones stay uniform.
    """
    if not (MIN_SCORE <= score <= MAX_SCORE):
        raise ValueError(f"Score must be between {MIN_SCORE} and {MAX_SCORE}, got {score}")
    rounded = round(float(score), 2)
    normalized = int(rounded) if rounded.is_integer() else rounded
    get_db().execute(
        """
        INSERT INTO ratings (ost_id, rater_id, score, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(ost_id, rater_id)
        DO UPDATE SET score = excluded.score, updated_at = CURRENT_TIMESTAMP
        """,
        (ost_id, rater_id, normalized),
    )


def ensure_self_rating(ost_id: int, submitter_id: Optional[int]) -> bool:
    """Seed the submitter's own rating (``SELF_RATING_SCORE``) if they have none
    yet for this OST. Idempotent and non-destructive: an existing rating for the
    pair (including one the operator has since corrected) is left untouched, so
    this is safe to call on create, on submitter change, and from the backfill.

    Returns True if a self-rating was newly inserted. Does nothing (returns
    False) when the OST has no submitter — you can't rate on nobody's behalf.
    """
    if submitter_id is None:
        return False
    if get_score(ost_id, submitter_id) is not None:
        return False
    upsert_rating(ost_id, submitter_id, SELF_RATING_SCORE)
    return True


def delete_rating(ost_id: int, rater_id: int) -> None:
    """Clear a single score (e.g. an entry cell was emptied)."""
    get_db().execute(
        "DELETE FROM ratings WHERE ost_id = ? AND rater_id = ?", (ost_id, rater_id)
    )


def get_score(ost_id: int, rater_id: int) -> Optional[float]:
    val = get_db().scalar(
        "SELECT score FROM ratings WHERE ost_id = ? AND rater_id = ?",
        (ost_id, rater_id),
    )
    return float(val) if val is not None else None


def ratings_for_ost(ost_id: int) -> list[Rating]:
    rows = get_db().query(
        """
        SELECT r.ost_id, r.rater_id, p.name AS rater_name, r.score, r.updated_at
        FROM ratings r
        JOIN people p ON p.id = r.rater_id
        WHERE r.ost_id = ?
        ORDER BY p.name COLLATE NOCASE
        """,
        (ost_id,),
    )
    return [
        Rating(
            ost_id=row["ost_id"],
            rater_id=row["rater_id"],
            rater_name=row["rater_name"],
            score=row["score"],
            updated_at=row["updated_at"],
        )
        for row in rows
    ]


def scores_for_ost(ost_id: int) -> list[float]:
    rows = get_db().query("SELECT score FROM ratings WHERE ost_id = ?", (ost_id,))
    return [r["score"] for r in rows]


def rated_ost_ids_for_rater(rater_id: int) -> set[int]:
    rows = get_db().query("SELECT ost_id FROM ratings WHERE rater_id = ?", (rater_id,))
    return {r["ost_id"] for r in rows}


def scores_by_rater(rater_id: int) -> list[float]:
    rows = get_db().query("SELECT score FROM ratings WHERE rater_id = ?", (rater_id,))
    return [r["score"] for r in rows]


def total_ratings() -> int:
    return int(get_db().scalar("SELECT COUNT(*) FROM ratings") or 0)


def completion_pairs() -> set[tuple[int, int]]:
    """Every (ost_id, rater_id) pair that currently has a score. Used by the
    completion overview heatmap and the locked-reveal condition."""
    rows = get_db().query("SELECT ost_id, rater_id FROM ratings")
    return {(r["ost_id"], r["rater_id"]) for r in rows}
