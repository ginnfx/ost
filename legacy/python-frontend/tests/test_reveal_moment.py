"""The reveal fires exactly once, the instant scores become visible."""

from __future__ import annotations

import pytest

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.ui.signals import bus

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


def test_reveal_celebration_fires_once_on_completion(app, qtbot, monkeypatch):
    # Count celebrations without popping a modal.
    calls = {"n": 0}
    from ost_tracker.ui import reveal_dialog

    monkeypatch.setattr(reveal_dialog.RevealDialog, "exec", lambda self: calls.__setitem__("n", calls["n"] + 1))

    person = people_repo.add_person("Solo")
    # No submitter, so the single cell isn't auto-filled by a self-rating; the
    # grid is genuinely 0/1 until Solo rates it below.
    oid = ost_repo.add_ost("Song", "Game", None)

    from ost_tracker.ui.main_window import MainWindow

    win = MainWindow()
    qtbot.addWidget(win)
    assert win._reveal_seen is False  # 0/1 rated at construction

    # Completing the only cell makes scores visible -> celebrate once.
    rating_repo.upsert_rating(oid, person.id, 8)
    bus().ratings_changed.emit()
    assert win._reveal_seen is True
    assert calls["n"] == 1

    # Further changes don't re-celebrate.
    bus().ratings_changed.emit()
    assert calls["n"] == 1


def test_no_celebration_when_already_revealed_at_launch(app, qtbot, monkeypatch):
    calls = {"n": 0}
    from ost_tracker.ui import reveal_dialog

    monkeypatch.setattr(reveal_dialog.RevealDialog, "exec", lambda self: calls.__setitem__("n", calls["n"] + 1))

    person = people_repo.add_person("Solo")
    oid = ost_repo.add_ost("Song", "Game", person.id)
    rating_repo.upsert_rating(oid, person.id, 8)  # already complete

    from ost_tracker.ui.main_window import MainWindow

    win = MainWindow()
    qtbot.addWidget(win)
    assert win._reveal_seen is True
    bus().ratings_changed.emit()
    assert calls["n"] == 0  # nothing to celebrate; it was already revealed
