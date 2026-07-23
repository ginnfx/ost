"""The Leaderboard screen.

A segmented control switches between two views of the same competition:

* **Ranking** — the leaderboard grid, with the detail view stacked behind it.
  Clicking a card opens the Quick Rate dialog for that track; its Full-details
  button (or any open_detail_requested emit) slides to detail in place, and a
  back action returns to the grid.
* **Completed** — the rater × OST completion heatmap (formerly a toolbar popover).

Keeping both in one screen (rather than separate sidebar destinations) is the
IA the spec asks for: same data, different view, switched in-place.
"""

from __future__ import annotations

from PySide6.QtWidgets import QHBoxLayout, QStackedWidget, QVBoxLayout, QWidget

from ost_tracker.ui import theme
from ost_tracker.ui.completion_view import CompletionOverview
from ost_tracker.ui.detail_view import DetailView
from ost_tracker.ui.grid_view import GridView
from ost_tracker.ui.widgets import SegmentedControl


class HomeScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        # Slim view-switch bar on top; each view keeps its own title beneath.
        self.seg = SegmentedControl(["Ranking", "Completed"])
        self.seg.changed.connect(self._on_segment)
        seg_row = QHBoxLayout()
        seg_row.setContentsMargins(theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, 0)
        seg_row.addStretch(1)
        seg_row.addWidget(self.seg)
        root.addLayout(seg_row)

        self.stack = QStackedWidget()
        # Ranking area: grid <-> detail, in-place.
        self.ranking = QStackedWidget()
        self.grid = GridView()
        self.detail = DetailView()
        self.ranking.addWidget(self.grid)    # index 0
        self.ranking.addWidget(self.detail)  # index 1
        self.detail.back_requested.connect(self.show_grid)
        # Completed area.
        self.completed = CompletionOverview()
        self.stack.addWidget(self.ranking)    # index 0
        self.stack.addWidget(self.completed)  # index 1
        root.addWidget(self.stack, 1)

    def _on_segment(self, index: int) -> None:
        if index == 0:
            self.stack.setCurrentWidget(self.ranking)
        else:
            self.completed.refresh()
            self.stack.setCurrentWidget(self.completed)

    # --- public API used by MainWindow (unchanged surface) ------------------

    def show_grid(self) -> None:
        self.ranking.setCurrentWidget(self.grid)

    def show_detail(self, ost_id: int) -> None:
        if self.detail.load(ost_id):
            self.seg.setCurrentIndex(0)
            self.stack.setCurrentWidget(self.ranking)
            self.ranking.setCurrentWidget(self.detail)

    def focus_search(self) -> None:
        self.seg.setCurrentIndex(0)
        self.stack.setCurrentWidget(self.ranking)
        self.show_grid()
        self.grid.focus_search()
