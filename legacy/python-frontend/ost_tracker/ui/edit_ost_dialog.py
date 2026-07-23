"""Edit an existing OST's title / source / submitter / external link.

Kept separate from AddOstDialog because editing must not re-trigger the cover
fetch (the cover has its own override/re-fetch controls in the detail view).
"""

from __future__ import annotations

from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo
from ost_tracker.db.models import Ost
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import attach_source_completer


class EditOstDialog(QDialog):
    def __init__(self, ost: Ost, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost = ost
        self.setWindowTitle("Edit OST")
        self.setMinimumWidth(440)

        root = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(10)

        self.title_edit = QLineEdit(ost.title)
        form.addRow("Title", self.title_edit)

        self.source_edit = QLineEdit(ost.source or "")
        attach_source_completer(self.source_edit)
        form.addRow("Source", self.source_edit)

        self.submitter_combo = QComboBox()
        self.submitter_combo.addItem("(no submitter)", None)
        for person in people_repo.list_people():
            self.submitter_combo.addItem(person.name, person.id)
        idx = self.submitter_combo.findData(ost.submitter_id)
        self.submitter_combo.setCurrentIndex(idx if idx >= 0 else 0)
        form.addRow("Submitted by", self.submitter_combo)

        self.link_edit = QLineEdit(ost.external_link or "")
        self.link_edit.setPlaceholderText("Optional YouTube/Spotify URL")
        form.addRow("External link", self.link_edit)

        root.addLayout(form)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _save(self) -> None:
        title = self.title_edit.text().strip()
        if not title:
            QMessageBox.warning(self, "Title required", "Please enter a title.")
            return
        ost_repo.update_ost(
            self._ost.id,
            title=title,
            source=self.source_edit.text().strip() or None,
            submitter_id=self.submitter_combo.currentData(),
            external_link=self.link_edit.text().strip() or None,
        )
        bus().osts_changed.emit()
        self.accept()
