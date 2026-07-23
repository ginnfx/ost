"""Matrix-entry (by submitter) behaviour: grid shape, upsert-on-change parity
with bulk entry, incomplete-row detection, and arrow navigation clamping."""

from __future__ import annotations

import pytest

from ost_tracker.db import ost_repo, people_repo, rating_repo

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


def _seed(n_people=3, n_osts=2):
    people = [people_repo.add_person(f"P{i}") for i in range(n_people)]
    # First person submits all the OSTs so the matrix has rows.
    osts = [ost_repo.add_ost(f"OST {i}", "Game", people[0].id) for i in range(n_osts)]
    return people, osts


def test_matrix_shape_matches_osts_by_raters(app, qtbot):
    people, osts = _seed(n_people=3, n_osts=2)
    from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen

    screen = MatrixEntryScreen()
    qtbot.addWidget(screen)
    # Submitter P0 is selected first; they submitted 2 OSTs.
    assert len(screen._cells) == 2
    assert all(len(row) == 3 for row in screen._cells)


def test_cell_save_upserts(app, qtbot):
    people, osts = _seed(n_people=3, n_osts=2)
    from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen

    screen = MatrixEntryScreen()
    qtbot.addWidget(screen)
    # P0 is the submitter (column 0 = self), so baseline is P0's 2 self-ratings.
    base = rating_repo.total_ratings()
    screen._cells[0][1].setText("9")
    screen._save_cell(0, 1)
    assert rating_repo.get_score(screen._osts[0].id, screen._people[1].id) == 9

    # Correcting re-uses the same upsert (no duplicate row).
    screen._cells[0][1].setText("4")
    screen._save_cell(0, 1)
    assert rating_repo.get_score(screen._osts[0].id, screen._people[1].id) == 4
    assert rating_repo.total_ratings() == base + 1


def test_clearing_cell_deletes(app, qtbot):
    people, osts = _seed(n_people=2, n_osts=1)
    from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen

    screen = MatrixEntryScreen()
    qtbot.addWidget(screen)
    # Column 0 is P0's self column; edit the rater column (1) instead.
    base = rating_repo.total_ratings()  # P0's self-rating on the one OST
    screen._cells[0][1].setText("5")
    screen._save_cell(0, 1)
    assert rating_repo.total_ratings() == base + 1
    screen._cells[0][1].setText("")
    screen._save_cell(0, 1)
    assert rating_repo.total_ratings() == base  # self-rating survives


def test_row_tint_reflects_completeness(app, qtbot):
    people, osts = _seed(n_people=2, n_osts=1)
    from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen
    from ost_tracker.ui import theme

    screen = MatrixEntryScreen()
    qtbot.addWidget(screen)
    # Column 0 (P0) is the auto-filled self column; column 1 (P1) starts empty,
    # so the row is initially incomplete -> tinted.
    assert theme.INCOMPLETE_TINT in screen._row_frames[0].styleSheet()
    # Filling the only rater cell completes the row -> no tint.
    screen._cells[0][1].setText("7")
    screen._save_cell(0, 1)
    assert theme.INCOMPLETE_TINT not in screen._row_frames[0].styleSheet()


def test_self_column_is_locked_and_skipped(app, qtbot):
    people, osts = _seed(n_people=3, n_osts=1)  # P0 submits -> column 0 is self
    from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen

    screen = MatrixEntryScreen()
    qtbot.addWidget(screen)
    assert screen._self_col == 0
    self_cell = screen._cells[0][0]
    assert self_cell.isReadOnly()

    # Saving the self cell never overwrites the auto self-rating.
    before = rating_repo.get_score(screen._osts[0].id, screen._people[0].id)
    self_cell.setText("3")
    screen._save_cell(0, 0)
    assert rating_repo.get_score(screen._osts[0].id, screen._people[0].id) == before

    # Navigation resolves the self column to the nearest editable one.
    assert screen._nearest_editable_col(0) == 1


def test_arrow_navigation_clamps(app, qtbot):
    people, osts = _seed(n_people=3, n_osts=2)
    from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen

    screen = MatrixEntryScreen()
    qtbot.addWidget(screen)
    # Should not raise when navigating out of bounds.
    screen._move(-5, -5)
    screen._move(100, 100)
