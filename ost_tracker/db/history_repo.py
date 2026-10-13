"""CRUD and match lookup for the ``ost_history`` exclusion list.

This table records OSTs used in every past or current competition. It is
reference data, completely separate from the current competition's rating
math: it never joins to ``ratings`` and nothing here feeds rankings/stats/
exports. Its job is to let the Add OST flow reject a title that has been
used before.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

from ost_tracker.db.connection import get_db
from ost_tracker.db.models import HistoryEntry

_SELECT_ENTRY = "SELECT id, title, source, batch_label, sender, created_at FROM ost_history"


def _row_to_entry(row: sqlite3.Row) -> HistoryEntry:
    return HistoryEntry(
        id=row["id"],
        title=row["title"],
        source=row["source"],
        batch_label=row["batch_label"],
        sender=row["sender"],
        created_at=row["created_at"],
    )


def list_history() -> list[HistoryEntry]:
    rows = get_db().query(f"{_SELECT_ENTRY} ORDER BY title COLLATE NOCASE")
    return [_row_to_entry(r) for r in rows]


def get_entry(entry_id: int) -> Optional[HistoryEntry]:
    row = get_db().query_one(f"{_SELECT_ENTRY} WHERE id = ?", (entry_id,))
    return _row_to_entry(row) if row else None


def add_entry(
    title: str,
    source: Optional[str] = None,
    batch_label: Optional[str] = None,
    sender: Optional[str] = None,
) -> HistoryEntry:
    title = (title or "").strip()
    if not title:
        raise ValueError("History entry title cannot be empty")
    new_id = get_db().execute(
        "INSERT INTO ost_history (title, source, batch_label, sender) VALUES (?, ?, ?, ?)",
        (
            title,
            (source or "").strip() or None,
            (batch_label or "").strip() or None,
            (sender or "").strip() or None,
        ),
    )
    created = get_entry(new_id)
    if created is None:
        raise RuntimeError(f"history entry {new_id} missing after insert")
    return created


def update_entry(
    entry_id: int,
    title: str,
    source: Optional[str],
    batch_label: Optional[str] = None,
    sender: Optional[str] = None,
) -> None:
    title = (title or "").strip()
    if not title:
        raise ValueError("History entry title cannot be empty")
    get_db().execute(
        "UPDATE ost_history SET title = ?, source = ?, batch_label = ?, sender = ? WHERE id = ?",
        (
            title,
            (source or "").strip() or None,
            (batch_label or "").strip() or None,
            (sender or "").strip() or None,
            entry_id,
        ),
    )


def delete_entry(entry_id: int) -> None:
    get_db().execute("DELETE FROM ost_history WHERE id = ?", (entry_id,))


def count_history() -> int:
    return int(get_db().scalar("SELECT COUNT(*) FROM ost_history") or 0)


def import_competition_history(source_id: str, name: str, entries: list[dict]) -> dict:
    """Import a finished competition into the deduplicated local OST history."""
    from ost_tracker.db.connection import get_db

    label = (name or "").strip()
    if not source_id or not label or len(label) > 120:
        raise ValueError("Competition history needs an id and a name.")
    db = get_db()
    with db.transaction() as conn:
        inserted = conn.execute(
            "INSERT INTO imported_competitions(source_id,name) VALUES (?,?) ON CONFLICT(source_id) DO NOTHING",
            (source_id, label),
        ).rowcount
        if not inserted:
            return {"imported": False, "added": 0}
        existing = list_history()
        existing_index: dict = {}
        for entry in existing:
            existing_index.setdefault(_norm(entry.title), []).append(entry)
        added = 0
        for item in entries:
            title = (item.get("title") or "").strip()
            source = (item.get("source") or "").strip() or None
            if not title:
                continue
            if any(entry_matches(match, title, source) for match in existing_index.get(_norm(title), ())):
                continue
            conn.execute(
                "INSERT INTO ost_history(title,source,batch_label,sender) VALUES (?,?,?,?)",
                (title, source, label, "OST Competition"),
            )
            added += 1
            existing_index.setdefault(_norm(title), []).append(
                HistoryEntry(id=-added, title=title, source=source, batch_label=label, sender="OST Competition", created_at="")
            )
        return {"imported": True, "added": added}


def _norm(value: Optional[str]) -> str:
    return (value or "").strip().lower()


def entry_matches(entry: HistoryEntry, title: str, source: Optional[str]) -> bool:
    """A duplicate is the same track: title must match, and source must match
    unless one side's source is unknown (blank/None on either side matches
    anything). This is deliberately permissive when data is missing and
    strict only when both sides actually name a source — otherwise two
    different games' "Main Theme" would wrongly collide. This predicate is
    the one place that defines "duplicate"; find_matches and the bulk
    migration paths both defer to the same rule."""
    if _norm(entry.title) != _norm(title):
        return False
    entry_source = _norm(entry.source)
    incoming_source = _norm(source)
    return entry_source == "" or incoming_source == "" or entry_source == incoming_source


def find_matches(title: str, source: Optional[str] = None) -> list[HistoryEntry]:
    """Return history entries that match ``title`` (case/whitespace-insensitive)
    and, unless either side's source is unknown, ``source`` too — see
    ``entry_matches``. Empty list for blank input. Used to reject a repeat
    OST. ``source`` defaults to None, i.e. "any source", for callers that
    only care about the title (e.g. debugging/parity checks)."""
    norm_title = _norm(title)
    if not norm_title:
        return []
    norm_source = _norm(source)
    rows = get_db().query(
        f"{_SELECT_ENTRY} WHERE LOWER(TRIM(title)) = ? "
        "AND (? = '' OR COALESCE(LOWER(TRIM(source)), '') = '' OR LOWER(TRIM(source)) = ?)",
        (norm_title, norm_source, norm_source),
    )
    return [_row_to_entry(r) for r in rows]
