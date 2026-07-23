"""The reveal moment.

Shown once, the instant scores become visible — whether that's the final rating
landing (auto) or a manual early reveal. A deliberate, celebratory beat so the
leaderboard arrives as an event rather than quietly resolving as data trickles
in.
"""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.ui import icons, theme


class RevealDialog(QDialog):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Results are in")
        self.setModal(True)
        self.setMinimumWidth(420)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(32, 28, 32, 24)
        layout.setSpacing(14)
        layout.setAlignment(Qt.AlignCenter)

        trophy = QLabel()
        pm = icons.trophy(color=theme.SCORE_MID).pixmap(72, 72)
        trophy.setPixmap(pm)
        trophy.setAlignment(Qt.AlignCenter)
        layout.addWidget(trophy)

        title = QLabel("The results are in!")
        tf = title.font()
        tf.setPointSize(22)
        tf.setBold(True)
        title.setFont(tf)
        title.setAlignment(Qt.AlignCenter)
        layout.addWidget(title)

        subtitle = QLabel("Every score is locked in. Time to reveal the rankings.")
        subtitle.setAlignment(Qt.AlignCenter)
        subtitle.setWordWrap(True)
        subtitle.setStyleSheet(f"color:{theme.TEXT_DIM};")
        layout.addWidget(subtitle)

        button = QPushButton("Show the leaderboard")
        button.setDefault(True)
        button.clicked.connect(self.accept)
        layout.addWidget(button)
