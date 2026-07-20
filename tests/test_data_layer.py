"""Tests for the SQLite data-access layer: CRUD, the ratings upsert, cascade
deletes, leaderboard stats, reveal logic, and the notes/competition boundary."""

from __future__ import annotations

import pytest

from ost_tracker.db import history_repo, notes_repo, ost_repo, people_repo, rating_repo, settings_repo
from ost_tracker.services import rater_stats, reveal, statistics


# --- people -----------------------------------------------------------------

def test_add_and_list_people(fresh_db):
    people_repo.add_person("Alice")
    people_repo.add_person("bob")
    names = [p.name for p in people_repo.list_people()]
    assert names == ["Alice", "bob"]  # case-insensitive alpha order


def test_duplicate_person_name_rejected(fresh_db):
    people_repo.add_person("Alice")
    with pytest.raises(Exception):
        people_repo.add_person("Alice")


def test_rename_and_delete_person(fresh_db):
    p = people_repo.add_person("Al")
    people_repo.rename_person(p.id, "Alice")
    assert people_repo.get_person(p.id).name == "Alice"
    people_repo.delete_person(p.id)
    assert people_repo.get_person(p.id) is None


# --- osts -------------------------------------------------------------------

def test_add_ost_requires_title(fresh_db):
    with pytest.raises(ValueError):
        ost_repo.add_ost("   ")


def test_add_ost_rejects_repeat_title(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_repo.add_ost("Aerith's Theme", "FF7", alice.id)
    with pytest.raises(ValueError):
        ost_repo.add_ost("  aerith's theme  ", "FF7", alice.id)


def test_add_ost_records_into_history(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_repo.add_ost("Aerith's Theme", "FF7", alice.id)
    matches = history_repo.find_matches("Aerith's Theme")
    assert len(matches) == 1
    assert matches[0].source == "FF7"
    assert matches[0].batch_label == ost_repo.CURRENT_RANKING_LABEL
    assert matches[0].sender == "Alice"


def test_ost_crud_roundtrip(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Aerith's Theme", "FF7", alice.id, "https://youtu.be/x")
    ost = ost_repo.get_ost(ost_id)
    assert ost.title == "Aerith's Theme"
    assert ost.source == "FF7"
    assert ost.submitter_name == "Alice"
    assert ost.external_link == "https://youtu.be/x"

    ost_repo.update_ost(ost_id, title="Aerith", source="FFVII",
                        submitter_id=alice.id, external_link=None)
    ost = ost_repo.get_ost(ost_id)
    assert ost.title == "Aerith"
    assert ost.external_link is None

    ost_repo.set_cover(ost_id, "/tmp/cover.jpg")
    assert ost_repo.get_ost(ost_id).cover_image_path == "/tmp/cover.jpg"


def test_deleting_person_nulls_submitter(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    people_repo.delete_person(alice.id)
    assert ost_repo.get_ost(ost_id).submitter_id is None


# --- ratings upsert ---------------------------------------------------------

def test_rating_upsert_corrects_not_duplicates(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)

    rating_repo.upsert_rating(ost_id, alice.id, 7)
    rating_repo.upsert_rating(ost_id, alice.id, 9)  # re-entry corrects

    assert rating_repo.get_score(ost_id, alice.id) == 9
    assert rating_repo.total_ratings() == 1  # not duplicated


def test_rating_out_of_range_rejected(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    for bad in (-1, 11, 100, -0.5, 10.5):
        with pytest.raises(ValueError):
            rating_repo.upsert_rating(ost_id, alice.id, bad)


def test_rating_accepts_decimal_scores(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)

    for value in (7.5, 6.7, 8.66):
        rating_repo.upsert_rating(ost_id, alice.id, value)
        assert rating_repo.get_score(ost_id, alice.id) == value

    assert rating_repo.ratings_for_ost(ost_id)[0].score == 8.66


def test_rating_rounds_to_two_decimals(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)

    rating_repo.upsert_rating(ost_id, alice.id, 8.666)

    assert rating_repo.get_score(ost_id, alice.id) == 8.67


def test_half_point_scores_flow_into_stats(fresh_db):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    ost_id = ost_repo.add_ost("Song", "Game", None)

    rating_repo.upsert_rating(ost_id, alice.id, 7.5)
    rating_repo.upsert_rating(ost_id, bob.id, 8.5)

    stats = ost_repo.get_ost_stats(ost_id)
    assert stats.average == 8.0
    assert stats.minimum == 7.5
    assert stats.maximum == 8.5


def test_deleting_ost_cascades_ratings(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    rating_repo.upsert_rating(ost_id, alice.id, 5)
    ost_repo.delete_ost(ost_id)
    assert rating_repo.total_ratings() == 0


def test_delete_rating_clears_cell(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    rating_repo.upsert_rating(ost_id, alice.id, 5)
    rating_repo.delete_rating(ost_id, alice.id)
    assert rating_repo.get_score(ost_id, alice.id) is None


# --- self-ratings -----------------------------------------------------------

def test_self_rating_auto_inserted_on_create(fresh_db):
    from ost_tracker.config import SELF_RATING_SCORE

    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Mine", "Game", alice.id)
    # The submitter's own 10/10 lands automatically and counts like any rating.
    assert rating_repo.get_score(ost_id, alice.id) == SELF_RATING_SCORE
    assert rating_repo.total_ratings() == 1
    stats = ost_repo.get_ost_stats(ost_id)
    assert stats.average == pytest.approx(float(SELF_RATING_SCORE))
    assert stats.rating_count == 1


def test_no_self_rating_without_submitter(fresh_db):
    ost_id = ost_repo.add_ost("Orphan", "Game", None)
    assert rating_repo.total_ratings() == 0
    assert ost_repo.get_ost_stats(ost_id).average is None


def test_self_rating_included_in_average(fresh_db):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)  # alice self = 10
    rating_repo.upsert_rating(ost_id, bob.id, 4)
    # (10 + 4) / 2
    assert ost_repo.get_ost_stats(ost_id).average == pytest.approx(7.0)


def test_self_rating_is_editable_not_duplicated(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    # Correcting the submitter's own score reuses the same row (no duplicate).
    rating_repo.upsert_rating(ost_id, alice.id, 6)
    assert rating_repo.get_score(ost_id, alice.id) == 6
    assert rating_repo.total_ratings() == 1


def test_backfill_self_ratings_is_idempotent(fresh_db):
    from ost_tracker.config import SELF_RATING_SCORE
    from ost_tracker.db import migrations

    alice = people_repo.add_person("Alice")
    # Simulate a legacy OST that predates self-ratings by deleting the seeded one.
    ost_id = ost_repo.add_ost("Legacy", "Game", alice.id)
    rating_repo.delete_rating(ost_id, alice.id)
    ost_repo.add_ost("NoSubmitter", "Game", None)  # must be skipped
    assert rating_repo.total_ratings() == 0

    assert migrations.backfill_self_ratings() == 1  # only the legacy submitted one
    assert rating_repo.get_score(ost_id, alice.id) == SELF_RATING_SCORE
    assert migrations.backfill_self_ratings() == 0  # nothing left to do


def test_run_pending_backfills_once(fresh_db):
    from ost_tracker.db import migrations

    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    rating_repo.delete_rating(ost_id, alice.id)  # emulate legacy row
    migrations.run_pending()
    assert rating_repo.get_score(ost_id, alice.id) is not None
    # A second OST added after the one-time migration ran still self-rates via
    # add_ost, and run_pending doesn't run the backfill again.
    bob = people_repo.add_person("Bob")
    o2 = ost_repo.add_ost("Second", "Game", bob.id)
    rating_repo.delete_rating(o2, bob.id)
    migrations.run_pending()  # flag already set -> no-op
    assert rating_repo.get_score(o2, bob.id) is None


# --- leaderboard stats ------------------------------------------------------

def test_leaderboard_ranking_and_stats(fresh_db):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    low = ost_repo.add_ost("Low", "Game", alice.id)
    high = ost_repo.add_ost("High", "Game", bob.id)
    # No submitter -> no auto self-rating, so this one stays genuinely unrated.
    unrated = ost_repo.add_ost("Unrated", "Game", None)

    # Explicit ratings overwrite each submitter's seeded self-rating on their own
    # OST, so the averages below are over exactly these two scores.
    rating_repo.upsert_rating(low, alice.id, 2)
    rating_repo.upsert_rating(low, bob.id, 4)   # avg 3
    rating_repo.upsert_rating(high, alice.id, 8)
    rating_repo.upsert_rating(high, bob.id, 10)  # avg 9

    stats = {s.ost.id: s for s in ost_repo.list_osts_with_stats()}
    assert stats[high].rank == 1
    assert stats[low].rank == 2
    assert stats[unrated].rank is None
    assert stats[high].average == pytest.approx(9.0)
    assert stats[low].minimum == 2 and stats[low].maximum == 4
    assert stats[low].stddev == pytest.approx(1.0)  # popn stddev of [2,4]


def test_tiebreak_by_submitter_own_average(fresh_db):
    strong = people_repo.add_person("Strong")
    weak = people_repo.add_person("Weak")
    rater = people_repo.add_person("Rater")

    a_tie = ost_repo.add_ost("A tie", "G", strong.id)
    a_other = ost_repo.add_ost("A other", "G", strong.id)
    b_tie = ost_repo.add_ost("B tie", "G", weak.id)

    # A-tie and B-tie share average 5, but Strong's other OST is a 9, lifting
    # their own-submission average (7) above Weak's (5).
    rating_repo.upsert_rating(a_tie, rater.id, 5)
    rating_repo.upsert_rating(b_tie, rater.id, 5)
    rating_repo.upsert_rating(a_other, rater.id, 9)

    stats = {s.ost.id: s for s in ost_repo.list_osts_with_stats()}
    assert stats[a_other].rank == 1          # highest average
    assert stats[a_tie].rank == 2            # tie broken by stronger submitter
    assert stats[b_tie].rank == 3
    assert stats[a_tie].average == pytest.approx(stats[b_tie].average)  # genuinely tied


def test_tiebreak_survives_incomplete_data(fresh_db):
    # A submitter with no rated OSTs must not break ranking of a tie.
    p1 = people_repo.add_person("P1")
    p2 = people_repo.add_person("P2")
    rater = people_repo.add_person("R")
    o1 = ost_repo.add_ost("One", "G", p1.id)
    o2 = ost_repo.add_ost("Two", "G", p2.id)
    ost_repo.add_ost("Unrated", "G", None)  # no submitter, no ratings
    rating_repo.upsert_rating(o1, rater.id, 6)
    rating_repo.upsert_rating(o2, rater.id, 6)  # tie, both submitters have own-avg 6

    # Should not raise; both get consecutive ranks, unrated is unranked.
    stats = {s.ost.id: s for s in ost_repo.list_osts_with_stats()}
    assert {stats[o1].rank, stats[o2].rank} == {1, 2}


# --- statistics helpers -----------------------------------------------------

def test_statistics_edge_cases():
    assert statistics.mean([]) is None
    assert statistics.population_stddev([]) is None
    assert statistics.population_stddev([5]) == 0.0
    assert statistics.mean([2, 4, 6]) == 4
    assert statistics.spread_label(None, None) == "—"
    assert statistics.spread_label(3, 10) == "3–10"


# --- reveal logic -----------------------------------------------------------

def test_reveal_hidden_until_complete(fresh_db):
    people = [people_repo.add_person(n) for n in ("A", "B")]
    osts = [ost_repo.add_ost(t, "G", people[0].id) for t in ("x", "y")]
    assert not reveal.scores_visible()  # nothing rated

    # Fill every (person, ost) pair -> 4 cells.
    for o in osts:
        for p in people:
            rating_repo.upsert_rating(o, p.id, 5)
    assert reveal.is_complete()
    assert reveal.scores_visible()


def test_manual_reveal_overrides_incomplete(fresh_db):
    people_repo.add_person("A")
    ost_repo.add_ost("x", "G", None)
    assert not reveal.scores_visible()
    reveal.set_manually_unlocked(True)
    assert reveal.scores_visible()
    reveal.set_manually_unlocked(False)
    assert not reveal.scores_visible()


# --- per-rater leniency -----------------------------------------------------

def test_rater_leniency_orders_by_generosity(fresh_db):
    lenient = people_repo.add_person("Lenient")
    harsh = people_repo.add_person("Harsh")
    people_repo.add_person("Never")  # rates nothing; must sort last
    ost_id = ost_repo.add_ost("Song", "Game", lenient.id)
    rating_repo.upsert_rating(ost_id, lenient.id, 10)
    rating_repo.upsert_rating(ost_id, harsh.id, 2)

    stats = rater_stats.rater_leniency()
    assert stats[0].name == "Lenient"
    assert stats[1].name == "Harsh"
    assert stats[-1].name == "Never"
    assert stats[-1].average_given is None


# --- notes are isolated from competition ------------------------------------

def test_notes_crud_and_isolation(fresh_db):
    people_repo.add_person("Alice")
    n = notes_repo.add_note("Maybe this one", "great boss theme")
    assert notes_repo.get_note(n.id).note == "great boss theme"
    notes_repo.update_note(n.id, "Definitely", "final answer")
    assert notes_repo.get_note(n.id).title == "Definitely"

    # Promoting a note does not couple it to an OST: adding the OST leaves the
    # note untouched, and neither affects the other's existence.
    ost_repo.add_ost("Definitely", "Game", None)
    assert notes_repo.get_note(n.id) is not None
    assert ost_repo.count_osts() == 1

    notes_repo.delete_note(n.id)
    assert notes_repo.get_note(n.id) is None
    assert ost_repo.count_osts() == 1  # deleting the note leaves the OST alone


def test_settings_roundtrip(fresh_db):
    assert settings_repo.get_setting("missing") is None
    settings_repo.set_setting("k", "v")
    assert settings_repo.get_setting("k") == "v"
    settings_repo.set_bool("flag", True)
    assert settings_repo.get_bool("flag") is True


def test_bing_api_key_config_roundtrip(fresh_db):
    from ost_tracker import config

    assert config.get_bing_api_key() is None       # nothing configured yet
    config.set_bing_api_key("abc123")
    assert config.get_bing_api_key() == "abc123"
    assert config.config_file_path().exists()      # persisted to config.json
    config.set_bing_api_key("   ")                  # blank clears it
    assert config.get_bing_api_key() is None
