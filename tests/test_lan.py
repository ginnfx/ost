"""The LAN companion must keep a stable secret and protect Mac artwork."""

from __future__ import annotations

import os
import stat

from fastapi.testclient import TestClient


def test_lan_pairing_token_is_private_and_stable(fresh_db):
    from backend import api
    from ost_tracker.config import app_support_dir

    first = api._lan_token()
    assert len(first) == 64
    assert api._lan_token() == first
    if os.name == "posix":
        assert stat.S_IMODE((app_support_dir() / "lan-token").stat().st_mode) == 0o600


def test_lan_cover_requires_token_and_uses_known_cover_path(fresh_db):
    from backend import api
    from ost_tracker.config import covers_dir
    from ost_tracker.db import ost_repo

    ost_id = ost_repo.add_ost("Test OST")
    cover = covers_dir() / f"cover_{ost_id}.jpg"
    cover.write_bytes(b"sample-cover")
    ost_repo.set_cover(ost_id, str(cover))

    client = TestClient(api.app)
    assert client.get(f"/covers/{ost_id}").status_code == 401
    response = client.get(f"/covers/{ost_id}", headers={"X-OST-Token": api.TOKEN})
    assert response.status_code == 200
    assert response.content == b"sample-cover"
    assert client.get("/covers/99999", headers={"X-OST-Token": api.TOKEN}).status_code == 404
