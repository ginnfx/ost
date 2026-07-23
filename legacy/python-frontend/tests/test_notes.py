"""Notes scratchpad: CRUD via the editor, and promote-to-OST which pre-fills
the Add dialog without deleting or duplicating the note."""

from __future__ import annotations

import pytest

from ost_tracker.db import notes_repo, ost_repo, people_repo
from ost_tracker.ui.signals import bus

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


def test_add_and_edit_note(app, qtbot):
    from ost_tracker.ui.notes_view import NotesScreen

    screen = NotesScreen()
    qtbot.addWidget(screen)
    screen._new_note()
    screen.title_edit.setText("Maybe this one")
    screen.body_edit.setPlainText("great boss theme")
    screen._save()

    notes = notes_repo.list_notes()
    assert len(notes) == 1 and notes[0].title == "Maybe this one"

    screen.title_edit.setText("Definitely this one")
    screen._save()
    assert notes_repo.list_notes()[0].title == "Definitely this one"
    assert len(notes_repo.list_notes()) == 1  # edited, not duplicated


def test_promote_prefills_dialog_without_touching_note(app, qtbot):
    from ost_tracker.ui.notes_view import NotesScreen

    screen = NotesScreen()
    qtbot.addWidget(screen)
    screen._new_note()
    screen.title_edit.setText("Snake Eater")
    screen.body_edit.setPlainText("MGS3 ending")
    screen._save()

    captured = {}
    bus().open_add_ost_requested.connect(
        lambda t, n, sid: captured.update(title=t, note=n)
    )
    screen._promote()

    assert captured == {"title": "Snake Eater", "note": "MGS3 ending"}
    # The note survives promotion (no auto-delete, no duplication).
    assert len(notes_repo.list_notes()) == 1

    # And simulating the resulting OST creation doesn't disturb the note.
    people_repo.add_person("Alice")
    ost_repo.add_ost("Snake Eater", "MGS3", None)
    assert len(notes_repo.list_notes()) == 1
    assert ost_repo.count_osts() == 1


def test_delete_note(app, qtbot, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.notes_view import NotesScreen

    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)
    screen = NotesScreen()
    qtbot.addWidget(screen)
    screen._new_note()
    screen.title_edit.setText("Doomed idea")
    screen._save()
    assert len(notes_repo.list_notes()) == 1

    screen._delete()
    assert len(notes_repo.list_notes()) == 0
