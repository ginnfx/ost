"""A left-to-right wrapping flow layout (adapted from the canonical Qt example),
used to lay out cover-art cards that reflow as the window resizes — the Steam
library-grid feel."""

from __future__ import annotations

from PySide6.QtCore import QMargins, QPoint, QRect, QSize, Qt
from PySide6.QtWidgets import QLayout, QLayoutItem, QWidget


class FlowLayout(QLayout):
    def __init__(
        self,
        parent: QWidget | None = None,
        margin: int = 0,
        spacing: int = 16,
        vspacing: int | None = None,
    ) -> None:
        super().__init__(parent)
        self._items: list[QLayoutItem] = []
        self._spacing = spacing
        # Vertical gap between wrapped rows. Separate from the horizontal gap so
        # the grid can reserve hover-lift clearance between EVERY row (same value
        # as its top padding — never a first-row special case).
        self._vspacing = vspacing if vspacing is not None else spacing
        self.setContentsMargins(QMargins(margin, margin, margin, margin))

    def __del__(self) -> None:  # pragma: no cover - Qt teardown
        while self._items:
            self._items.pop()

    def addItem(self, item: QLayoutItem) -> None:
        self._items.append(item)
        self.invalidate()  # mark dirty so geometry is recomputed on the next pass

    def count(self) -> int:
        return len(self._items)

    def itemAt(self, index: int) -> QLayoutItem | None:
        if 0 <= index < len(self._items):
            return self._items[index]
        return None

    def takeAt(self, index: int) -> QLayoutItem | None:
        if 0 <= index < len(self._items):
            item = self._items.pop(index)
            # Without this the layout keeps stale geometry: a removed card's grid
            # slot is never freed, so a filtered-down result stays parked in its
            # old column instead of collapsing to the top-left.
            self.invalidate()
            return item
        return None

    def expandingDirections(self) -> Qt.Orientations:
        return Qt.Orientations(Qt.Orientation(0))

    def hasHeightForWidth(self) -> bool:
        return True

    def heightForWidth(self, width: int) -> int:
        return self._do_layout(QRect(0, 0, width, 0), test_only=True)

    def setGeometry(self, rect: QRect) -> None:
        super().setGeometry(rect)
        self._do_layout(rect, test_only=False)

    def sizeHint(self) -> QSize:
        return self.minimumSize()

    def minimumSize(self) -> QSize:
        size = QSize()
        for item in self._items:
            size = size.expandedTo(item.minimumSize())
        margins = self.contentsMargins()
        size += QSize(margins.left() + margins.right(), margins.top() + margins.bottom())
        return size

    def _do_layout(self, rect: QRect, test_only: bool) -> int:
        margins = self.contentsMargins()
        effective = rect.adjusted(margins.left(), margins.top(), -margins.right(), -margins.bottom())
        x = effective.x()
        y = effective.y()
        line_height = 0

        for item in self._items:
            hint = item.sizeHint()
            next_x = x + hint.width() + self._spacing
            if next_x - self._spacing > effective.right() and line_height > 0:
                x = effective.x()
                y = y + line_height + self._vspacing
                next_x = x + hint.width() + self._spacing
                line_height = 0

            if not test_only:
                item.setGeometry(QRect(QPoint(x, y), hint))

            x = next_x
            line_height = max(line_height, hint.height())

        return y + line_height - rect.y() + margins.bottom()
