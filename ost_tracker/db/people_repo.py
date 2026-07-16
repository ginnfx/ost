"""CRUD for the ``people`` table."""

from __future__ import annotations

import sqlite3
from typing import Optional

from ost_tracker.db.connection import get_db
from ost_tracker.db.models import Person


def _row_to_person(row: sqlite3.Row) -> Person:
    return Person(id=row["id"], name=row["name"])


def list_people() -> list[Person]:
    rows = get_db().query("SELECT id, name FROM people ORDER BY name COLLATE NOCASE")
    return [_row_to_person(r) for r in rows]


def get_person(person_id: int) -> Optional[Person]:
    row = get_db().query_one("SELECT id, name FROM people WHERE id = ?", (person_id,))
    return _row_to_person(row) if row else None


def add_person(name: str) -> Person:
    name = name.strip()
    if not name:
        raise ValueError("Person name cannot be empty")
    new_id = get_db().execute("INSERT INTO people (name) VALUES (?)", (name,))
    return Person(id=new_id, name=name)


def rename_person(person_id: int, name: str) -> None:
    name = name.strip()
    if not name:
        raise ValueError("Person name cannot be empty")
    get_db().execute("UPDATE people SET name = ? WHERE id = ?", (name, person_id))


def delete_person(person_id: int) -> None:
    """Delete a person. Their OSTs' submitter becomes NULL and their ratings
    cascade away (see schema foreign keys)."""
    get_db().execute("DELETE FROM people WHERE id = ?", (person_id,))


def count_people() -> int:
    return int(get_db().scalar("SELECT COUNT(*) FROM people") or 0)
