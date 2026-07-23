"""Notes scratchpad (screen 10).

A private staging area for OST ideas you're still mulling, backed by the isolated
``notes`` table — nothing here touches rankings, stats, or exports. Each note can
be *promoted*: it opens the Add OST dialog pre-filled with the note's title (and
shows the body for reference), turning a settled idea into a real submission
without retyping. Promoting never deletes the note; you remove it yourself once
you're sure.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QSplitter,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import notes_repo
from ost_tracker.ui import icons, theme
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import TitleBlock, danger_button, ghost_button, primary_button


class NotesScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._current_id: Optional[int] = None
        self._build_ui()
        self._reload_list()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM
        )
        root.setSpacing(theme.HEADER_GAP)

        header = QHBoxLayout()
        header.addWidget(TitleBlock("Notes", "Scratchpad — separate from the competition", "fa5s.sticky-note"))
        header.addStretch(1)
        new_btn = primary_button(" New note", icons.add())
        new_btn.clicked.connect(self._new_note)
        header.addWidget(new_btn)
        root.addLayout(header)

        splitter = QSplitter(Qt.Horizontal)

        self.list = QListWidget()
        self.list.setMinimumWidth(220)
        self.list.currentItemChanged.connect(self._on_selection_changed)
        splitter.addWidget(self.list)

        editor = QWidget()
        ed_layout = QVBoxLayout(editor)
        ed_layout.setContentsMargins(12, 0, 0, 0)
        self.title_edit = QLineEdit()
        self.title_edit.setPlaceholderText("Note title")
        ed_layout.addWidget(self.title_edit)
        self.body_edit = QTextEdit()
        self.body_edit.setPlaceholderText("Freeform notes — why this OST, timestamps, doubts…")
        ed_layout.addWidget(self.body_edit, 1)

        buttons = QHBoxLayout()
        save_btn = ghost_button(" Save", icons.edit())
        save_btn.clicked.connect(self._save)
        promote_btn = primary_button(" Promote to OST", icons.trophy())
        promote_btn.clicked.connect(self._promote)
        delete_btn = danger_button(" Delete", icons.delete())
        delete_btn.clicked.connect(self._delete)
        buttons.addWidget(promote_btn)
        buttons.addWidget(save_btn)
        buttons.addStretch(1)
        buttons.addWidget(delete_btn)
        ed_layout.addLayout(buttons)

        splitter.addWidget(editor)
        splitter.setStretchFactor(1, 1)
        root.addWidget(splitter, 1)

        self.empty_hint = QLabel("No notes yet — jot down an idea with “New note”.")
        self.empty_hint.setStyleSheet(f"color:{theme.TEXT_DIM};")
        self.empty_hint.setAlignment(Qt.AlignCenter)
        root.addWidget(self.empty_hint)

    # --- data ---------------------------------------------------------------

    def _reload_list(self, select_id: Optional[int] = None) -> None:
        self.list.blockSignals(True)
        self.list.clear()
        notes = notes_repo.list_notes()
        for note in notes:
            item = QListWidgetItem(note.title)
            item.setData(Qt.UserRole, note.id)
            self.list.addItem(item)
        self.list.blockSignals(False)

        self.empty_hint.setVisible(not notes)
        if not notes:
            self._new_note()
            return

        target = select_id if select_id is not None else notes[0].id
        self._select_in_list(target)

    def _select_in_list(self, note_id: int) -> None:
        for i in range(self.list.count()):
            if self.list.item(i).data(Qt.UserRole) == note_id:
                self.list.setCurrentRow(i)
                return
        # Not found — load first.
        if self.list.count():
            self.list.setCurrentRow(0)

    def _on_selection_changed(self, current: QListWidgetItem, _previous) -> None:
        if current is None:
            return
        self._load_note(current.data(Qt.UserRole))

    def _load_note(self, note_id: int) -> None:
        note = notes_repo.get_note(note_id)
        if note is None:
            return
        self._current_id = note.id
        self.title_edit.setText(note.title)
        self.body_edit.setPlainText(note.note)

    def _new_note(self) -> None:
        self._current_id = None
        self.title_edit.clear()
        self.body_edit.clear()
        self.title_edit.setFocus()

    # --- actions ------------------------------------------------------------

    def _save(self) -> None:
        title = self.title_edit.text().strip()
        if not title:
            QMessageBox.warning(self, "Title required", "Give the note a title.")
            self.title_edit.setFocus()
            return
        body = self.body_edit.toPlainText()
        if self._current_id is None:
            note = notes_repo.add_note(title, body)
            self._current_id = note.id
        else:
            notes_repo.update_note(self._current_id, title, body)
        bus().notes_changed.emit()
        self._reload_list(select_id=self._current_id)

    def _delete(self) -> None:
        if self._current_id is None:
            self._new_note()
            return
        note = notes_repo.get_note(self._current_id)
        confirm = QMessageBox.question(
            self,
            "Delete note?",
            f"Delete “{note.title}”?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm == QMessageBox.Yes:
            notes_repo.delete_note(self._current_id)
            self._current_id = None
            bus().notes_changed.emit()
            self._reload_list()

    def _promote(self) -> None:
        title = self.title_edit.text().strip()
        if not title:
            QMessageBox.information(
                self, "Nothing to promote", "Add a title first, then promote it to an OST."
            )
            return
        body = self.body_edit.toPlainText()
        # Opens the Add OST dialog pre-filled. The note is deliberately left in
        # place — delete it yourself once the submission is settled.
        bus().open_add_ost_requested.emit(title, body, None)
