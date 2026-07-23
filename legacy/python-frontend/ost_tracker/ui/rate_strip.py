"""One row of rater score cells for a single OST — the shared single-track
rating surface.

Two hosts embed this: ``QuickRateDialog`` (popup from a leaderboard card) and
the detail view (inline, so a track can be rated without leaving the screen).
Cell semantics mirror the archived matrix screen exactly: the same ``ScoreEdit``
widget, the same upsert-on-change through ``rating_repo`` (the single write
path), and the same locked gold self-rating cell for the submitter. Enter
advances to the next cell and, from the last one, emits ``completed`` (the
dialog closes on it; the inline host just leaves focus where it is).
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import QHBoxLayout, QLabel, QVBoxLayout, QWidget

from ost_tracker.db import people_repo, rating_repo
from ost_tracker.ui import theme
from ost_tracker.ui.anim import tick_up
from ost_tracker.ui.score_edit import ScoreEdit
from ost_tracker.ui.signals import bus

_CELL_W = 52
_SPACING = 6


class RateStrip(QWidget):
    completed = Signal()  # Enter confirmed on the last editable cell

    def __init__(self, ost, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost = ost
        self._people = people_repo.list_people()
        self._cells: list[ScoreEdit] = []
        self._saved: dict[int, Optional[int]] = {}
        self._self_col: Optional[int] = None
        if ost is not None:
            self._self_col = next(
                (i for i, p in enumerate(self._people) if p.id == ost.submitter_id),
                None,
            )
        self._build_ui()

    @property
    def ost_id(self) -> Optional[int]:
        return self._ost.id if self._ost is not None else None

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(4)

        if self._ost is None or not self._people:
            root.addWidget(QLabel("No people yet — add them on the People screen."))
            return

        # One column per rater: name over its score cell, matrix-style.
        row = QHBoxLayout()
        row.setSpacing(_SPACING)
        for c, person in enumerate(self._people):
            is_self = c == self._self_col
            col = QVBoxLayout()
            col.setSpacing(3)

            name = QLabel(("★ " if is_self else "") + person.name[:5])
            name.setFixedWidth(_CELL_W)
            name.setAlignment(Qt.AlignCenter)
            name.setToolTip(person.name + (" (submitter — self-rating)" if is_self else ""))
            color = theme.GOLD if is_self else theme.TEXT_DIM
            name.setStyleSheet(
                f"color:{color}; font-size:11px;" + (" font-weight:700;" if is_self else "")
            )
            col.addWidget(name)

            cell = ScoreEdit()
            score = rating_repo.get_score(self._ost.id, person.id)
            self._saved[c] = score
            if score is not None:
                cell.setText(str(score))
            if is_self:
                self._make_self_cell(cell)
            else:
                self._wire_cell(cell, c)
            col.addWidget(cell)

            row.addLayout(col)
        row.addStretch(1)
        root.addLayout(row)

        hint = QLabel("Enter saves and advances. Cleared cells remove the score.")
        hint.setStyleSheet(f"color:{theme.TEXT_FAINT}; font-size:10px;")
        root.addWidget(hint)

    # --- cells (same semantics as the archived matrix screen) ----------------

    def _make_self_cell(self, cell: ScoreEdit) -> None:
        cell.setReadOnly(True)
        cell.setFocusPolicy(Qt.NoFocus)
        cell.setToolTip("Self-rating — the submitter's own pick (auto 10)")
        cell.setStyleSheet(
            f"background:{theme.SELF_TINT}; color:{theme.GOLD};"
            f" border:1px solid {theme.GOLD}; border-radius:8px; font-weight:700;"
        )
        self._cells.append(cell)

    def _wire_cell(self, cell: ScoreEdit, c: int) -> None:
        cell.editingFinished.connect(lambda c=c: self._save_cell(c))
        cell.submitted.connect(lambda c=c: self._on_enter(c))
        cell.go_left.connect(lambda c=c: self._move_horizontal(c, -1))
        cell.go_right.connect(lambda c=c: self._move_horizontal(c, +1))
        self._cells.append(cell)

    def _save_cell(self, c: int) -> None:
        if c >= len(self._cells) or c == self._self_col:
            return
        text = self._cells[c].text().strip()
        new_value = int(text) if text else None
        if self._saved.get(c) == new_value:
            return  # nothing changed; avoid redundant writes/signals
        rater = self._people[c]
        if new_value is None:
            rating_repo.delete_rating(self._ost.id, rater.id)
        else:
            rating_repo.upsert_rating(self._ost.id, rater.id, new_value)
        self._saved[c] = new_value
        bus().ratings_changed.emit()

    def _on_enter(self, c: int) -> None:
        self._save_cell(c)
        value = self._saved.get(c)
        nxt = self._next_editable(c, +1)
        if nxt is None:
            self.completed.emit()  # last cell confirmed
            return
        self._move(nxt)
        if value is not None:
            tick_up(self._cells[c], value)

    def _next_editable(self, c: int, step: int) -> Optional[int]:
        nc = c + step
        while 0 <= nc < len(self._cells):
            if nc != self._self_col:
                return nc
            nc += step
        return None

    def _move_horizontal(self, c: int, step: int) -> None:
        """Arrow left/right: hop over the locked self column in the direction
        of travel instead of landing on (or bouncing off) it."""
        nc = c + step
        while 0 <= nc < len(self._cells) and nc == self._self_col:
            nc += step
        if 0 <= nc < len(self._cells):
            self._cells[nc].setFocus()

    def _move(self, c: int) -> None:
        if not self._cells:
            return
        c = max(0, min(c, len(self._cells) - 1))
        if c == self._self_col:
            nxt = self._next_editable(c, +1)
            c = nxt if nxt is not None else c
        if c != self._self_col:
            self._cells[c].setFocus()

    def focus_first_incomplete(self) -> None:
        for c, cell in enumerate(self._cells):
            if c != self._self_col and cell.text().strip() == "":
                self._move(c)
                return
        if self._cells:
            first = self._next_editable(-1, +1)
            if first is not None:
                self._move(first)

    # --- external refresh -----------------------------------------------------

    def refresh_external(self) -> None:
        """Re-read scores after a change made elsewhere. Skipped while any cell
        has focus — the change then came from this strip (or the user is mid-
        edit) and clobbering the cells would eat their typing."""
        if self._ost is None:
            return
        if any(cell.hasFocus() for cell in self._cells):
            return
        for c, person in enumerate(self._people):
            if c == self._self_col:
                continue
            score = rating_repo.get_score(self._ost.id, person.id)
            self._saved[c] = score
            self._cells[c].setText("" if score is None else str(score))
