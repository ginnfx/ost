"""Tests for the batch randomizer: configurable count, manual arrangement,
editable pins, and the self-healing slide-in."""

from __future__ import annotations

import random

import pytest

from ost_tracker.db import ost_repo, people_repo, settings_repo
from ost_tracker.services import batches


def _make_osts(fresh_db, n, submitter_id=None, offset=0):
    """Add n OSTs, return their ids in creation order. ``offset`` keeps titles
    unique across multiple calls within the same test (titles must be unique
    now that repeats are hard-blocked)."""
    ids = []
    for i in range(offset, offset + n):
        ids.append(ost_repo.add_ost(f"OST {i:02d}", f"src {i}", submitter_id, None))
    return ids


# --- count -------------------------------------------------------------------


def test_default_count_is_three(fresh_db):
    assert batches.get_count() == 3


def test_set_count_persists_and_clamps(fresh_db):
    batches.set_count(4)
    assert batches.get_count() == 4
    with pytest.raises(ValueError):
        batches.set_count(0)
    with pytest.raises(ValueError):
        batches.set_count(99)


def test_batch_sizes_dumps_remainder_last(fresh_db):
    assert batches.batch_sizes(50, 3) == [16, 16, 18]
    assert batches.batch_sizes(9, 3) == [3, 3, 3]


def test_set_count_reflows_preserving_order(fresh_db):
    ids = _make_osts(fresh_db, 6)
    batches.save_arrangement([ids[0:3], ids[3:6]])  # 2 batches
    batches.set_count(3)
    _, groups, _ = batches.current()
    flat = [slot.id for group in groups for slot in group]
    assert flat == ids  # global order preserved across re-flow
    assert [len(g) for g in groups] == [2, 2, 2]


# --- manual arrangement ------------------------------------------------------


def test_save_arrangement_roundtrips(fresh_db):
    ids = _make_osts(fresh_db, 4)
    batches.set_count(2)
    batches.save_arrangement([[ids[3], ids[2]], [ids[1], ids[0]]])
    _, groups, _ = batches.current()
    assert [[o.id for o in g] for g in groups] == [[ids[3], ids[2]], [ids[1], ids[0]]]


def test_save_arrangement_rejects_unknown_id(fresh_db):
    ids = _make_osts(fresh_db, 2)
    with pytest.raises(ValueError):
        batches.save_arrangement([[ids[0], 9999]])


def test_save_arrangement_rejects_duplicate(fresh_db):
    ids = _make_osts(fresh_db, 2)
    with pytest.raises(ValueError):
        batches.save_arrangement([[ids[0], ids[0]]])


# --- pins --------------------------------------------------------------------


def test_pin_persists_and_survives_randomize(fresh_db):
    ids = _make_osts(fresh_db, 12)
    batches.randomize()  # seeds default (empty needle) pins, lays everything out
    target = ids[5]
    batches.set_pin(target, True)
    # Find where it sits now, then re-randomize and confirm it stayed put.
    _, groups, pins = batches.current()
    assert target in pins
    pos = _position_of(groups, target)
    for _ in range(5):
        batches.randomize()
        _, groups, _ = batches.current()
        assert _position_of(groups, target) == pos


def test_set_pin_rejects_unknown(fresh_db):
    with pytest.raises(ValueError):
        batches.set_pin(9999, True)


def test_unpin_removes_from_set(fresh_db):
    ids = _make_osts(fresh_db, 4)
    batches.set_pin(ids[0], True)
    assert ids[0] in batches.pinned_ids(ost_repo.list_osts())
    batches.set_pin(ids[0], False)
    assert ids[0] not in batches.pinned_ids(ost_repo.list_osts())


# --- slide-in ----------------------------------------------------------------


def test_slide_in_places_new_osts_without_disturbing_pins(fresh_db):
    ids = _make_osts(fresh_db, 6)
    batches.set_count(2)
    batches.save_arrangement([ids[0:3], ids[3:6]])
    batches.set_pin(ids[0], True)
    pos = _position_of(_groups(), ids[0])
    # Add three more and let current() slide them in.
    new_ids = _make_osts(fresh_db, 3, offset=6)
    _, groups, _ = batches.current()
    flat = [o.id for g in groups for o in g]
    for nid in new_ids:
        assert nid in flat  # every new OST landed somewhere
    assert _position_of(groups, ids[0]) == pos  # pin never shifted


def test_build_assignment_is_deterministic_with_seed(fresh_db):
    osts = [ost_repo.get_ost(i) for i in _make_osts(fresh_db, 9)]
    a = batches.build_assignment(osts, rng=random.Random(1))
    b = batches.build_assignment(osts, rng=random.Random(1))
    assert [[o.id for o in g] for g in a] == [[o.id for o in g] for g in b]


# --- helpers -----------------------------------------------------------------


def _groups():
    _, groups, _ = batches.current()
    return groups


def _position_of(groups, ost_id):
    for bi, group in enumerate(groups):
        for si, ost in enumerate(group):
            if ost.id == ost_id:
                return (bi, si)
    return None
