"""Prior-OST history/exclusion list: repo matching, the Add OST warning
(warn-not-block), and the History screen CRUD."""

from __future__ import annotations

import pytest

from ost_tracker.db import history_repo, ost_repo

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


# --- repo -------------------------------------------------------------------

def test_history_crud(fresh_db):
    e = history_repo.add_entry("Snake Eater", "MGS3")
    assert history_repo.get_entry(e.id).source == "MGS3"
    history_repo.update_entry(e.id, "Snake Eater (Vocal)", "MGS3")
    assert history_repo.get_entry(e.id).title == "Snake Eater (Vocal)"
    history_repo.delete_entry(e.id)
    assert history_repo.get_entry(e.id) is None


def test_find_matches_is_case_and_space_insensitive(fresh_db):
    history_repo.add_entry("Snake Eater", "MGS3")
    assert len(history_repo.find_matches("snake eater")) == 1
    assert len(history_repo.find_matches("  SNAKE EATER  ")) == 1
    assert history_repo.find_matches("Aerith's Theme") == []
    assert history_repo.find_matches("   ") == []


# --- Add OST warning --------------------------------------------------------

@pytest.fixture()
def _no_network(monkeypatch):
    # Prevent the background cover fetch from doing real network in tests.
    from ost_tracker.ui.cover_worker import CoverService
    monkeypatch.setattr(CoverService, "fetch", lambda self, *a, **k: None)


def test_add_ost_warns_and_can_cancel(app, qtbot, monkeypatch, _no_network):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    history_repo.add_entry("Snake Eater", "MGS3")
    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.No)

    dialog = AddOstDialog(prefill_title="snake eater")  # different case
    qtbot.addWidget(dialog)
    dialog._save()
    assert dialog.created_ost_id is None          # cancelled
    assert ost_repo.count_osts() == 0


def test_add_ost_warns_but_can_proceed(app, qtbot, monkeypatch, _no_network):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    history_repo.add_entry("Snake Eater", "MGS3")
    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)

    dialog = AddOstDialog(prefill_title="Snake Eater")
    qtbot.addWidget(dialog)
    dialog._save()
    assert dialog.created_ost_id is not None      # proceeded despite warning
    assert ost_repo.count_osts() == 1


def test_add_ost_no_warning_when_not_in_history(app, qtbot, monkeypatch, _no_network):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    history_repo.add_entry("Snake Eater", "MGS3")
    # question() must NOT be called for a non-matching title.
    called = {"n": 0}
    monkeypatch.setattr(QMessageBox, "question",
                        lambda *a, **k: called.__setitem__("n", called["n"] + 1) or QMessageBox.Yes)

    dialog = AddOstDialog(prefill_title="Aerith's Theme")
    qtbot.addWidget(dialog)
    dialog._save()
    assert called["n"] == 0
    assert ost_repo.count_osts() == 1


# --- History screen ---------------------------------------------------------

def test_history_screen_add_and_delete(app, qtbot, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.history_view import HistoryScreen

    screen = HistoryScreen()
    qtbot.addWidget(screen)
    screen._new_entry()
    screen.title_edit.setText("Baba Yetu")
    screen.source_edit.setText("Civ IV")
    screen._save()
    assert history_repo.count_history() == 1
    assert history_repo.list_history()[0].source == "Civ IV"

    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)
    screen._delete()
    assert history_repo.count_history() == 0
