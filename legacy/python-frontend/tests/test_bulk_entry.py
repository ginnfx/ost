"""Bulk-entry (by rater) behaviour: Enter saves + advances to the next unrated
row, completing a person auto-advances to the next, and clearing deletes."""

from __future__ import annotations

import pytest

from ost_tracker.db import ost_repo, people_repo, rating_repo

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


def _seed(n_people=2, n_osts=3):
    people = [people_repo.add_person(f"P{i}") for i in range(n_people)]
    # A dedicated submitter (sorts last) owns the OSTs, so none of the raters we
    # test are self-submitting — every row stays in the rateable queue.
    submitter = people_repo.add_person("Zubmitter")
    osts = [ost_repo.add_ost(f"OST {i}", "Game", submitter.id) for i in range(n_osts)]
    return people, osts


def test_enter_saves_and_advances_to_next_unrated(app, qtbot):
    people, osts = _seed()
    from ost_tracker.ui.archive.bulk_entry import BulkEntryScreen

    screen = BulkEntryScreen()
    qtbot.addWidget(screen)
    # Person P0 selected by default; rows built in some order.
    first = screen._rows[0]
    first.edit.setText("8")
    first.edit.submitted.emit()

    # Score persisted for P0 on that OST.
    assert rating_repo.get_score(first.ost.id, people[0].id) == 8
    # Focus advanced to a still-unrated row that isn't the one just saved.
    assert screen._focused_row is not None
    assert screen._focused_row is not first
    assert screen._focused_row.edit.text() == ""


def test_completing_person_auto_advances(app, qtbot):
    people, osts = _seed(n_people=2, n_osts=3)
    from ost_tracker.ui.archive.bulk_entry import BulkEntryScreen

    screen = BulkEntryScreen()
    qtbot.addWidget(screen)
    assert screen.person_combo.currentIndex() == 0

    # Fill all three rows for P0.
    for row in list(screen._rows):
        row.edit.setText("5")
        row.edit.submitted.emit()

    # P0 fully rated -> combo advanced to P1.
    assert screen.person_combo.currentIndex() == 1
    assert len(rating_repo.rated_ost_ids_for_rater(people[0].id)) == 3


def test_clearing_a_score_deletes_the_rating(app, qtbot):
    people, osts = _seed(n_people=1, n_osts=2)
    from ost_tracker.ui.archive.bulk_entry import BulkEntryScreen

    screen = BulkEntryScreen()
    qtbot.addWidget(screen)
    row = screen._rows[0]
    row.edit.setText("7")
    row.edit.submitted.emit()
    assert rating_repo.get_score(row.ost.id, people[0].id) == 7

    row.edit.setText("")
    row.edit.submitted.emit()
    assert rating_repo.get_score(row.ost.id, people[0].id) is None


def test_self_submission_excluded_from_queue(app, qtbot):
    # P0 submits one OST and also rates a second one owned by someone else.
    p0 = people_repo.add_person("P0")
    other = people_repo.add_person("Zubmitter")
    own = ost_repo.add_ost("Own Pick", "Game", p0.id)          # self row for P0
    ost_repo.add_ost("Other Pick", "Game", other.id)            # rateable for P0

    from ost_tracker.ui.archive.bulk_entry import BulkEntryScreen

    screen = BulkEntryScreen()
    qtbot.addWidget(screen)
    # P0 is selected first. Both OSTs render, but only the non-self one is active.
    assert len(screen._rows) == 2
    assert len(screen._active_rows) == 1
    self_rows = [r for r in screen._rows if r.is_self]
    assert len(self_rows) == 1 and self_rows[0].ost.id == own
    assert self_rows[0].edit is None            # no editable field on a self row
    assert "1 own submission" in screen.progress_label.text()
    # Progress counts only the rateable row.
    assert "0/1 rated" in screen.progress_label.text()


def test_progress_readout(app, qtbot):
    people, osts = _seed(n_people=1, n_osts=3)
    from ost_tracker.ui.archive.bulk_entry import BulkEntryScreen

    screen = BulkEntryScreen()
    qtbot.addWidget(screen)
    assert "0/3 rated" in screen.progress_label.text()
    screen._rows[0].edit.setText("6")
    screen._rows[0].edit.submitted.emit()
    assert "1/3 rated" in screen.progress_label.text()
