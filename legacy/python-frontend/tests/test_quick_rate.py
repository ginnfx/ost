"""Quick Rate dialog: single-track score entry from a leaderboard card."""

from __future__ import annotations

import pytest

pytest.importorskip("pytestqt")

from ost_tracker.config import SELF_RATING_SCORE
from ost_tracker.db import ost_repo, people_repo, rating_repo


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication

    return QApplication.instance()


@pytest.fixture()
def seeded(app):
    """Three people; Alice submitted one OST."""
    alice = people_repo.add_person("Alice").id
    bob = people_repo.add_person("Bob").id
    cara = people_repo.add_person("Cara").id
    ost_id = ost_repo.add_ost("Main Theme", "Some Game", alice)
    return {"alice": alice, "bob": bob, "cara": cara, "ost_id": ost_id}


def _dialog(seeded, qtbot):
    from ost_tracker.ui.quick_rate_dialog import QuickRateDialog

    dlg = QuickRateDialog(seeded["ost_id"])
    qtbot.addWidget(dlg)
    return dlg


def test_one_cell_per_person(seeded, qtbot):
    dlg = _dialog(seeded, qtbot)
    assert len(dlg._cells) == 3


def test_submitter_cell_is_locked_and_prefilled(seeded, qtbot):
    dlg = _dialog(seeded, qtbot)
    self_cell = dlg._cells[dlg._self_col]
    assert self_cell.isReadOnly()
    assert self_cell.text() == str(SELF_RATING_SCORE)


def test_entering_a_score_upserts(seeded, qtbot):
    dlg = _dialog(seeded, qtbot)
    bob_col = next(i for i, p in enumerate(dlg._people) if p.id == seeded["bob"])
    dlg._cells[bob_col].setText("7")
    dlg._save_cell(bob_col)
    assert rating_repo.get_score(seeded["ost_id"], seeded["bob"]) == 7


def test_correcting_a_score_updates_in_place(seeded, qtbot):
    rating_repo.upsert_rating(seeded["ost_id"], seeded["bob"], 4)
    dlg = _dialog(seeded, qtbot)
    bob_col = next(i for i, p in enumerate(dlg._people) if p.id == seeded["bob"])
    assert dlg._cells[bob_col].text() == "4"  # existing score pre-filled
    dlg._cells[bob_col].setText("9")
    dlg._save_cell(bob_col)
    assert rating_repo.get_score(seeded["ost_id"], seeded["bob"]) == 9


def test_clearing_a_cell_deletes_the_rating(seeded, qtbot):
    rating_repo.upsert_rating(seeded["ost_id"], seeded["bob"], 4)
    dlg = _dialog(seeded, qtbot)
    bob_col = next(i for i, p in enumerate(dlg._people) if p.id == seeded["bob"])
    dlg._cells[bob_col].setText("")
    dlg._save_cell(bob_col)
    assert rating_repo.get_score(seeded["ost_id"], seeded["bob"]) is None


def test_unchanged_cell_emits_no_ratings_signal(seeded, qtbot):
    from ost_tracker.ui.signals import bus

    rating_repo.upsert_rating(seeded["ost_id"], seeded["bob"], 4)
    dlg = _dialog(seeded, qtbot)
    bob_col = next(i for i, p in enumerate(dlg._people) if p.id == seeded["bob"])
    fired = []
    bus().ratings_changed.connect(lambda: fired.append(1))
    dlg._save_cell(bob_col)  # value still 4 — must be a no-op
    assert not fired


def test_save_never_writes_the_self_column(seeded, qtbot):
    dlg = _dialog(seeded, qtbot)
    dlg._save_cell(dlg._self_col)
    assert rating_repo.get_score(seeded["ost_id"], seeded["alice"]) == SELF_RATING_SCORE


def test_enter_on_last_cell_closes_the_dialog(seeded, qtbot):
    dlg = _dialog(seeded, qtbot)
    editable = [c for c in range(len(dlg._cells)) if c != dlg._self_col]
    last = editable[-1]
    dlg._cells[last].setText("8")
    dlg._on_enter(last)
    assert dlg.result() == 1  # accepted
    assert rating_repo.get_score(seeded["ost_id"], dlg._people[last].id) == 8


def test_arrows_hop_over_the_locked_self_column(seeded, qtbot):
    dlg = _dialog(seeded, qtbot)
    dlg.show()
    # Alice (submitter) is column 0 alphabetically; from Bob's cell, moving
    # right lands on Cara, and moving back left from Cara returns to Bob —
    # never onto the locked cell.
    assert dlg._self_col == 0
    dlg._move_horizontal(1, +1)
    assert dlg.focusWidget() is dlg._cells[2]
    dlg._move_horizontal(2, -1)
    assert dlg.focusWidget() is dlg._cells[1]
    dlg._move_horizontal(1, -1)  # nothing editable further left; stays put
    assert dlg.focusWidget() is dlg._cells[1]


def test_full_details_button_requests_detail_view(seeded, qtbot):
    from ost_tracker.ui.signals import bus

    dlg = _dialog(seeded, qtbot)
    opened = []
    bus().open_detail_requested.connect(opened.append)
    dlg._open_details()
    assert opened == [seeded["ost_id"]]
    assert dlg.result() == 1


def test_card_click_opens_quick_rate(seeded, qtbot, monkeypatch):
    from ost_tracker.ui import quick_rate_dialog
    from ost_tracker.ui.grid_view import GridView

    opened = []
    monkeypatch.setattr(
        quick_rate_dialog.QuickRateDialog,
        "exec",
        lambda self: opened.append(self._ost.id),
    )
    grid = GridView()
    qtbot.addWidget(grid)
    card = grid._cards[seeded["ost_id"]]
    card.clicked.emit(seeded["ost_id"])
    assert opened == [seeded["ost_id"]]


def test_grid_search_and_filter_survive_a_quick_rate(seeded, qtbot):
    """Item 2's state guarantee: rating through the dialog must not reset the
    Leaderboard's search text or submitter filter."""
    from ost_tracker.ui.grid_view import GridView

    grid = GridView()
    qtbot.addWidget(grid)
    grid.search_edit.setText("Main")
    alice_idx = grid.submitter_combo.findData(seeded["alice"])
    grid.submitter_combo.setCurrentIndex(alice_idx)

    dlg = _dialog(seeded, qtbot)
    bob_col = next(i for i, p in enumerate(dlg._people) if p.id == seeded["bob"])
    dlg._cells[bob_col].setText("6")
    dlg._save_cell(bob_col)  # emits ratings_changed -> grid refresh
    dlg.accept()

    assert grid.search_edit.text() == "Main"
    assert grid.submitter_combo.currentData() == seeded["alice"]
    assert seeded["ost_id"] in grid._cards


def test_dialog_survives_deleted_ost(app, qtbot):
    from ost_tracker.ui.quick_rate_dialog import QuickRateDialog

    dlg = QuickRateDialog(99999)
    qtbot.addWidget(dlg)
    assert dlg._ost is None
    assert dlg._cells == []
