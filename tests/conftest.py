"""Shared pytest fixtures.

Every test gets a throwaway Application Support directory and a fresh Database
singleton, so tests never touch real user data and never leak state between
each other. ``app_support_dir()`` reads ``OST_TRACKER_HOME`` dynamically on each
call, so redirecting state is just an env var plus resetting the singleton — no
module reloads (which would desync the ``get_db`` reference repos captured at
import time).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


@pytest.fixture()
def fresh_db(tmp_path, monkeypatch):
    monkeypatch.setenv("OST_TRACKER_HOME", str(tmp_path))

    from ost_tracker.db import connection

    connection.set_db(None)
    db = connection.get_db()
    yield db
    db.close()
    connection.set_db(None)
