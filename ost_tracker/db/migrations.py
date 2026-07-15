"""One-time data migrations.

The schema itself is idempotent (``CREATE TABLE IF NOT EXISTS`` in schema.sql),
but some changes need to *transform existing rows* once. Each such step is
recorded in ``app_settings`` under a unique key so it runs exactly once per
database, even across app restarts. ``run_pending`` is called at startup.
"""

from __future__ import annotations

from ost_tracker.config import SELF_RATING_SCORE
from ost_tracker.db import history_repo, ost_repo, rating_repo, settings_repo
from ost_tracker.db.connection import get_db
from ost_tracker.db.history_seed_data import SEED_ENTRIES
from ost_tracker.db.models import HistoryEntry
from ost_tracker.db.ost_repo import CURRENT_RANKING_LABEL

# app_settings flag marking the self-rating backfill as done.
_SELF_RATINGS_BACKFILLED = "migration_self_ratings_backfilled"
# app_settings flag marking the cover-accent backfill as done.
_COVER_ACCENTS_BACKFILLED = "migration_cover_accents_backfilled"
# app_settings flag marking the past-rankings history seed as done.
_HISTORY_SEEDED = "migration_history_seeded"
# app_settings flag marking the current-roster history backfill as done.
_HISTORY_BACKFILLED_FROM_OSTS = "migration_history_backfilled_from_osts"


def run_pending() -> None:
    """Apply any migrations that haven't run yet on this database."""
    if not settings_repo.get_bool(_SELF_RATINGS_BACKFILLED):
        backfill_self_ratings()
        settings_repo.set_bool(_SELF_RATINGS_BACKFILLED, True)
    if not settings_repo.get_bool(_COVER_ACCENTS_BACKFILLED):
        backfill_cover_accents()
        settings_repo.set_bool(_COVER_ACCENTS_BACKFILLED, True)
    if not settings_repo.get_bool(_HISTORY_SEEDED):
        seed_history_from_batches()
        settings_repo.set_bool(_HISTORY_SEEDED, True)
    if not settings_repo.get_bool(_HISTORY_BACKFILLED_FROM_OSTS):
        backfill_history_from_current_osts()
        settings_repo.set_bool(_HISTORY_BACKFILLED_FROM_OSTS, True)


def backfill_self_ratings() -> int:
    """Seed a self-rating for every existing OST whose submitter doesn't already
    have one. Safe to run repeatedly (only fills gaps). Returns how many were
    inserted, so a standalone run can report what it did."""
    added = 0
    for ost in ost_repo.list_osts():
        if rating_repo.ensure_self_rating(ost.id, ost.submitter_id):
            added += 1
    return added


def backfill_cover_accents() -> int:
    """Extract an accent for every cached cover that predates the
    ``cover_accent_hex`` column. New covers get their accent at write time
    (see ``ost_repo.set_cover``); this catches the covers already on disk.
    Returns how many accents were stored."""
    from ost_tracker.services import accent

    filled = 0
    for ost in ost_repo.list_osts():
        if not ost.cover_image_path or ost.cover_accent_hex is not None:
            continue
        accent_hex = accent.extract_accent(ost.cover_image_path)
        if accent_hex is not None:
            get_db().execute(
                "UPDATE osts SET cover_accent_hex = ? WHERE id = ?",
                (accent_hex, ost.id),
            )
            filled += 1
    return filled


def _stage(existing: list[HistoryEntry], title: str, source, batch_label, sender):
    """Append a not-yet-committed row to a bulk-insert batch, checking against
    both what's already in the DB and what's already staged this run (so
    duplicates within the batch itself are caught too), then return the
    normalized DB row tuple. Reuses ``history_repo.entry_matches`` — the
    single definition of "duplicate" — instead of a second SQL round-trip
    per candidate, which is what made startup migration slow."""
    if any(history_repo.entry_matches(e, title, source) for e in existing):
        return None
    title_norm = title.strip()
    source_norm = (source or "").strip() or None
    batch_norm = (batch_label or "").strip() or None
    sender_norm = (sender or "").strip() or None
    existing.append(
        HistoryEntry(id=-1, title=title_norm, source=source_norm, batch_label=batch_norm,
                     sender=sender_norm, created_at="")
    )
    return (title_norm, source_norm, batch_norm, sender_norm)


def seed_history_from_batches() -> int:
    """Insert every past-ranking OST recorded in ``list.md`` (batches 1-4,
    see ``scripts/generate_history_seed.py``) into ``ost_history`` in one
    bulk insert. Skips any (title, source) already present as a safety net;
    the ``run_pending`` guard flag normally makes this run exactly once.
    Returns how many rows were added."""
    existing = history_repo.list_history()
    rows = [
        row
        for entry in SEED_ENTRIES
        if (row := _stage(existing, entry["title"], entry.get("source"),
                           entry.get("batch_label"), entry.get("sender")))
        is not None
    ]
    if rows:
        get_db().executemany(
            "INSERT INTO ost_history (title, source, batch_label, sender) VALUES (?, ?, ?, ?)",
            rows,
        )
    return len(rows)


def backfill_history_from_current_osts() -> int:
    """Record every OST currently in the live roster into ``ost_history`` in
    one bulk insert so it can never be re-submitted in a future ranking.
    Skips any (title, source) already present. Returns how many rows were
    added."""
    existing = history_repo.list_history()
    rows = [
        row
        for ost in ost_repo.list_osts()
        if (row := _stage(existing, ost.title, ost.source, CURRENT_RANKING_LABEL, ost.submitter_name))
        is not None
    ]
    if rows:
        get_db().executemany(
            "INSERT INTO ost_history (title, source, batch_label, sender) VALUES (?, ?, ?, ?)",
            rows,
        )
    return len(rows)


__all__ = [
    "run_pending",
    "backfill_self_ratings",
    "backfill_cover_accents",
    "seed_history_from_batches",
    "backfill_history_from_current_osts",
    "SELF_RATING_SCORE",
]
