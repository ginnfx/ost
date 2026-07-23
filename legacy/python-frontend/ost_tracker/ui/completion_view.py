"""Completion overview (screen 6): a raters × OSTs heatmap of what's rated.

One glance answers "what's left". Rows are raters, columns are OSTs; a filled
cell means that rater has scored that OST, an empty (red) cell means they
haven't. The grid is painted directly (not 500 widgets) so it stays crisp and
cheap. Hovering a cell names the exact rater/OST pair and its status.
"""

from __future__ import annotations


from PySide6.QtCore import QRect, Qt
from PySide6.QtGui import QColor, QFont, QPainter
from PySide6.QtWidgets import (
    QFrame,
    QLabel,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.ui import theme
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import EmptyState, TitleBlock

_CELL = 20
_GAP = 3
_LEFT = 110
_TOP = 26

_FILLED = QColor(theme.SCORE_HIGH)
_SELF = QColor(theme.GOLD)
_EMPTY = QColor(theme.MISSING_FILL)
_EMPTY_BORDER = QColor(theme.MISSING_BORDER)


class HeatmapWidget(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setMouseTracking(True)
        self._people: list = []
        self._osts: list = []
        self._filled: set[tuple[int, int]] = set()
        self._self_pairs: set[tuple[int, int]] = set()
        self.reload()

    def reload(self) -> None:
        self._people = people_repo.list_people()
        self._osts = ost_repo.list_osts()
        self._filled = rating_repo.completion_pairs()
        # (ost, submitter) pairs are the auto self-ratings — shown gold, not green.
        self._self_pairs = {
            (o.id, o.submitter_id) for o in self._osts if o.submitter_id is not None
        }
        rows, cols = len(self._people), len(self._osts)
        self.setMinimumSize(
            _LEFT + max(cols, 1) * (_CELL + _GAP) + 20,
            _TOP + max(rows, 1) * (_CELL + _GAP) + 20,
        )
        self.update()

    def _cell_rect(self, r: int, c: int) -> QRect:
        return QRect(_LEFT + c * (_CELL + _GAP), _TOP + r * (_CELL + _GAP), _CELL, _CELL)

    def paintEvent(self, event) -> None:  # noqa: N802
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing, False)

        small = theme.mono_font(8, weight=QFont.Medium)  # column indices in mono
        painter.setFont(small)

        # Column numbers every 5th OST to avoid clutter.
        painter.setPen(QColor(theme.TEXT_DIM))
        for c in range(len(self._osts)):
            if c == 0 or (c + 1) % 5 == 0:
                rect = self._cell_rect(0, c)
                painter.drawText(
                    QRect(rect.x(), 4, _CELL, _TOP - 6), Qt.AlignCenter, str(c + 1)
                )

        # Rater names on the left, then the cells.
        for r, person in enumerate(self._people):
            row_rect = self._cell_rect(r, 0)
            painter.setPen(QColor(theme.TEXT))
            painter.drawText(
                QRect(4, row_rect.y(), _LEFT - 10, _CELL),
                Qt.AlignVCenter | Qt.AlignRight,
                person.name[:12],
            )
            for c, ost in enumerate(self._osts):
                rect = self._cell_rect(r, c)
                pair = (ost.id, person.id)
                if pair in self._filled:
                    painter.fillRect(rect, _SELF if pair in self._self_pairs else _FILLED)
                else:
                    painter.fillRect(rect, _EMPTY)
                    painter.setPen(_EMPTY_BORDER)
                    painter.drawRect(rect.adjusted(0, 0, -1, -1))
        painter.end()

    def mouseMoveEvent(self, event) -> None:  # noqa: N802
        pos = event.position().toPoint()
        for r, person in enumerate(self._people):
            for c, ost in enumerate(self._osts):
                if self._cell_rect(r, c).contains(pos):
                    pair = (ost.id, person.id)
                    if pair in self._self_pairs:
                        status = "self-rating (auto)"
                    elif pair in self._filled:
                        status = "rated"
                    else:
                        status = "MISSING"
                    self.setToolTip(f"{person.name} → {ost.title}: {status}")
                    return
        self.setToolTip("")


class CompletionOverview(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM
        )
        root.setSpacing(theme.HEADER_GAP)

        root.addWidget(TitleBlock("Completion", "What's left to rate", "fa5s.check-double"))

        self.summary = QLabel()
        self.summary.setFont(theme.mono_font(11, weight=QFont.Medium))
        root.addWidget(self.summary)

        self.legend = QLabel(
            f"<span style='color:{theme.SCORE_HIGH}'>■</span> rated&nbsp;&nbsp;"
            f"<span style='color:{theme.GOLD}'>■</span> self (auto)&nbsp;&nbsp;"
            f"<span style='color:{theme.MISSING_TEXT}'>■</span> missing"
        )
        root.addWidget(self.legend)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self.heatmap = HeatmapWidget()
        self.scroll.setWidget(self.heatmap)
        root.addWidget(self.scroll, 1)

        self.empty_state = EmptyState()
        root.addWidget(self.empty_state, 1)

        b = bus()
        b.ratings_changed.connect(self.refresh)
        b.osts_changed.connect(self.refresh)
        b.people_changed.connect(self.refresh)
        self.refresh()

    def refresh(self) -> None:
        self.heatmap.reload()
        people = people_repo.count_people()
        osts = ost_repo.count_osts()
        expected = people * osts
        filled = rating_repo.total_ratings()
        has_data = expected > 0
        self.scroll.setVisible(has_data)
        self.legend.setVisible(has_data)
        self.summary.setVisible(has_data)
        self.empty_state.setVisible(not has_data)
        if has_data:
            pct = 100 * filled / expected
            self.summary.setText(
                f"{filled} / {expected} cells filled ({pct:.0f}%) — "
                f"{expected - filled} ratings still missing"
            )
        else:
            self.summary.setText("")
            self.empty_state.configure_needs_data("Add OSTs so there are cells to fill in.")
