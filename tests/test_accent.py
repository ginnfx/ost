"""Tests for the cover-accent extraction service and its DB plumbing."""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from ost_tracker.services import accent


def _write_solid(tmp_path: Path, color: tuple[int, int, int], name: str = "cover.jpg") -> Path:
    path = tmp_path / name
    Image.new("RGB", (120, 120), color).save(path, format="JPEG", quality=95)
    return path


class TestExtractAccent:
    def test_vivid_cover_yields_a_hex_color(self, tmp_path):
        path = _write_solid(tmp_path, (200, 40, 60))
        result = accent.extract_accent(path)
        assert result is not None
        assert result.startswith("#") and len(result) == 7
        int(result[1:], 16)  # parses as hex

    def test_extracted_color_keeps_the_cover_hue(self, tmp_path):
        path = _write_solid(tmp_path, (30, 90, 220))  # strongly blue
        result = accent.extract_accent(path)
        r, g, b = accent._hex_to_rgb(result)
        assert b > r and b > g

    def test_near_black_cover_falls_back_to_none(self, tmp_path):
        path = _write_solid(tmp_path, (10, 10, 12))
        assert accent.extract_accent(path) is None

    def test_washed_out_grey_cover_falls_back_to_none(self, tmp_path):
        path = _write_solid(tmp_path, (120, 120, 122))
        assert accent.extract_accent(path) is None

    def test_missing_file_returns_none(self, tmp_path):
        assert accent.extract_accent(tmp_path / "nope.jpg") is None

    def test_non_image_file_returns_none(self, tmp_path):
        path = tmp_path / "not_an_image.jpg"
        path.write_text("definitely not a JPEG")
        assert accent.extract_accent(path) is None

    def test_result_is_clamped_to_legible_brightness(self, tmp_path):
        # A dark-but-saturated cover must come back bright enough to glow
        # against the near-black app background.
        path = _write_solid(tmp_path, (70, 10, 10))
        result = accent.extract_accent(path)
        assert result is not None
        _, _, v = accent._rgb_to_hsv(accent._hex_to_rgb(result))
        assert v >= accent._MIN_VALUE - (1 / 255)  # allow 8-bit rounding

    def test_dominant_color_wins_over_minority(self, tmp_path):
        img = Image.new("RGB", (120, 120), (210, 60, 40))  # dominant warm red
        for x in range(20):
            for y in range(20):
                img.putpixel((x, y), (40, 60, 210))  # minority blue corner
        path = tmp_path / "mixed.jpg"
        img.save(path, format="JPEG", quality=95)
        r, g, b = accent._hex_to_rgb(accent.extract_accent(path))
        assert r > b


class TestAccentColumn:
    def test_osts_table_has_accent_column(self, fresh_db):
        cols = {row["name"] for row in fresh_db.query("PRAGMA table_info(osts)")}
        assert "cover_accent_hex" in cols

    def test_migration_adds_column_to_pre_existing_db(self, tmp_path, monkeypatch):
        """A database created before the column existed gains it on open."""
        import sqlite3

        from ost_tracker.db import connection

        monkeypatch.setenv("OST_TRACKER_HOME", str(tmp_path))
        db_file = tmp_path / "ost.db"
        legacy = sqlite3.connect(db_file)
        legacy.execute(
            "CREATE TABLE osts (id INTEGER PRIMARY KEY, title TEXT NOT NULL,"
            " source TEXT, submitter_id INTEGER, cover_image_path TEXT,"
            " external_link TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"
        )
        legacy.commit()
        legacy.close()

        connection.set_db(None)
        db = connection.get_db()
        try:
            cols = {row["name"] for row in db.query("PRAGMA table_info(osts)")}
            assert "cover_accent_hex" in cols
        finally:
            db.close()
            connection.set_db(None)

    def test_set_cover_stores_extracted_accent(self, fresh_db, tmp_path):
        from ost_tracker.db import ost_repo

        cover = _write_solid(tmp_path, (200, 40, 60))
        ost_id = ost_repo.add_ost("Vivid Theme")
        ost_repo.set_cover(ost_id, str(cover))
        ost = ost_repo.get_ost(ost_id)
        assert ost.cover_accent_hex is not None
        assert ost.cover_accent_hex.startswith("#")

    def test_set_cover_with_unextractable_cover_stores_null(self, fresh_db, tmp_path):
        from ost_tracker.db import ost_repo

        ost_id = ost_repo.add_ost("Ghost Theme")
        ost_repo.set_cover(ost_id, str(tmp_path / "missing.jpg"))
        assert ost_repo.get_ost(ost_id).cover_accent_hex is None

    def test_clearing_cover_clears_accent(self, fresh_db, tmp_path):
        from ost_tracker.db import ost_repo

        cover = _write_solid(tmp_path, (200, 40, 60))
        ost_id = ost_repo.add_ost("Fading Theme")
        ost_repo.set_cover(ost_id, str(cover))
        ost_repo.set_cover(ost_id, None)
        ost = ost_repo.get_ost(ost_id)
        assert ost.cover_image_path is None
        assert ost.cover_accent_hex is None


class TestAccentBackfill:
    def test_backfill_fills_missing_accents(self, fresh_db, tmp_path):
        from ost_tracker.db import migrations, ost_repo
        from ost_tracker.db.connection import get_db

        cover = _write_solid(tmp_path, (200, 40, 60))
        ost_id = ost_repo.add_ost("Legacy Cover")
        # Simulate a pre-accent row: path present, accent never computed.
        get_db().execute(
            "UPDATE osts SET cover_image_path = ?, cover_accent_hex = NULL WHERE id = ?",
            (str(cover), ost_id),
        )

        assert migrations.backfill_cover_accents() == 1
        assert ost_repo.get_ost(ost_id).cover_accent_hex is not None

    def test_backfill_skips_rows_without_covers(self, fresh_db):
        from ost_tracker.db import migrations, ost_repo

        ost_repo.add_ost("No Cover")
        assert migrations.backfill_cover_accents() == 0
