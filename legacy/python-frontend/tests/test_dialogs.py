"""Edit dialog, settings (people) dialog, and ScoreEdit key handling."""

from __future__ import annotations

import pytest

from ost_tracker.db import ost_repo, people_repo

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


# --- EditOstDialog ----------------------------------------------------------

def test_edit_ost_dialog_saves_changes(app, qtbot):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    oid = ost_repo.add_ost("Old", "OldSrc", alice.id, None)
    ost = ost_repo.get_ost(oid)

    from ost_tracker.ui.edit_ost_dialog import EditOstDialog

    dialog = EditOstDialog(ost)
    qtbot.addWidget(dialog)
    dialog.title_edit.setText("New Title")
    dialog.source_edit.setText("NewSrc")
    idx = dialog.submitter_combo.findData(bob.id)
    dialog.submitter_combo.setCurrentIndex(idx)
    dialog.link_edit.setText("https://example.com")
    dialog._save()

    updated = ost_repo.get_ost(oid)
    assert updated.title == "New Title"
    assert updated.source == "NewSrc"
    assert updated.submitter_id == bob.id
    assert updated.external_link == "https://example.com"


def test_edit_ost_dialog_rejects_empty_title(app, qtbot, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    monkeypatch.setattr(QMessageBox, "warning", lambda *a, **k: None)

    oid = ost_repo.add_ost("Keep", "Src", None)
    from ost_tracker.ui.edit_ost_dialog import EditOstDialog

    dialog = EditOstDialog(ost_repo.get_ost(oid))
    qtbot.addWidget(dialog)
    dialog.title_edit.setText("   ")
    dialog._save()
    assert ost_repo.get_ost(oid).title == "Keep"  # unchanged


# --- PeopleScreen -----------------------------------------------------------

def test_people_screen_inline_add_rename_delete(app, qtbot):
    from ost_tracker.ui.people_view import PeopleScreen

    screen = PeopleScreen()
    qtbot.addWidget(screen)

    # Empty roster → the inline add row is already revealed, in the list.
    assert not screen.add_row.isHidden()

    # Inline add: type + Enter (no form, no Save). The input stays open and
    # cleared so seeding the roster is a run of quick adds.
    screen.add_edit.setText("Alice")
    screen._commit_add()
    assert [p.name for p in people_repo.list_people()] == ["Alice"]
    assert screen.add_edit.text() == ""

    # Click-to-edit rename directly in the row — no Save button anywhere.
    row = next(iter(screen._rows.values()))
    row.start_rename()
    row.name_edit.setText("Alicia")
    row._commit_rename()
    assert people_repo.list_people()[0].name == "Alicia"
    assert people_repo.count_people() == 1  # renamed, not duplicated

    # Bare delete: first click arms the row, second click removes.
    row._on_delete_clicked()
    assert row._armed
    row._on_delete_clicked()
    assert people_repo.count_people() == 0


def test_people_armed_delete_shows_cascade_impact(app, qtbot):
    from ost_tracker.db import ost_repo, rating_repo
    from ost_tracker.ui.people_view import PeopleScreen

    alice = people_repo.add_person("Alice")
    oid = ost_repo.add_ost("Song", "Game", alice.id)
    rating_repo.upsert_rating(oid, alice.id, 7)

    screen = PeopleScreen()
    qtbot.addWidget(screen)
    row = screen._rows[alice.id]

    # Arming spells out the cascade inline before the confirming click.
    row._on_delete_clicked()
    assert "rating" in row.impact.text()
    assert "OST" in row.impact.text()

    row._on_delete_clicked()
    assert people_repo.count_people() == 0
    # OST survives but loses its submitter; its rating cascaded away.
    assert ost_repo.get_ost(oid).submitter_id is None
    assert rating_repo.total_ratings() == 0


def test_people_rows_carry_leniency_readout(app, qtbot):
    """Per-rater leniency relocated from the retired Stats tab (§3 option b)."""
    from ost_tracker.db import ost_repo, rating_repo
    from ost_tracker.ui.people_view import PeopleScreen

    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    oid = ost_repo.add_ost("Song", "Game", None)
    rating_repo.upsert_rating(oid, alice.id, 8)

    screen = PeopleScreen()
    qtbot.addWidget(screen)
    assert "8.00" in screen._rows[alice.id].leniency.text()
    assert "no ratings yet" in screen._rows[bob.id].leniency.text()

    # Live update: a new rating elsewhere refreshes the readout via the bus.
    rating_repo.upsert_rating(oid, bob.id, 4)
    from ost_tracker.ui.signals import bus

    bus().ratings_changed.emit()
    assert "4.00" in screen._rows[bob.id].leniency.text()


# --- ScoreEdit key handling -------------------------------------------------

def test_score_edit_enter_and_arrows(app, qtbot):
    from PySide6.QtCore import Qt
    from ost_tracker.ui.score_edit import ScoreEdit

    edit = ScoreEdit()
    qtbot.addWidget(edit)
    fired = {"submitted": 0, "up": 0, "down": 0, "left": 0, "right": 0}
    edit.submitted.connect(lambda: fired.__setitem__("submitted", fired["submitted"] + 1))
    edit.go_up.connect(lambda: fired.__setitem__("up", fired["up"] + 1))
    edit.go_down.connect(lambda: fired.__setitem__("down", fired["down"] + 1))
    edit.go_left.connect(lambda: fired.__setitem__("left", fired["left"] + 1))
    edit.go_right.connect(lambda: fired.__setitem__("right", fired["right"] + 1))

    qtbot.keyClick(edit, Qt.Key_Return)
    qtbot.keyClick(edit, Qt.Key_Up)
    qtbot.keyClick(edit, Qt.Key_Down)

    edit.setText("5")
    edit.setCursorPosition(0)
    qtbot.keyClick(edit, Qt.Key_Left)   # at start -> go_left
    edit.setCursorPosition(1)
    qtbot.keyClick(edit, Qt.Key_Right)  # at end -> go_right

    assert fired == {"submitted": 1, "up": 1, "down": 1, "left": 1, "right": 1}


def test_score_edit_left_in_middle_moves_cursor_not_cell(app, qtbot):
    from PySide6.QtCore import Qt
    from ost_tracker.ui.score_edit import ScoreEdit

    edit = ScoreEdit()
    qtbot.addWidget(edit)
    left_fired = {"n": 0}
    edit.go_left.connect(lambda: left_fired.__setitem__("n", left_fired["n"] + 1))
    edit.setText("10")
    edit.setCursorPosition(1)  # middle of "10"
    qtbot.keyClick(edit, Qt.Key_Left)
    assert left_fired["n"] == 0  # stayed within the field
