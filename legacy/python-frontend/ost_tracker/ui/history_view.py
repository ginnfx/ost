"""History screen (screen: prior-OST exclusion list).

A reference list of OSTs used in previous competitions, so the same track isn't
submitted again across seasons. Modeled on the People/Notes master-detail: a
list on the left, the selected entry's title + franchise on the right, with a
primary "+ Add entry" action. Adding an OST elsewhere checks these titles and
warns on a match (see AddOstDialog) — this screen is purely for curating that
list; it never touches competition data.
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
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import history_repo
from ost_tracker.ui import icons, theme
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import TitleBlock, danger_button, ghost_button, primary_button


class HistoryScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._current_id: Optional[int] = None
        self._build_ui()
        self._reload_list()
        bus().history_changed.connect(self._reload_keep_selection)

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM
        )
        root.setSpacing(theme.HEADER_GAP)

        header = QHBoxLayout()
        header.addWidget(TitleBlock(
            "History", "Previously-used OSTs — you'll be warned before re-adding one", "fa5s.history"))
        header.addStretch(1)
        add_btn = primary_button(" Add entry", icons.add())
        add_btn.clicked.connect(self._new_entry)
        header.addWidget(add_btn)
        root.addLayout(header)

        splitter = QSplitter(Qt.Horizontal)

        self.list = QListWidget()
        self.list.setMinimumWidth(240)
        self.list.setSpacing(2)
        self.list.currentItemChanged.connect(self._on_selection_changed)
        splitter.addWidget(self.list)

        editor = QWidget()
        ed_layout = QVBoxLayout(editor)
        ed_layout.setContentsMargins(theme.HEADER_GAP, 0, 0, 0)
        ed_layout.setSpacing(10)

        title_label = QLabel("OST title")
        title_label.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:11px;")
        ed_layout.addWidget(title_label)
        self.title_edit = QLineEdit()
        self.title_edit.setPlaceholderText("Name of the OST")
        self.title_edit.returnPressed.connect(self._save)
        ed_layout.addWidget(self.title_edit)

        source_label = QLabel("Franchise / source")
        source_label.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:11px;")
        ed_layout.addWidget(source_label)
        self.source_edit = QLineEdit()
        self.source_edit.setPlaceholderText("Game / anime / media (optional)")
        self.source_edit.returnPressed.connect(self._save)
        ed_layout.addWidget(self.source_edit)

        buttons = QHBoxLayout()
        save_btn = ghost_button(" Save", icons.edit())
        save_btn.clicked.connect(self._save)
        delete_btn = danger_button(" Remove", icons.delete())
        delete_btn.clicked.connect(self._delete)
        buttons.addWidget(save_btn)
        buttons.addStretch(1)
        buttons.addWidget(delete_btn)
        ed_layout.addLayout(buttons)
        ed_layout.addStretch(1)

        splitter.addWidget(editor)
        splitter.setStretchFactor(1, 1)
        root.addWidget(splitter, 1)

        self.empty_hint = QLabel("No history yet — add past OSTs so they can't be re-submitted.")
        self.empty_hint.setStyleSheet(f"color:{theme.TEXT_DIM};")
        self.empty_hint.setAlignment(Qt.AlignCenter)
        root.addWidget(self.empty_hint)

    # --- data ---------------------------------------------------------------

    def _reload_keep_selection(self) -> None:
        self._reload_list(select_id=self._current_id)

    def _reload_list(self, select_id: Optional[int] = None) -> None:
        self.list.blockSignals(True)
        self.list.clear()
        entries = history_repo.list_history()
        for entry in entries:
            label = entry.title if not entry.source else f"{entry.title}  ·  {entry.source}"
            item = QListWidgetItem(label)
            item.setData(Qt.UserRole, entry.id)
            self.list.addItem(item)
        self.list.blockSignals(False)

        self.empty_hint.setVisible(not entries)
        if not entries:
            self._new_entry()
            return

        target = select_id if select_id is not None else entries[0].id
        self._select_in_list(target)

    def _select_in_list(self, entry_id: int) -> None:
        for i in range(self.list.count()):
            if self.list.item(i).data(Qt.UserRole) == entry_id:
                self.list.setCurrentRow(i)
                return
        if self.list.count():
            self.list.setCurrentRow(0)

    def _on_selection_changed(self, current: QListWidgetItem, _previous) -> None:
        if current is None:
            return
        entry = history_repo.get_entry(current.data(Qt.UserRole))
        if entry:
            self._current_id = entry.id
            self.title_edit.setText(entry.title)
            self.source_edit.setText(entry.source or "")

    def _new_entry(self) -> None:
        self._current_id = None
        self.title_edit.clear()
        self.source_edit.clear()
        self.title_edit.setFocus()

    # --- actions ------------------------------------------------------------

    def _save(self) -> None:
        title = self.title_edit.text().strip()
        if not title:
            QMessageBox.warning(self, "Title required", "Enter the OST's title.")
            self.title_edit.setFocus()
            return
        source = self.source_edit.text().strip() or None
        if self._current_id is None:
            entry = history_repo.add_entry(title, source)
            self._current_id = entry.id
        else:
            history_repo.update_entry(self._current_id, title, source)
        bus().history_changed.emit()
        self._reload_list(select_id=self._current_id)

    def _delete(self) -> None:
        if self._current_id is None:
            self._new_entry()
            return
        entry = history_repo.get_entry(self._current_id)
        confirm = QMessageBox.question(
            self,
            "Remove history entry?",
            f"Remove “{entry.title}” from the history list? It will no longer be "
            f"flagged when adding OSTs.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm == QMessageBox.Yes:
            history_repo.delete_entry(self._current_id)
            self._current_id = None
            bus().history_changed.emit()
            self._reload_list()
