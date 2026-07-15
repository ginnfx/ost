"""SQLite connection management.

Design note: the spec left the ORM choice open ("SQLAlchemy your call, keep it
simple"). For a ~500-row single-user local dataset, raw ``sqlite3`` is the
simplest thing that works — no schema-mapping layer, no session lifecycle, and
trivially inspectable output. We use one long-lived connection shared across
threads (``check_same_thread=False``) guarded by a re-entrant lock, plus WAL
mode so the background cover-art thread never blocks UI reads.
"""

from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Iterable, Iterator, Optional, Sequence

from ost_tracker.config import database_path

_SCHEMA_PATH = Path(__file__).with_name("schema.sql")


class Database:
    """Thin, thread-safe wrapper around a single SQLite connection."""

    def __init__(self, path: Optional[Path] = None) -> None:
        self._path = Path(path) if path is not None else database_path()
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(
            str(self._path),
            check_same_thread=False,
            detect_types=sqlite3.PARSE_DECLTYPES,
        )
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA foreign_keys = ON")
        self._conn.execute("PRAGMA journal_mode = WAL")
        self._conn.execute("PRAGMA synchronous = NORMAL")
        self._init_schema()

    @property
    def path(self) -> Path:
        return self._path

    def _init_schema(self) -> None:
        sql = _SCHEMA_PATH.read_text(encoding="utf-8")
        with self._lock:
            self._conn.executescript(sql)
            self._apply_column_migrations()
            self._conn.commit()

    def _apply_column_migrations(self) -> None:
        """Add columns that post-date a table's creation. ``CREATE TABLE IF NOT
        EXISTS`` never alters an existing table, so a database created before a
        column was introduced needs an explicit ALTER on open. Idempotent:
        each ALTER runs only while its column is missing."""
        added_columns = [
            ("osts", "cover_accent_hex", "TEXT"),
            ("osts", "playback_watch_url", "TEXT"),
            ("ost_history", "batch_label", "TEXT"),
            ("ost_history", "sender", "TEXT"),
        ]
        for table, column, col_type in added_columns:
            existing = {
                row["name"] for row in self._conn.execute(f"PRAGMA table_info({table})")
            }
            if column not in existing:
                self._conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}")

    # --- read helpers ---------------------------------------------------

    def query(self, sql: str, params: Sequence = ()) -> list[sqlite3.Row]:
        with self._lock:
            cur = self._conn.execute(sql, params)
            return cur.fetchall()

    def query_one(self, sql: str, params: Sequence = ()) -> Optional[sqlite3.Row]:
        with self._lock:
            cur = self._conn.execute(sql, params)
            return cur.fetchone()

    def scalar(self, sql: str, params: Sequence = ()):
        row = self.query_one(sql, params)
        if row is None:
            return None
        return row[0]

    # --- write helpers --------------------------------------------------

    def execute(self, sql: str, params: Sequence = ()) -> int:
        """Execute a single write and commit. Returns ``lastrowid``."""
        with self._lock:
            cur = self._conn.execute(sql, params)
            self._conn.commit()
            return cur.lastrowid

    def executemany(self, sql: str, seq_of_params: Iterable[Sequence]) -> None:
        with self._lock:
            self._conn.executemany(sql, seq_of_params)
            self._conn.commit()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        """Group several writes into one atomic commit/rollback."""
        with self._lock:
            try:
                yield self._conn
                self._conn.commit()
            except Exception:
                self._conn.rollback()
                raise

    def close(self) -> None:
        with self._lock:
            self._conn.close()


# --- module-level singleton -------------------------------------------------

_db: Optional[Database] = None
_db_lock = threading.Lock()


def get_db() -> Database:
    """Return the process-wide Database, creating it on first use."""
    global _db
    with _db_lock:
        if _db is None:
            _db = Database()
        return _db


def set_db(db: Optional[Database]) -> None:
    """Override the singleton (used by tests to inject an isolated DB)."""
    global _db
    with _db_lock:
        _db = db
