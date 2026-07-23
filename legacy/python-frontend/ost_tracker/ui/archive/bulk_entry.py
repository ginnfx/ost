"""Bulk rating entry, one rater at a time (screen 4) — the keyboard-first
surface where most of the real time is spent.

Pick a person, then walk down every OST typing a score and pressing Enter. Each
Enter upserts the score and jumps to the next *unrated* row, skipping ones
already done. Rated rows keep a check + dimmed score but stay editable so you can
correct. When a person hits N/N, the screen auto-advances to the next person and
refocuses their first unrated row. A sort toggle lets the on-screen order match
whatever external list you're reading from.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.ui import theme
from ost_tracker.ui.anim import tick_up
from ost_tracker.ui.score_edit import ScoreEdit
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import EmptyState

SORT_SUBMITTER = "By submitter"
SORT_ALPHA = "Alphabetical"
SORT_ADDED = "Order added"


class _RaterRow(QWidget):
    """One OST row for the selected rater. When the rater *is* the OST's
    submitter the row is a self-rating: it's shown locked and tagged (you never
    score your own submission) and ``edit`` is ``None`` so the screen skips it in
    the unrated queue."""

    def __init__(self, ost, index: int, is_self: bool = False) -> None:
        super().__init__()
        self.ost = ost
        self.is_self = is_self
        self.edit: Optional[ScoreEdit] = None
        self.setObjectName("raterRow")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(10, 6, 10, 6)
        layout.setSpacing(10)

        self.check = QLabel()
        self.check.setFixedWidth(18)
        layout.addWidget(self.check)

        num = QLabel(f"{index + 1}.")
        num.setStyleSheet(f"color:{theme.TEXT_DIM};")
        num.setFixedWidth(28)
        layout.addWidget(num)

        title = QLabel(ost.title)
        title.setStyleSheet("font-size: 13px;")
        layout.addWidget(title, 1)

        submitter = QLabel(ost.submitter_name or "—")
        submitter.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size: 11px;")
        submitter.setFixedWidth(90)
        layout.addWidget(submitter)

        if is_self:
            # Locked self-rating chip in place of the editable field.
            self.self_chip = QLabel()
            self.self_chip.setAlignment(Qt.AlignCenter)
            self.self_chip.setFixedWidth(96)
            self.self_chip.setStyleSheet(
                f"background:{theme.SELF_TINT}; color:{theme.GOLD};"
                f" border:1px solid {theme.GOLD}; border-radius:6px;"
                f" padding:2px 4px; font-size:11px; font-weight:700;"
            )
            layout.addWidget(self.self_chip)
        else:
            self.edit = ScoreEdit()
            layout.addWidget(self.edit)

    def set_score(self, score: Optional[int]) -> None:
        if self.is_self:
            self.check.setText("★")
            self.check.setStyleSheet(f"color:{theme.GOLD}; font-weight:bold;")
            self.self_chip.setText(f"{'—' if score is None else score} · SELF")
            self._style(rated=True)
            return
        if score is None:
            self.edit.setText("")
            self.check.setText("")
            self._style(rated=False)
        else:
            self.edit.setText(str(score))
            self.check.setText("✓")
            self.check.setStyleSheet(f"color:{theme.SCORE_HIGH}; font-weight:bold;")
            self._style(rated=True)

    def _style(self, rated: bool) -> None:
        bg = "transparent" if not rated else theme.SURFACE
        self.setStyleSheet(f"#raterRow {{ background:{bg}; }}")


class BulkEntryScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._rows: list[_RaterRow] = []          # every row shown (incl. self)
        self._active_rows: list[_RaterRow] = []   # rateable rows (self excluded)
        self._focused_row: Optional[_RaterRow] = None  # last row we moved focus to
        self._build_ui()
        self._connect_signals()
        self._reload_people()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        # No outer margins: the Rate screen that hosts this provides them.
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(theme.HEADER_GAP)

        header = QHBoxLayout()
        header.addWidget(QLabel("Rater"))
        self.person_combo = QComboBox()
        self.person_combo.setMinimumWidth(160)
        self.person_combo.currentIndexChanged.connect(self._load_person)
        header.addWidget(self.person_combo)

        header.addSpacing(12)
        header.addWidget(QLabel("Order"))
        self.sort_combo = QComboBox()
        self.sort_combo.addItems([SORT_SUBMITTER, SORT_ALPHA, SORT_ADDED])
        self.sort_combo.currentIndexChanged.connect(lambda _: self._load_person())
        header.addWidget(self.sort_combo)
        header.addStretch(1)

        root.addLayout(header)

        self.progress_label = QLabel()
        self.progress_label.setFont(theme.mono_font(12))  # counts in mono
        root.addWidget(self.progress_label)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self._rows_host = QWidget()
        self._rows_layout = QVBoxLayout(self._rows_host)
        self._rows_layout.setContentsMargins(0, 0, 0, 0)
        self._rows_layout.setSpacing(2)
        self._rows_layout.setAlignment(Qt.AlignTop)
        self.scroll.setWidget(self._rows_host)
        root.addWidget(self.scroll, 1)

        self.empty_state = EmptyState()
        root.addWidget(self.empty_state, 1)

    def _connect_signals(self) -> None:
        b = bus()
        b.people_changed.connect(self._reload_people)
        b.osts_changed.connect(self._load_person)

    # --- data ---------------------------------------------------------------

    def _reload_people(self) -> None:
        current = self.person_combo.currentData()
        self.person_combo.blockSignals(True)
        self.person_combo.clear()
        for person in people_repo.list_people():
            self.person_combo.addItem(person.name, person.id)
        idx = self.person_combo.findData(current)
        self.person_combo.setCurrentIndex(idx if idx >= 0 else 0)
        self.person_combo.blockSignals(False)
        self._load_person()

    def _sorted_osts(self) -> list:
        osts = ost_repo.list_osts()
        mode = self.sort_combo.currentText()
        if mode == SORT_ALPHA:
            return sorted(osts, key=lambda o: o.title.lower())
        if mode == SORT_ADDED:
            return sorted(osts, key=lambda o: o.id)
        # By submitter, then title.
        return sorted(osts, key=lambda o: ((o.submitter_name or "~").lower(), o.title.lower()))

    def _load_person(self) -> None:
        person_id = self.person_combo.currentData()
        osts = self._sorted_osts()

        has_data = person_id is not None and len(osts) > 0
        self.scroll.setVisible(has_data)
        self.empty_state.setVisible(not has_data)
        if not has_data:
            self.empty_state.configure_needs_data(
                "Add OSTs so raters have something to score."
            )
            self.progress_label.setText("")
            self._clear_rows()
            return

        scores = {oid: rating_repo.get_score(oid, person_id) for oid in [o.id for o in osts]}

        self._clear_rows()
        for i, ost in enumerate(osts):
            is_self = ost.submitter_id == person_id
            row = _RaterRow(ost, i, is_self=is_self)
            row.set_score(scores[ost.id])
            if not is_self:
                row.edit.submitted.connect(lambda r=row: self._on_submit(r))
                row.edit.go_down.connect(lambda r=row: self._focus_relative(r, +1))
                row.edit.go_up.connect(lambda r=row: self._focus_relative(r, -1))
                self._active_rows.append(row)
            self._rows.append(row)
            self._rows_layout.addWidget(row)

        self._update_progress()
        self._focus_first_unrated()

    def _clear_rows(self) -> None:
        for row in self._rows:
            row.deleteLater()
        self._rows = []
        self._active_rows = []

    # --- interaction --------------------------------------------------------

    def _on_submit(self, row: _RaterRow) -> None:
        person_id = self.person_combo.currentData()
        if person_id is None:
            return
        text = row.edit.text().strip()
        score: Optional[int] = None
        if text == "":
            # Cleared -> remove any existing score for this cell.
            rating_repo.delete_rating(row.ost.id, person_id)
            row.set_score(None)
        else:
            score = int(text)
            rating_repo.upsert_rating(row.ost.id, person_id, score)
            row.set_score(score)
        bus().ratings_changed.emit()

        self._update_progress()
        advanced = self._advance_from(row)
        # Tick the just-confirmed value up from 0 (focus has already moved on).
        if advanced and score is not None:
            tick_up(row.edit, score)
        if not advanced:
            self._auto_advance_person()

    def _advance_from(self, row: _RaterRow) -> bool:
        """Focus the next unrated row after ``row`` (wrapping), skipping the
        rater's own submissions. Returns False if every rateable row is done."""
        if row not in self._active_rows:
            return True
        start = self._active_rows.index(row)
        n = len(self._active_rows)
        order = list(range(start + 1, n)) + list(range(0, start + 1))
        for i in order:
            if self._active_rows[i].edit.text().strip() == "":
                self._focus_row(self._active_rows[i])
                return True
        return False

    def _focus_relative(self, row: _RaterRow, delta: int) -> None:
        if row not in self._active_rows:
            return
        i = self._active_rows.index(row) + delta
        if 0 <= i < len(self._active_rows):
            self._focus_row(self._active_rows[i])

    def _focus_first_unrated(self) -> None:
        for row in self._active_rows:
            if row.edit.text().strip() == "":
                self._focus_row(row)
                return
        # All rated: focus the first rateable row so corrections are still easy.
        if self._active_rows:
            self._focus_row(self._active_rows[0])

    def _focus_row(self, row: _RaterRow) -> None:
        self._focused_row = row
        row.edit.setFocus()
        self._ensure_visible(row)

    def _ensure_visible(self, row: _RaterRow) -> None:
        self.scroll.ensureWidgetVisible(row, 0, 40)

    def _auto_advance_person(self) -> None:
        idx = self.person_combo.currentIndex()
        if idx + 1 < self.person_combo.count():
            self.person_combo.setCurrentIndex(idx + 1)  # triggers _load_person
        else:
            self.progress_label.setText(self.progress_label.text() + "  ·  All raters complete! 🎉")

    def _update_progress(self) -> None:
        total = len(self._active_rows)
        rated = sum(1 for r in self._active_rows if r.edit.text().strip() != "")
        name = self.person_combo.currentText()
        self_count = len(self._rows) - total
        suffix = f"  ·  {self_count} own submission{'s' if self_count != 1 else ''} (auto 10)" if self_count else ""
        if total == 0 and self_count:
            self.progress_label.setText(f"{name}: nothing to rate — only own submissions")
        else:
            self.progress_label.setText(f"{name}: {rated}/{total} rated{suffix}")
