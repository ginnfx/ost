"""CRUD and leaderboard queries for the ``osts`` table."""

from __future__ import annotations

import sqlite3
from typing import Optional

from ost_tracker.db import history_repo, people_repo, rating_repo
from ost_tracker.db.connection import get_db
from ost_tracker.db.models import Ost, OstStats
from ost_tracker.services import accent, statistics

# batch_label used for every OST recorded into history via the live app,
# whether backfilled from an existing roster or auto-added on creation.
CURRENT_RANKING_LABEL = "Current Ranking"

_SELECT_OST = """
    SELECT o.id, o.title, o.source, o.submitter_id, p.name AS submitter_name,
           o.cover_image_path, o.cover_accent_hex, o.external_link, o.created_at
    FROM osts o
    LEFT JOIN people p ON p.id = o.submitter_id
"""


def _row_to_ost(row: sqlite3.Row) -> Ost:
    return Ost(
        id=row["id"],
        title=row["title"],
        source=row["source"],
        submitter_id=row["submitter_id"],
        submitter_name=row["submitter_name"],
        cover_image_path=row["cover_image_path"],
        cover_accent_hex=row["cover_accent_hex"],
        external_link=row["external_link"],
        created_at=row["created_at"],
    )


def list_osts() -> list[Ost]:
    rows = get_db().query(_SELECT_OST + " ORDER BY o.created_at DESC, o.id DESC")
    return [_row_to_ost(r) for r in rows]


def get_ost(ost_id: int) -> Optional[Ost]:
    row = get_db().query_one(_SELECT_OST + " WHERE o.id = ?", (ost_id,))
    return _row_to_ost(row) if row else None


def add_ost(
    title: str,
    source: Optional[str] = None,
    submitter_id: Optional[int] = None,
    external_link: Optional[str] = None,
) -> int:
    title = (title or "").strip()
    if not title:
        raise ValueError("OST title cannot be empty")
    source_norm = (source or "").strip() or None
    matches = history_repo.find_matches(title, source_norm)
    if matches:
        match = matches[0]
        detail = match.batch_label or "a past ranking"
        if match.sender:
            detail += f" (submitted by {match.sender})"
        if not source_norm and match.source:
            detail += " — set the Source field if this is a different track"
        raise ValueError(f'"{title}" was already used before, in {detail}.')
    ost_id = get_db().execute(
        """
        INSERT INTO osts (title, source, submitter_id, external_link)
        VALUES (?, ?, ?, ?)
        """,
        (title, source_norm, submitter_id, (external_link or "").strip() or None),
    )
    # A submitter automatically rates their own pick (see ensure_self_rating).
    rating_repo.ensure_self_rating(ost_id, submitter_id)
    # Every unique OST self-records into history so it's never re-submittable.
    person = people_repo.get_person(submitter_id) if submitter_id is not None else None
    history_repo.add_entry(
        title, source_norm, batch_label=CURRENT_RANKING_LABEL, sender=person.name if person else None
    )
    return ost_id


def update_ost(
    ost_id: int,
    *,
    title: str,
    source: Optional[str],
    submitter_id: Optional[int],
    external_link: Optional[str],
) -> None:
    title = (title or "").strip()
    if not title:
        raise ValueError("OST title cannot be empty")
    source_norm = (source or "").strip() or None
    current = get_ost(ost_id)
    get_db().execute(
        """
        UPDATE osts
        SET title = ?, source = ?, submitter_id = ?, external_link = ?
        WHERE id = ?
        """,
        (title, source_norm, submitter_id,
         (external_link or "").strip() or None, ost_id),
    )
    # If the submitter changed to someone with no rating yet, seed theirs too.
    # A previous submitter's seeded 10 is left as a normal rating they gave.
    rating_repo.ensure_self_rating(ost_id, submitter_id)
    _sync_history_entry(current, title, source_norm, submitter_id)


def _sync_history_entry(
    previous: Optional[Ost], title: str, source: Optional[str], submitter_id: Optional[int]
) -> None:
    """Keep the OST's own "Current Ranking" history row in step with a rename
    so the old title becomes re-submittable and the new one is protected.
    Only this OST's own row is touched — never a past-batch record. If the
    OST predates this feature (or its row was hand-deleted), this is a no-op;
    we don't resurrect deleted rows or guess which entry is "this one" when
    none matches."""
    if previous is None:
        return
    candidates = [
        e
        for e in history_repo.find_matches(previous.title, previous.source)
        if e.batch_label == CURRENT_RANKING_LABEL
    ]
    if not candidates:
        return
    exact = [
        e
        for e in candidates
        if (e.title or "").strip().lower() == (previous.title or "").strip().lower()
        and (e.source or None) == (previous.source or None)
    ]
    entry = exact[0] if exact else candidates[0]
    person = people_repo.get_person(submitter_id) if submitter_id is not None else None
    history_repo.update_entry(
        entry.id, title, source, batch_label=CURRENT_RANKING_LABEL, sender=person.name if person else None
    )


def set_cover(ost_id: int, cover_image_path: Optional[str]) -> None:
    """Set (or clear) the cached cover and its derived accent colour together,
    so the accent can never go stale against a changed cover."""
    accent_hex = accent.extract_accent(cover_image_path) if cover_image_path else None
    get_db().execute(
        "UPDATE osts SET cover_image_path = ?, cover_accent_hex = ? WHERE id = ?",
        (cover_image_path, accent_hex, ost_id),
    )


def delete_ost(ost_id: int) -> None:
    """Delete an OST. Its ratings cascade away via the foreign key."""
    get_db().execute("DELETE FROM osts WHERE id = ?", (ost_id,))


def get_playback_watch_url(ost_id: int) -> Optional[str]:
    """The cached resolved playback page (YouTube watch URL) for this OST, if
    a previous resolution stored one. See services/link_resolver.py."""
    url = get_db().scalar("SELECT playback_watch_url FROM osts WHERE id = ?", (ost_id,))
    return url or None


def set_playback_watch_url(ost_id: int, url: Optional[str]) -> None:
    """Cache (or clear, with None — the manual re-search action) the resolved
    playback page for this OST so playback doesn't re-search every open."""
    get_db().execute(
        "UPDATE osts SET playback_watch_url = ? WHERE id = ?", (url, ost_id)
    )


def list_sources() -> list[str]:
    """Distinct non-empty source/franchise values, for autocomplete."""
    rows = get_db().query(
        """
        SELECT DISTINCT source FROM osts
        WHERE source IS NOT NULL AND TRIM(source) <> ''
        ORDER BY source COLLATE NOCASE
        """
    )
    return [r["source"] for r in rows]


def count_osts() -> int:
    return int(get_db().scalar("SELECT COUNT(*) FROM osts") or 0)


def osts_by_submitter(submitter_id: int) -> list[Ost]:
    rows = get_db().query(
        _SELECT_OST + " WHERE o.submitter_id = ? ORDER BY o.title COLLATE NOCASE",
        (submitter_id,),
    )
    return [_row_to_ost(r) for r in rows]


def list_osts_with_stats() -> list[OstStats]:
    """Return every OST joined with its aggregate rating stats and leaderboard
    rank. Rank is 1-based over average descending; OSTs with no ratings are
    unranked (``rank`` is None) and carry a ``None`` average.

    Aggregation is done in one grouped query for avg/min/max/count; stddev is
    computed in Python (SQLite has no built-in stddev) from a single fetch of
    all scores, keeping this to two queries regardless of OST count.
    """
    osts = {o.id: o for o in list_osts()}

    agg_rows = get_db().query(
        """
        SELECT ost_id,
               COUNT(*)  AS n,
               AVG(score) AS avg_score,
               MIN(score) AS min_score,
               MAX(score) AS max_score
        FROM ratings
        GROUP BY ost_id
        """
    )
    agg = {r["ost_id"]: r for r in agg_rows}

    score_rows = get_db().query("SELECT ost_id, score FROM ratings")
    scores_by_ost: dict[int, list[int]] = {}
    for r in score_rows:
        scores_by_ost.setdefault(r["ost_id"], []).append(r["score"])

    results: list[OstStats] = []
    for ost in osts.values():
        a = agg.get(ost.id)
        if a is None:
            results.append(
                OstStats(ost=ost, rating_count=0, average=None,
                         minimum=None, maximum=None, stddev=None, rank=None)
            )
            continue
        scores = scores_by_ost.get(ost.id, [])
        results.append(
            OstStats(
                ost=ost,
                rating_count=a["n"],
                average=a["avg_score"],
                minimum=a["min_score"],
                maximum=a["max_score"],
                stddev=statistics.population_stddev(scores),
                rank=None,  # assigned below
            )
        )

    # Tiebreaker: when two OSTs share the same average, the one whose submitter
    # scored higher on average across their own submissions ranks first. This is
    # computed only from the ratings that actually exist (mean of each
    # submitter's rated-OST averages), so partial/incomplete data never breaks
    # it — a submitter with nothing rated simply sorts last among ties, and the
    # final fallback is the title for full determinism.
    own_scores: dict[int, list[float]] = {}
    for s in results:
        if s.ost.submitter_id is not None and s.average is not None:
            own_scores.setdefault(s.ost.submitter_id, []).append(s.average)
    submitter_own_avg = {
        sid: sum(vals) / len(vals) for sid, vals in own_scores.items()
    }

    def _own_avg(s: OstStats) -> float:
        sid = s.ost.submitter_id
        if sid is None:
            return float("-inf")
        return submitter_own_avg.get(sid, float("-inf"))

    # Assign ranks over rated OSTs: average desc, then submitter's own-average
    # desc, then title asc.
    rated = [s for s in results if s.average is not None]
    rated.sort(key=lambda s: (-s.average, -_own_avg(s), s.ost.title.lower()))
    rank_by_id = {s.ost.id: i + 1 for i, s in enumerate(rated)}

    return [
        OstStats(
            ost=s.ost,
            rating_count=s.rating_count,
            average=s.average,
            minimum=s.minimum,
            maximum=s.maximum,
            stddev=s.stddev,
            rank=rank_by_id.get(s.ost.id),
        )
        for s in results
    ]


def get_ost_stats(ost_id: int) -> Optional[OstStats]:
    for s in list_osts_with_stats():
        if s.ost.id == ost_id:
            return s
    return None
