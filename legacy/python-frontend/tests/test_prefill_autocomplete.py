"""Item 5: submitter pre-fill from the active filter, source autocomplete."""

from __future__ import annotations

import pytest

pytest.importorskip("pytestqt")

from ost_tracker.db import ost_repo, people_repo


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication

    return QApplication.instance()


# --- submitter pre-fill -------------------------------------------------------

def test_add_dialog_prefills_given_submitter(app, qtbot):
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob").id
    dlg = AddOstDialog(prefill_submitter_id=bob)
    qtbot.addWidget(dlg)
    assert dlg.submitter_combo.currentData() == bob


def test_add_dialog_defaults_to_first_person_without_prefill(app, qtbot):
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    alice = people_repo.add_person("Alice").id
    people_repo.add_person("Bob")
    dlg = AddOstDialog()
    qtbot.addWidget(dlg)
    assert dlg.submitter_combo.currentData() == alice


def test_add_dialog_ignores_unknown_prefill_id(app, qtbot):
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    alice = people_repo.add_person("Alice").id
    dlg = AddOstDialog(prefill_submitter_id=424242)
    qtbot.addWidget(dlg)
    assert dlg.submitter_combo.currentData() == alice


def test_grid_add_button_passes_active_submitter_filter(app, qtbot):
    from ost_tracker.ui.grid_view import GridView
    from ost_tracker.ui.signals import bus

    people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob").id
    grid = GridView()
    qtbot.addWidget(grid)
    grid.submitter_combo.setCurrentIndex(grid.submitter_combo.findData(bob))

    captured = []
    bus().open_add_ost_requested.connect(lambda t, n, sid: captured.append(sid))
    grid.add_button.click()
    assert captured == [bob]


def test_grid_add_button_passes_none_for_all_submitters(app, qtbot):
    from ost_tracker.ui.grid_view import GridView
    from ost_tracker.ui.signals import bus

    people_repo.add_person("Alice")
    grid = GridView()
    qtbot.addWidget(grid)

    captured = []
    bus().open_add_ost_requested.connect(lambda t, n, sid: captured.append(sid))
    grid.add_button.click()
    assert captured == [None]


# --- source autocomplete --------------------------------------------------------

def test_list_sources_is_distinct_and_skips_blanks(fresh_db):
    ost_repo.add_ost("A", "Nier")
    ost_repo.add_ost("B", "Nier")
    ost_repo.add_ost("C", "Chrono Trigger")
    ost_repo.add_ost("D", None)
    ost_repo.add_ost("E", "   ")
    assert ost_repo.list_sources() == ["Chrono Trigger", "Nier"]


def test_add_dialog_source_field_has_completer(app, qtbot):
    from PySide6.QtCore import Qt
    from ost_tracker.ui.add_ost_dialog import AddOstDialog

    people_repo.add_person("Alice")
    ost_repo.add_ost("A", "Nier")
    dlg = AddOstDialog()
    qtbot.addWidget(dlg)
    completer = dlg.source_edit.completer()
    assert completer is not None
    assert completer.caseSensitivity() == Qt.CaseInsensitive
    model = completer.model()
    values = [model.index(i, 0).data() for i in range(model.rowCount())]
    assert "Nier" in values


def test_edit_dialog_source_field_has_completer(app, qtbot):
    from ost_tracker.ui.edit_ost_dialog import EditOstDialog

    people_repo.add_person("Alice")
    oid = ost_repo.add_ost("A", "Nier")
    dlg = EditOstDialog(ost_repo.get_ost(oid))
    qtbot.addWidget(dlg)
    assert dlg.source_edit.completer() is not None
