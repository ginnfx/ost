"""A small 0–10 score input used by the keyboard-first entry screens.

Enter saves and advances; Up/Down move between rows. A 0–10 validator keeps
input clean, and focus-in selects existing text so typing overwrites.
"""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QIntValidator
from PySide6.QtWidgets import QLineEdit


class ScoreEdit(QLineEdit):
    submitted = Signal()  # Enter/Return pressed
    go_up = Signal()
    go_down = Signal()
    go_left = Signal()   # Left pressed at the start of the field
    go_right = Signal()  # Right pressed at the end of the field

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.setObjectName("scoreEdit")
        self.setValidator(QIntValidator(0, 10, self))
        self.setMaxLength(2)
        self.setAlignment(Qt.AlignCenter)
        self.setFixedWidth(52)

    def focusInEvent(self, event) -> None:  # noqa: N802
        super().focusInEvent(event)
        self.selectAll()

    def keyPressEvent(self, event) -> None:  # noqa: N802
        key = event.key()
        if key in (Qt.Key_Return, Qt.Key_Enter):
            self.submitted.emit()
            return
        if key == Qt.Key_Up:
            self.go_up.emit()
            return
        if key == Qt.Key_Down:
            self.go_down.emit()
            return
        # Left/Right move between cells only at the text boundary, so normal
        # cursor movement within a 2-digit value still works.
        if key == Qt.Key_Left and self.cursorPosition() == 0 and not self.hasSelectedText():
            self.go_left.emit()
            return
        if key == Qt.Key_Right and self.cursorPosition() == len(self.text()) and not self.hasSelectedText():
            self.go_right.emit()
            return
        super().keyPressEvent(event)
