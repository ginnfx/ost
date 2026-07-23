"""The unified Rate screen.

One sidebar item for all score entry. A segmented control at the top switches the
content between the two existing modes without navigating away:

* **By person** — walk one rater down every OST (``BulkEntryScreen``).
* **By OST batch** — a submitter's OSTs × every rater matrix (``MatrixEntryScreen``).

Both modes are the original screens unchanged in behaviour; this screen only
provides the shared header + segmented control and hosts them in a stack.
"""

from __future__ import annotations

from PySide6.QtWidgets import QHBoxLayout, QStackedWidget, QVBoxLayout, QWidget

from ost_tracker.ui import theme
from ost_tracker.ui.archive.bulk_entry import BulkEntryScreen
from ost_tracker.ui.archive.matrix_entry import MatrixEntryScreen
from ost_tracker.ui.widgets import SegmentedControl, TitleBlock


class RateScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM
        )
        root.setSpacing(theme.HEADER_GAP)

        self.stack = QStackedWidget()
        self.by_person = BulkEntryScreen()
        self.by_batch = MatrixEntryScreen()
        self.stack.addWidget(self.by_person)   # index 0
        self.stack.addWidget(self.by_batch)    # index 1

        self.seg = SegmentedControl(["By person", "By OST batch"])
        self.seg.changed.connect(self.stack.setCurrentIndex)

        header = QHBoxLayout()
        header.addWidget(TitleBlock("Rate", "Enter scores — by person or by OST", "fa5s.keyboard"))
        header.addStretch(1)
        header.addWidget(self.seg)
        root.addLayout(header)
        root.addWidget(self.stack, 1)
