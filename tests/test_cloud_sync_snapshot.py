"""The portable sync API round-trips competition data without device file paths."""

import json

from fastapi.testclient import TestClient


def test_sync_snapshot_round_trips_rows_and_preserves_local_art(fresh_db):
    from backend import api
    from ost_tracker.config import covers_dir
    from ost_tracker.db import notes_repo, ost_repo, people_repo, rating_repo

    person = people_repo.add_person("Cloud tester")
    ost_id = ost_repo.add_ost("Shared OST", submitter_id=person.id)
    notes_repo.add_note("A note", "Written on one device")
    rating_repo.upsert_rating(ost_id, person.id, 8.5)
    cover = covers_dir() / f"cover_{ost_id}.jpg"
    cover.write_bytes(b"local artwork")
    ost_repo.set_cover(ost_id, str(cover))

    client = TestClient(api.app)
    headers = {"X-OST-Token": api.TOKEN}
    snapshot_response = client.get("/sync/state", headers=headers)
    assert snapshot_response.status_code == 200
    snapshot = snapshot_response.json()
    assert snapshot["tables"]["people"][0]["name"] == "Cloud tester"
    assert "cover_image_path" not in snapshot["tables"]["osts"][0]

    # A second import replaces the shared rows while keeping host-only art.
    assert client.put("/sync/state", headers=headers, json=snapshot).status_code == 200
    assert people_repo.list_people()[0].name == "Cloud tester"
    assert notes_repo.list_notes()[0].note == "Written on one device"
    assert rating_repo.get_score(ost_id, person.id) == 8.5
    assert ost_repo.get_ost(ost_id).cover_image_path == str(cover)

    # Cover paths inside a retired archive are private to each device too.
    from ost_tracker.db import rounds_repo
    from ost_tracker.db.connection import get_db

    rounds_repo.retire_round()
    archive_response = client.get("/sync/state", headers=headers)
    archive_snapshot = archive_response.json()
    archived_payload = json.loads(archive_snapshot["tables"]["retired_rounds"][0]["payload"])
    assert "cover_image_path" not in archived_payload["osts"][0]
    assert client.put("/sync/state", headers=headers, json=archive_snapshot).status_code == 200
    stored_payload = json.loads(get_db().query("SELECT payload FROM retired_rounds")[0]["payload"])
    assert stored_payload["osts"][0]["cover_image_path"] == str(cover)


def test_sync_snapshot_rejects_malformed_payload(fresh_db):
    from backend import api

    client = TestClient(api.app)
    response = client.put(
        "/sync/state",
        headers={"X-OST-Token": api.TOKEN},
        json={"version": 2, "tables": {}},
    )
    assert response.status_code == 400
