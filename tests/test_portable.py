"""Portable competition bundle (export/import of ost.db + covers/)."""
from __future__ import annotations

import zipfile

from ost_tracker.db import ost_repo, people_repo
from ost_tracker.services import portable


def _seed_competition(db) -> None:
    person = people_repo.add_person("Alice")
    people_repo.add_person("Bob")
    ost_id = ost_repo.add_ost("Main Theme", source="Some Game", submitter_id=person.id)
    covers = db.path.parent / "covers"
    covers.mkdir(parents=True, exist_ok=True)
    (covers / "seed.jpg").write_bytes(b"jpeg")
    db.execute(
        "UPDATE osts SET cover_image_path = ? WHERE id = ?",
        (str(covers / "seed.jpg"), ost_id),
    )


def test_export_creates_zip_with_db_and_covers(fresh_db, tmp_path):
    _seed_competition(fresh_db)

    bundle = portable.export_bundle()
    try:
        assert bundle.is_file()
        with zipfile.ZipFile(bundle) as zf:
            names = zf.namelist()
            assert "ost.db" in names
            assert "covers/seed.jpg" in names
    finally:
        bundle.unlink(missing_ok=True)


def test_import_stage_then_apply(fresh_db, tmp_path):
    _seed_competition(fresh_db)
    bundle = portable.export_bundle()
    try:
        # Close the singleton first: Windows locks an open SQLite file, so the
        # swap below has to happen with no connection holding it.
        fresh_db.close()
        from ost_tracker.db import connection

        connection.set_db(None)

        # Wipe the live db to prove the staged import restores it.
        db_path = fresh_db.path
        (db_path.parent / "covers" / "seed.jpg").unlink()
        db_path.unlink()

        portable.stage_import(bundle)
        applied = portable.apply_staged_import()
        assert applied is True
        assert db_path.exists()
        assert (db_path.parent / "covers" / "seed.jpg").exists()
        assert people_repo.list_people(), "data restored after import"
        # Second apply is a no-op (nothing staged).
        assert portable.apply_staged_import() is False
    finally:
        bundle.unlink(missing_ok=True)


def test_import_rejects_missing_db(fresh_db, tmp_path):
    bogus = tmp_path / "bogus.zip"
    with zipfile.ZipFile(bogus, "w") as zf:
        zf.writestr("notes.txt", "hello")
    try:
        portable.stage_import(bogus)
        assert False, "should have raised"
    except ValueError:
        pass
    finally:
        bogus.unlink(missing_ok=True)
