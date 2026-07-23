"""Matrix rating entry, by submitter (screen 5).

Pick a submitter; their OSTs become rows and every rater a column, one small
score cell each. Arrow keys move between cells like a spreadsheet. Any row with
an empty cell is tinted until every rater has scored it. Cells write through the
same upsert as the bulk-entry screen — no divergent save logic.
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
from ost_tracker.ui import icons, theme
from ost_tracker.ui.anim import tick_up
from ost_tracker.ui.score_edit import ScoreEdit
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import EmptyState

_TITLE_COL_W = 230
_CELL_W = 52
_SPACING = 6


class MatrixEntryScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._osts: list = []
        self._people: list = []
        self._cells: list[list[ScoreEdit]] = []
        self._row_frames: list[QFrame] = []
        self._saved: dict[tuple[int, int], Optional[int]] = {}
        # Column index of the submitter themselves — a locked self-rating column
        # (they can't score their own submissions). None until a matrix is built.
        self._self_col: Optional[int] = None
        self._build_ui()
        self._connect_signals()
        self._reload_submitters()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        # No outer margins: the Rate screen that hosts this provides them.
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(theme.HEADER_GAP)

        header = QHBoxLayout()
        header.addWidget(QLabel("Submitter"))
        self.submitter_combo = QComboBox()
        self.submitter_combo.setMinimumWidth(160)
        self.submitter_combo.currentIndexChanged.connect(self._rebuild_matrix)
        header.addWidget(self.submitter_combo)
        header.addStretch(1)
        root.addLayout(header)

        self.hint = QLabel(
            "Rows tint until every rater has scored them. Arrow keys move between cells. "
            "The gold column is the submitter's own pick (auto 10)."
        )
        self.hint.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:11px;")
        root.addWidget(self.hint)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self._host = QWidget()
        self._host_layout = QVBoxLayout(self._host)
        self._host_layout.setContentsMargins(0, 0, 0, 0)
        self._host_layout.setSpacing(4)
        self._host_layout.setAlignment(Qt.AlignTop)
        self.scroll.setWidget(self._host)
        root.addWidget(self.scroll, 1)

        self.empty_state = EmptyState()
        root.addWidget(self.empty_state, 1)

    def _connect_signals(self) -> None:
        b = bus()
        b.people_changed.connect(self._reload_submitters)
        b.osts_changed.connect(self._rebuild_matrix)

    # --- data ---------------------------------------------------------------

    def _reload_submitters(self) -> None:
        current = self.submitter_combo.currentData()
        self.submitter_combo.blockSignals(True)
        self.submitter_combo.clear()
        for person in people_repo.list_people():
            self.submitter_combo.addItem(person.name, person.id)
        idx = self.submitter_combo.findData(current)
        if idx < 0:
            idx = self._default_submitter_index()
        self.submitter_combo.setCurrentIndex(idx)
        self.submitter_combo.blockSignals(False)
        self._rebuild_matrix()

    def _default_submitter_index(self) -> int:
        """Open on the first person who has actually submitted OSTs, so the matrix
        shows rows to score instead of an empty 'no submissions yet' state when
        the alphabetically-first person happens to have submitted nothing."""
        with_osts = {o.submitter_id for o in ost_repo.list_osts() if o.submitter_id is not None}
        for i in range(self.submitter_combo.count()):
            if self.submitter_combo.itemData(i) in with_osts:
                return i
        return 0

    def _clear(self) -> None:
        # Header + row frames all live in _host_layout.
        while self._host_layout.count():
            item = self._host_layout.takeAt(0)
            w = item.widget()
            if w:
                w.deleteLater()
        self._cells = []
        self._row_frames = []
        self._saved = {}
        self._self_col = None

    def _rebuild_matrix(self) -> None:
        self._clear()
        submitter_id = self.submitter_combo.currentData()
        self._people = people_repo.list_people()
        self._osts = ost_repo.osts_by_submitter(submitter_id) if submitter_id is not None else []
        # Every row here is this submitter's OST, so their own column is the same
        # locked self-rating column throughout.
        self._self_col = next(
            (i for i, p in enumerate(self._people) if p.id == submitter_id), None
        )

        has_data = bool(self._osts) and bool(self._people)
        self.scroll.setVisible(has_data)
        self.empty_state.setVisible(not has_data)
        if not has_data:
            if not self._people or ost_repo.count_osts() == 0:
                self.empty_state.configure_needs_data("Add OSTs, then score them by submitter.")
            else:
                name = self.submitter_combo.currentText() or "This person"
                self.empty_state.configure(
                    "No OSTs from this submitter",
                    f"{name} hasn't submitted any OSTs yet.",
                    " Add OST",
                    lambda: bus().open_add_ost_requested.emit(
                        "", "", self.submitter_combo.currentData()
                    ),
                    icon_name="fa5s.compact-disc",
                    button_icon=icons.add(),
                )
            return

        self._host_layout.addWidget(self._build_header())

        for r, ost in enumerate(self._osts):
            frame = QFrame()
            frame.setObjectName("matrixRow")
            row_layout = QHBoxLayout(frame)
            row_layout.setContentsMargins(6, 4, 6, 4)
            row_layout.setSpacing(_SPACING)

            title = QLabel(ost.title)
            title.setFixedWidth(_TITLE_COL_W)
            title.setToolTip(ost.title)
            title.setStyleSheet("font-size:13px;")
            row_layout.addWidget(title)

            row_cells: list[ScoreEdit] = []
            for c, person in enumerate(self._people):
                cell = ScoreEdit()
                score = rating_repo.get_score(ost.id, person.id)
                self._saved[(r, c)] = score
                if score is not None:
                    cell.setText(str(score))
                if c == self._self_col:
                    self._make_self_cell(cell)
                else:
                    self._wire_cell(cell, r, c)
                row_layout.addWidget(cell)
                row_cells.append(cell)
            row_layout.addStretch(1)

            self._cells.append(row_cells)
            self._row_frames.append(frame)
            self._host_layout.addWidget(frame)
            self._update_row_tint(r)

        # Focus the first empty cell, else the first cell.
        self._focus_first_incomplete()

    def _build_header(self) -> QWidget:
        header = QWidget()
        layout = QHBoxLayout(header)
        layout.setContentsMargins(6, 0, 6, 0)
        layout.setSpacing(_SPACING)
        corner = QLabel("OST \\ Rater")
        corner.setFixedWidth(_TITLE_COL_W)
        corner.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:11px;")
        layout.addWidget(corner)
        for c, person in enumerate(self._people):
            is_self = c == self._self_col
            lbl = QLabel(("★ " if is_self else "") + person.name[:5])
            lbl.setFixedWidth(_CELL_W)
            lbl.setAlignment(Qt.AlignCenter)
            lbl.setToolTip(person.name + (" (submitter — self-rating)" if is_self else ""))
            color = theme.GOLD if is_self else theme.TEXT_DIM
            lbl.setStyleSheet(f"color:{color}; font-size:11px;" + (" font-weight:700;" if is_self else ""))
            layout.addWidget(lbl)
        layout.addStretch(1)
        return header

    def _make_self_cell(self, cell: ScoreEdit) -> None:
        """Lock a cell as the submitter's own self-rating: gold, read-only, and
        skipped by navigation (they never score their own submission)."""
        cell.setReadOnly(True)
        cell.setFocusPolicy(Qt.NoFocus)
        cell.setToolTip("Self-rating — the submitter's own pick (auto 10)")
        cell.setStyleSheet(
            f"background:{theme.SELF_TINT}; color:{theme.GOLD};"
            f" border:1px solid {theme.GOLD}; border-radius:8px; font-weight:700;"
        )

    def _wire_cell(self, cell: ScoreEdit, r: int, c: int) -> None:
        cell.editingFinished.connect(lambda r=r, c=c: self._save_cell(r, c))
        cell.submitted.connect(lambda r=r, c=c: self._on_enter(r, c))
        cell.go_up.connect(lambda r=r, c=c: self._move(r - 1, c))
        cell.go_down.connect(lambda r=r, c=c: self._move(r + 1, c))
        cell.go_left.connect(lambda r=r, c=c: self._move_horizontal(r, c, -1))
        cell.go_right.connect(lambda r=r, c=c: self._move_horizontal(r, c, +1))

    # --- interaction --------------------------------------------------------

    def _save_cell(self, r: int, c: int) -> None:
        if r >= len(self._cells) or c >= len(self._cells[r]):
            return
        if c == self._self_col:
            return  # locked self-rating; never written from the matrix
        text = self._cells[r][c].text().strip()
        new_value = int(text) if text else None
        if self._saved.get((r, c)) == new_value:
            return  # nothing changed; avoid redundant writes/signals
        ost = self._osts[r]
        rater = self._people[c]
        if new_value is None:
            rating_repo.delete_rating(ost.id, rater.id)
        else:
            rating_repo.upsert_rating(ost.id, rater.id, new_value)
        self._saved[(r, c)] = new_value
        self._update_row_tint(r)
        bus().ratings_changed.emit()

    def _on_enter(self, r: int, c: int) -> None:
        self._save_cell(r, c)
        value = self._saved.get((r, c))
        self._move(r + 1, c)  # Enter drops down a row, spreadsheet-style
        # Tick the confirmed value up from 0 (focus has moved to the next row).
        if value is not None:
            tick_up(self._cells[r][c], value)

    def _nearest_editable_col(self, c: int) -> Optional[int]:
        """The editable column at or nearest to ``c`` (the self column can't hold
        focus). None when the submitter is the only person, so nothing is
        editable."""
        cols = len(self._people)
        if cols == 0:
            return None
        if c != self._self_col:
            return c
        for d in range(1, cols):
            for cand in (c + d, c - d):
                if 0 <= cand < cols and cand != self._self_col:
                    return cand
        return None

    def _move(self, r: int, c: int) -> None:
        if not self._cells:
            return
        r = max(0, min(r, len(self._cells) - 1))
        c = max(0, min(c, len(self._cells[0]) - 1))
        col = self._nearest_editable_col(c)
        if col is None:
            return
        cell = self._cells[r][col]
        cell.setFocus()
        self.scroll.ensureWidgetVisible(cell, 40, 40)

    def _move_horizontal(self, r: int, c: int, step: int) -> None:
        """Left/right arrow: step to the next column in ``step`` direction,
        hopping over the locked self column instead of landing on it."""
        cols = len(self._people)
        nc = c + step
        while 0 <= nc < cols and nc == self._self_col:
            nc += step
        if 0 <= nc < cols:
            self._move(r, nc)

    def _update_row_tint(self, r: int) -> None:
        # A row is complete once every *rater* (non-self) cell is filled — the
        # submitter's own column is auto-filled and never counts as missing.
        incomplete = any(
            self._cells[r][c].text().strip() == ""
            for c in range(len(self._cells[r]))
            if c != self._self_col
        )
        bg = theme.INCOMPLETE_TINT if incomplete else "transparent"
        self._row_frames[r].setStyleSheet(f"#matrixRow {{ background:{bg}; }}")

    def _focus_first_incomplete(self) -> None:
        for r, row in enumerate(self._cells):
            for c, cell in enumerate(row):
                if c != self._self_col and cell.text().strip() == "":
                    self._move(r, c)
                    return
        self._move(0, 0)
