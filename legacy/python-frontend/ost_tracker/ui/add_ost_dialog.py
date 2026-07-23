"""Add OST dialog (Phase 4).

Collects title / source / submitter (+ optional external link), inserts the row,
then kicks off the cover-art fetch on a background thread so the UI never
blocks. The grid refreshes immediately (showing a placeholder) and again when
the cover arrives. Can be opened pre-filled from the Notes "promote to OST" flow.
"""

from __future__ import annotations

from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import history_repo, ost_repo, people_repo
from ost_tracker.ui import theme
from ost_tracker.ui.cover_worker import cover_service
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import attach_source_completer


class AddOstDialog(QDialog):
    def __init__(
        self,
        parent: QWidget | None = None,
        prefill_title: str = "",
        prefill_note: str = "",
        prefill_submitter_id: int | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Add OST")
        self.setMinimumWidth(440)
        self._created_ost_id: int | None = None

        root = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(10)

        self.title_edit = QLineEdit(prefill_title)
        self.title_edit.setPlaceholderText("e.g. Aerith's Theme")
        form.addRow("Title", self.title_edit)

        self.source_edit = QLineEdit()
        self.source_edit.setPlaceholderText("Game / anime / media it's from")
        attach_source_completer(self.source_edit)
        form.addRow("Source", self.source_edit)

        self.submitter_combo = QComboBox()
        self.submitter_combo.addItem("(no submitter)", None)
        for person in people_repo.list_people():
            self.submitter_combo.addItem(person.name, person.id)
        # A caller with an active submitter context (e.g. the Leaderboard's
        # filter) pre-assigns that person; otherwise default to the first.
        prefill_idx = (
            self.submitter_combo.findData(prefill_submitter_id)
            if prefill_submitter_id is not None
            else -1
        )
        if prefill_idx >= 0:
            self.submitter_combo.setCurrentIndex(prefill_idx)
        elif self.submitter_combo.count() > 1:
            self.submitter_combo.setCurrentIndex(1)
        form.addRow("Submitted by", self.submitter_combo)

        self.link_edit = QLineEdit()
        self.link_edit.setPlaceholderText("Optional YouTube/Spotify URL")
        form.addRow("External link", self.link_edit)

        root.addLayout(form)

        if prefill_note.strip():
            note_label = QLabel(f"From your note:\n{prefill_note.strip()}")
            note_label.setWordWrap(True)
            note_label.setStyleSheet(
                f"color: {theme.TEXT_DIM}; background: {theme.SURFACE_RAISED};"
                f" border-radius: 8px; padding: 8px;"
            )
            root.addWidget(note_label)

        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Save).setText("Add OST")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

        self.title_edit.setFocus()

    @property
    def created_ost_id(self) -> int | None:
        return self._created_ost_id

    def _save(self) -> None:
        title = self.title_edit.text().strip()
        if not title:
            QMessageBox.warning(self, "Title required", "Please enter a title for the OST.")
            self.title_edit.setFocus()
            return

        # Warn (don't block) if this OST was used in a previous competition.
        matches = history_repo.find_matches(title)
        if matches:
            details = "\n".join(
                "• " + m.title + (f"  ({m.source})" if m.source else "") for m in matches
            )
            confirm = QMessageBox.question(
                self,
                "Used before",
                f"“{title}” is in your history of previously-used OSTs:\n\n{details}\n\n"
                f"Add it to this competition anyway?",
                QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No,
            )
            if confirm != QMessageBox.Yes:
                self.title_edit.setFocus()
                return

        source = self.source_edit.text().strip() or None
        submitter_id = self.submitter_combo.currentData()
        link = self.link_edit.text().strip() or None

        ost_id = ost_repo.add_ost(title, source, submitter_id, link)
        self._created_ost_id = ost_id
        bus().osts_changed.emit()  # grid shows the card (placeholder) immediately

        # Fetch cover art in the background; the grid updates when it lands.
        cover_service().fetch(ost_id, title, source)

        self.accept()
