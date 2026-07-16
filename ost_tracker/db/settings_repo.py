"""Key/value app settings (locked-reveal flag, remembered UI preferences)."""

from __future__ import annotations

from typing import Optional

from ost_tracker.db.connection import get_db

REVEAL_UNLOCKED = "reveal_unlocked"


def get_setting(key: str, default: Optional[str] = None) -> Optional[str]:
    val = get_db().scalar("SELECT value FROM app_settings WHERE key = ?", (key,))
    return val if val is not None else default


def set_setting(key: str, value: str) -> None:
    get_db().execute(
        """
        INSERT INTO app_settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (key, value),
    )


def get_bool(key: str, default: bool = False) -> bool:
    val = get_setting(key)
    if val is None:
        return default
    return val == "1"


def set_bool(key: str, value: bool) -> None:
    set_setting(key, "1" if value else "0")
