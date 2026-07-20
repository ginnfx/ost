"""Tests for the ost_history exclusion list: CRUD, match lookup, and the
guarded migrations that seed it from list.md and backfill it from the live
roster."""

from __future__ import annotations

import pytest

from ost_tracker.db import history_repo, migrations, ost_repo, people_repo


# --- CRUD ---------------------------------------------------------------

def test_add_and_list_entry(fresh_db):
    history_repo.add_entry("Aerith's Theme", "FF7", batch_label="Batch 1", sender="@alice")
    entries = history_repo.list_history()
    assert len(entries) == 1
    assert entries[0].title == "Aerith's Theme"
    assert entries[0].source == "FF7"
    assert entries[0].batch_label == "Batch 1"
    assert entries[0].sender == "@alice"


def test_add_entry_requires_title(fresh_db):
    with pytest.raises(ValueError):
        history_repo.add_entry("   ")


def test_update_and_delete_entry(fresh_db):
    entry = history_repo.add_entry("Song", "Game", batch_label="Batch 1", sender="@bob")
    history_repo.update_entry(entry.id, "Renamed", "Game 2", batch_label="Batch 2", sender="@carol")
    updated = history_repo.get_entry(entry.id)
    assert updated.title == "Renamed"
    assert updated.source == "Game 2"
    assert updated.batch_label == "Batch 2"
    assert updated.sender == "@carol"

    history_repo.delete_entry(entry.id)
    assert history_repo.get_entry(entry.id) is None


def test_count_history(fresh_db):
    assert history_repo.count_history() == 0
    history_repo.add_entry("A")
    history_repo.add_entry("B")
    assert history_repo.count_history() == 2


# --- find_matches ---------------------------------------------------------

def test_find_matches_is_case_and_whitespace_insensitive(fresh_db):
    history_repo.add_entry("  Near's Theme  ", "Death Note")
    assert len(history_repo.find_matches("near's theme")) == 1
    assert len(history_repo.find_matches("NEAR'S THEME")) == 1
    assert len(history_repo.find_matches("  Near's Theme")) == 1
    assert history_repo.find_matches("Unrelated") == []


def test_find_matches_blank_returns_empty(fresh_db):
    history_repo.add_entry("Song")
    assert history_repo.find_matches("") == []
    assert history_repo.find_matches("   ") == []


def test_find_matches_different_sources_do_not_collide(fresh_db):
    history_repo.add_entry("Main Theme", "FF7")
    history_repo.add_entry("Main Theme", "God of War")
    assert history_repo.find_matches("Main Theme", "FF7") == [
        m for m in history_repo.find_matches("Main Theme") if m.source == "FF7"
    ]
    assert len(history_repo.find_matches("Main Theme", "FF7")) == 1
    assert len(history_repo.find_matches("Main Theme", "Dark Souls III")) == 0
    assert len(history_repo.find_matches("Main Theme")) == 2


def test_find_matches_blank_source_matches_any_source(fresh_db):
    history_repo.add_entry("Main Theme", "FF7")
    assert len(history_repo.find_matches("Main Theme", "")) == 1
    assert len(history_repo.find_matches("Main Theme", None)) == 1


def test_find_matches_null_entry_source_matches_any_incoming_source(fresh_db):
    history_repo.add_entry("Untitled Track", None)
    assert len(history_repo.find_matches("Untitled Track", "Some Game")) == 1


# --- add_ost hard block + auto-add ----------------------------------------

def test_add_ost_rejects_title_already_in_history(fresh_db):
    history_repo.add_entry("Near's Theme", "Death Note", batch_label="Batch 1", sender="@alice")
    with pytest.raises(ValueError):
        ost_repo.add_ost("near's theme", "Death Note", None)


def test_add_ost_allows_same_title_different_source(fresh_db):
    history_repo.add_entry("Main Theme", "FF7", batch_label="Batch 1")
    ost_repo.add_ost("Main Theme", "God of War", None)
    assert len(history_repo.find_matches("Main Theme")) == 2


def test_add_ost_auto_records_into_history(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_repo.add_ost("Brand New Song", "Some Game", alice.id)
    matches = history_repo.find_matches("Brand New Song")
    assert len(matches) == 1
    assert matches[0].batch_label == ost_repo.CURRENT_RANKING_LABEL
    assert matches[0].sender == "Alice"


def test_add_ost_with_no_submitter_records_null_sender(fresh_db):
    ost_repo.add_ost("Unsubmitted Song", "Some Game", None)
    matches = history_repo.find_matches("Unsubmitted Song")
    assert len(matches) == 1
    assert matches[0].sender is None


# --- update_ost history sync ------------------------------------------------

def test_update_ost_syncs_history_on_rename(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Old Title", "Game", alice.id)
    ost_repo.update_ost(ost_id, title="New Title", source="Game", submitter_id=alice.id, external_link=None)

    assert history_repo.find_matches("Old Title", "Game") == []
    matches = history_repo.find_matches("New Title", "Game")
    assert len(matches) == 1
    assert matches[0].batch_label == ost_repo.CURRENT_RANKING_LABEL

    # The old title is re-submittable now that its history row moved.
    ost_repo.add_ost("Old Title", "Game", alice.id)


def test_update_ost_sync_updates_sender_on_submitter_change(fresh_db):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    ost_id = ost_repo.add_ost("Song", "Game", alice.id)
    ost_repo.update_ost(ost_id, title="Song", source="Game", submitter_id=bob.id, external_link=None)
    [entry] = history_repo.find_matches("Song", "Game")
    assert entry.sender == "Bob"


def test_update_ost_leaves_past_batch_row_untouched(fresh_db):
    history_repo.add_entry("Song", "Game", batch_label="Batch 1", sender="@alice")
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Song", "Different Game", alice.id)
    ost_repo.update_ost(ost_id, title="Renamed", source="Different Game", submitter_id=alice.id, external_link=None)

    past = [m for m in history_repo.find_matches("Song", "Game") if m.batch_label == "Batch 1"]
    assert len(past) == 1
    assert past[0].title == "Song"


def test_update_ost_with_no_history_row_is_a_noop(fresh_db):
    # Simulates an OST that predates the history feature.
    alice = people_repo.add_person("Alice")
    ost_id = ost_repo.add_ost("Legacy Song", "Game", alice.id)
    [entry] = history_repo.find_matches("Legacy Song", "Game")
    history_repo.delete_entry(entry.id)

    before = history_repo.count_history()
    ost_repo.update_ost(ost_id, title="Renamed Legacy Song", source="Game", submitter_id=alice.id, external_link=None)
    assert history_repo.count_history() == before


# --- migrations -------------------------------------------------------------

def test_seed_history_from_batches_is_idempotent(fresh_db):
    added_first = migrations.seed_history_from_batches()
    assert added_first > 0
    assert migrations.seed_history_from_batches() == 0  # nothing left to add
    assert history_repo.count_history() == added_first


def test_seed_history_from_batches_recovers_all_seed_rows(fresh_db):
    from ost_tracker.db.history_seed_data import SEED_ENTRIES

    added = migrations.seed_history_from_batches()
    assert added == len(SEED_ENTRIES)
    # 11 different games all titled "Main Theme" must all survive the seed —
    # a title-only dedup key would collapse them to 1.
    assert len(history_repo.find_matches("Main Theme")) == 11


def test_backfill_history_from_current_osts(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_repo.add_ost("Roster Song", "Game", alice.id)
    # Simulate a pre-existing roster OST that predates the history feature by
    # removing the auto-recorded entry add_ost just made.
    [entry] = history_repo.find_matches("Roster Song")
    history_repo.delete_entry(entry.id)
    assert history_repo.find_matches("Roster Song") == []

    assert migrations.backfill_history_from_current_osts() == 1
    assert len(history_repo.find_matches("Roster Song")) == 1
    assert migrations.backfill_history_from_current_osts() == 0  # idempotent


def test_run_pending_seeds_and_backfills_history_once(fresh_db):
    alice = people_repo.add_person("Alice")
    ost_repo.add_ost("Roster Song", "Game", alice.id)

    migrations.run_pending()
    count_after_first = history_repo.count_history()
    assert count_after_first > 0
    assert history_repo.find_matches("Roster Song")

    migrations.run_pending()  # flags already set -> no-op
    assert history_repo.count_history() == count_after_first
