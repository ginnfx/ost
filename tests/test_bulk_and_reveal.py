"""Bulk ratings, the per-rater ratings filter, and the reveal flag."""
from __future__ import annotations

import io

import pytest
from PIL import Image

from ost_tracker.db import ost_repo, people_repo, rating_repo, settings_repo
from ost_tracker.services import accent, images


@pytest.fixture()
def seeded(fresh_db):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    ost1 = ost_repo.add_ost("One", submitter_id=alice.id)
    ost2 = ost_repo.add_ost("Two", submitter_id=alice.id)
    return alice, bob, ost1, ost2


def test_bulk_apply_upserts_and_clears(seeded):
    alice, _, ost1, ost2 = seeded
    rating_repo.bulk_apply([(ost1, alice.id, 8.66), (ost2, alice.id, 7.5)], [])
    assert rating_repo.get_score(ost1, alice.id) == 8.66
    assert rating_repo.get_score(ost2, alice.id) == 7.5

    rating_repo.bulk_apply([], [(ost1, alice.id)])
    assert rating_repo.get_score(ost1, alice.id) is None
    assert rating_repo.get_score(ost2, alice.id) == 7.5


def test_bulk_apply_rejects_out_of_range(seeded):
    alice, bob, ost1, _ = seeded
    with pytest.raises(ValueError):
        rating_repo.bulk_apply([(ost1, bob.id, 11)], [])
    assert rating_repo.get_score(ost1, bob.id) is None  # nothing applied


def test_ratings_for_rater_filters(seeded):
    alice, bob, ost1, ost2 = seeded
    rating_repo.bulk_apply(
        [(ost1, alice.id, 9.0), (ost2, alice.id, 8.0), (ost1, bob.id, 6.0)], []
    )
    alice_ratings = rating_repo.ratings_for_rater(alice.id)
    assert [(r.ost_id, r.score) for r in alice_ratings] == [(ost1, 9.0), (ost2, 8.0)]


def test_reveal_flag_roundtrip(fresh_db):
    assert settings_repo.get_bool(settings_repo.REVEAL_UNLOCKED) is False
    settings_repo.set_bool(settings_repo.REVEAL_UNLOCKED, True)
    assert settings_repo.get_bool(settings_repo.REVEAL_UNLOCKED) is True
    settings_repo.set_bool(settings_repo.REVEAL_UNLOCKED, False)
    assert settings_repo.get_bool(settings_repo.REVEAL_UNLOCKED) is False


def _color_image(rgb) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (64, 64), rgb).save(buf, format="PNG")
    return buf.getvalue()


def test_cover_save_returns_accent_from_memory(fresh_db, tmp_path):
    path, accent_hex = images.save_cover_from_bytes(
        _color_image((240, 40, 60)), tmp_path / "c.jpg"
    )
    assert path.exists()
    assert accent_hex is not None and accent_hex.startswith("#")


def test_cover_save_grey_gives_no_accent(fresh_db, tmp_path):
    _, accent_hex = images.save_cover_from_bytes(
        _color_image((120, 120, 120)), tmp_path / "grey.jpg"
    )
    assert accent_hex is None


def test_extract_accent_from_image_matches_path_version(fresh_db, tmp_path):
    data = _color_image((20, 200, 90))
    path, _ = images.save_cover_from_bytes(data, tmp_path / "a.jpg")
    with Image.open(path) as img:
        assert accent.extract_accent_from_image(img) == accent.extract_accent(path)
