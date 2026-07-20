"""Tests for the slice-elimination board: bottom-anchored rank slices, the
per-slice "how many has each person got out" tally, and the placement order of
knocked-out people."""

from __future__ import annotations

import pytest

from ost_tracker.db import ost_repo, people_repo, rating_repo, settings_repo
from ost_tracker.db.models import Ost, OstStats
from ost_tracker.services import elimination


def _stat(rank, ost_id, submitter_id, submitter_name):
    """One OST at `rank`. A None rank means unrated (and therefore unsliced)."""
    ost = Ost(
        id=ost_id,
        title=f"OST {ost_id:02d}",
        source=None,
        submitter_id=submitter_id,
        submitter_name=submitter_name,
        cover_image_path=None,
        external_link=None,
        created_at="2026-01-01T00:00:00Z",
    )
    return OstStats(
        ost=ost,
        rating_count=0 if rank is None else 10,
        average=None if rank is None else 10.0 - rank * 0.1,
        minimum=None,
        maximum=None,
        stddev=None,
        rank=rank,
    )


def _competition(people=10, per_person=5):
    """The real shape: `people` submitters with `per_person` OSTs each, dealt
    round-robin down the rankings so nobody is wiped out by a single slice."""
    return [
        _stat(rank, rank, (rank - 1) % people + 1, f"P{(rank - 1) % people + 1}")
        for rank in range(1, people * per_person + 1)
    ]


def _lopsided():
    """P1 owns the bottom ten (ranks 20–11), P2 the top ten (10–1)."""
    return (
        [_stat(rank, rank, 1, "P1") for rank in range(11, 21)]
        + [_stat(rank, rank, 2, "P2") for rank in range(1, 11)]
    )


# --- slicing -----------------------------------------------------------------


def test_fifty_osts_slice_into_five_tens_worst_first():
    board = elimination.build_board(_competition(), threshold=5)
    assert [(s.bottom_rank, s.top_rank) for s in board.slices] == [
        (50, 41), (40, 31), (30, 21), (20, 11), (10, 1)
    ]
    assert [s.index for s in board.slices] == [1, 2, 3, 4, 5]
    assert board.slices[0].label == "50–41"


def test_slices_are_bottom_anchored_so_the_top_slice_takes_the_remainder():
    stats = [_stat(rank, rank, 1, "P1") for rank in range(1, 48)]
    board = elimination.build_board(stats, threshold=5)
    assert [(s.bottom_rank, s.top_rank) for s in board.slices] == [
        (47, 38), (37, 28), (27, 18), (17, 8), (7, 1)
    ]
    assert [len(s.ost_ids) for s in board.slices] == [10, 10, 10, 10, 7]


def test_slice_holds_its_osts_worst_rank_first():
    stats = [_stat(rank, 100 + rank, 1, "P1") for rank in range(1, 11)]
    board = elimination.build_board(stats, threshold=5)
    assert board.slices[0].ost_ids == [110, 109, 108, 107, 106, 105, 104, 103, 102, 101]


def test_unrated_osts_are_left_out_of_the_slices():
    stats = [_stat(rank, rank, 1, "P1") for rank in range(1, 11)]
    stats.append(_stat(None, 99, 1, "P1"))
    board = elimination.build_board(stats, threshold=5)
    assert board.ranked_count == 10
    assert 99 not in board.slices[0].ost_ids


def test_no_ranked_osts_yields_an_empty_board():
    board = elimination.build_board([_stat(None, 1, 1, "P1")], threshold=5)
    assert board.slices == []
    assert board.eliminated == []
    assert [s.person_id for s in board.survivors] == [1]


# --- per-slice tallies -------------------------------------------------------


def test_tally_reports_this_slice_and_the_running_total():
    board = elimination.build_board(_competition(), threshold=5)
    first = {t.person_id: t for t in board.slices[0].tallies}
    second = {t.person_id: t for t in board.slices[1].tallies}
    # Round-robin: exactly one OST per person falls per slice.
    assert (first[1].out_here, first[1].total_out, first[1].remaining) == (1, 1, 4)
    assert (second[1].out_here, second[1].total_out, second[1].remaining) == (1, 2, 3)


def test_tally_lists_everyone_still_standing_even_at_zero_this_slice():
    board = elimination.build_board(_lopsided(), threshold=5)
    bottom = {t.person_id: t for t in board.slices[0].tallies}
    assert bottom[1].out_here == 10
    assert (bottom[2].out_here, bottom[2].total_out) == (0, 0)


def test_people_knocked_out_earlier_drop_off_later_tallies():
    board = elimination.build_board(_lopsided(), threshold=5)
    assert 1 in {t.person_id for t in board.slices[0].tallies}   # eliminated here
    assert 1 not in {t.person_id for t in board.slices[1].tallies}


def test_tallies_lead_with_whoever_is_furthest_out():
    board = elimination.build_board(_lopsided(), threshold=5)
    assert [t.person_id for t in board.slices[0].tallies] == [1, 2]
    assert board.slices[0].tallies[0].eliminated_here is True
    assert board.slices[0].tallies[1].eliminated_here is False


# --- elimination + placement -------------------------------------------------


def test_person_is_eliminated_on_the_ost_that_hits_the_threshold():
    board = elimination.build_board(_lopsided(), threshold=5)
    knocked = board.eliminated[-1]
    assert knocked.person_id == 1
    assert knocked.total_out == 5
    assert knocked.slice_index == 1
    assert knocked.out_at_rank == 16   # 20, 19, 18, 17, 16 — the fifth one down


def test_nobody_goes_out_before_the_threshold_slice():
    board = elimination.build_board(_competition(), threshold=5)
    # Round-robin means everyone sits on 4 out until the very last slice.
    assert all(t.total_out == 4 for t in board.slices[3].tallies)
    assert {e.slice_index for e in board.eliminated} == {5}


def test_places_count_down_from_the_bottom_and_read_best_first():
    # Three submitters, five OSTs each: P3 owns the worst five, then P2, then P1.
    stats = []
    rank = 15
    for person in (3, 2, 1):
        for _ in range(5):
            stats.append(_stat(rank, rank, person, f"P{person}"))
            rank -= 1
    board = elimination.build_board(stats, threshold=5)
    assert [(e.person_id, e.place) for e in board.eliminated] == [(1, 1), (2, 2), (3, 3)]
    assert board.survivors == []


def test_someone_who_never_reaches_the_threshold_survives():
    # P1 owns the bottom ten and goes out; P2 has only three submissions.
    stats = [_stat(rank, rank, 1, "P1") for rank in range(4, 14)]
    stats += [_stat(rank, rank, 2, "P2") for rank in range(1, 4)]
    board = elimination.build_board(stats, threshold=5)
    assert [(e.person_id, e.place) for e in board.eliminated] == [(1, 2)]
    assert [(s.person_id, s.total_out, s.remaining) for s in board.survivors] == [(2, 3, 0)]


def test_unranked_submissions_still_count_as_standing():
    stats = [_stat(rank, rank, 1, "P1") for rank in range(1, 4)]
    stats.append(_stat(None, 99, 1, "P1"))
    board = elimination.build_board(stats, threshold=5)
    assert (board.survivors[0].total_out, board.survivors[0].remaining) == (3, 1)


def test_ost_without_a_submitter_falls_without_tallying():
    stats = [_stat(rank, rank, None, None) for rank in range(1, 11)]
    board = elimination.build_board(stats, threshold=5)
    assert board.slices[0].ost_ids
    assert board.slices[0].tallies == []
    assert board.eliminated == []
    assert board.survivors == []


def test_threshold_moves_when_people_go_out():
    lenient = elimination.build_board(_lopsided(), threshold=10)
    assert lenient.eliminated[-1].out_at_rank == 11   # needs all ten to fall
    strict = elimination.build_board(_lopsided(), threshold=2)
    assert strict.eliminated[-1].out_at_rank == 19


# --- persisted threshold -----------------------------------------------------


def test_default_threshold_is_five(fresh_db):
    assert elimination.get_threshold() == 5


def test_set_threshold_persists_and_validates(fresh_db):
    elimination.set_threshold(3)
    assert elimination.get_threshold() == 3
    with pytest.raises(ValueError):
        elimination.set_threshold(0)
    with pytest.raises(ValueError):
        elimination.set_threshold(99)


def test_corrupt_stored_threshold_falls_back_to_the_default(fresh_db):
    settings_repo.set_setting("elimination_threshold", "banana")
    assert elimination.get_threshold() == elimination.DEFAULT_THRESHOLD


# --- DB-backed board ---------------------------------------------------------


def test_board_reads_live_ratings(fresh_db):
    alice = people_repo.add_person("Alice").id
    bob = people_repo.add_person("Bob").id
    # Two OSTs each, rated by the other person; Alice's score lower, so hers
    # fall first and she is eliminated first (worst place).
    for title, submitter, score in (
        ("A low", alice, 2), ("A lower", alice, 1), ("B high", bob, 9), ("B higher", bob, 10)
    ):
        ost_id = ost_repo.add_ost(title, None, submitter, None)
        rating_repo.upsert_rating(ost_id, bob if submitter == alice else alice, score)

    elimination.set_threshold(2)
    board = elimination.board()

    assert board.threshold == 2
    assert board.ranked_count == 4
    assert [(e.name, e.place) for e in board.eliminated] == [("Bob", 1), ("Alice", 2)]
    assert board.survivors == []
