"""CRUD for the ``notes`` scratchpad table.

This table is kept separate from the competition data. Nothing here
joins to ``osts``, and promoting a note to a real OST (see the Notes tab) is a
plain read of the note followed by an independent insert into ``osts`` — no
foreign key ties the two together, so a note and the OST it inspired live
separate lives.
"""

from __future__ import annotations

import sqlite3
from typing import Optional

from ost_tracker.db.connection import get_db
from ost_tracker.db.models import Note


def _row_to_note(row: sqlite3.Row) -> Note:
    return Note(
        id=row["id"],
        title=row["title"],
        note=row["note"] or "",
        created_at=row["created_at"],
    )


def list_notes() -> list[Note]:
    rows = get_db().query(
        "SELECT id, title, note, created_at FROM notes ORDER BY created_at DESC, id DESC"
    )
    return [_row_to_note(r) for r in rows]


def get_note(note_id: int) -> Optional[Note]:
    row = get_db().query_one(
        "SELECT id, title, note, created_at FROM notes WHERE id = ?", (note_id,)
    )
    return _row_to_note(row) if row else None


def add_note(title: str, note: str = "") -> Note:
    title = (title or "").strip()
    if not title:
        raise ValueError("Note title cannot be empty")
    new_id = get_db().execute(
        "INSERT INTO notes (title, note) VALUES (?, ?)", (title, note or "")
    )
    created = get_note(new_id)
    if created is None:
        raise RuntimeError(f"note {new_id} missing after insert")
    return created


def update_note(note_id: int, title: str, note: str) -> None:
    title = (title or "").strip()
    if not title:
        raise ValueError("Note title cannot be empty")
    get_db().execute(
        "UPDATE notes SET title = ?, note = ? WHERE id = ?", (title, note or "", note_id)
    )


def delete_note(note_id: int) -> None:
    get_db().execute("DELETE FROM notes WHERE id = ?", (note_id,))
