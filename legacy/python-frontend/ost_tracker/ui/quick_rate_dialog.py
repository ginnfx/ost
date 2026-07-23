"""Quick Rate: single-track score entry straight from a leaderboard card.

The one-off path for fixing ONE track's scores: click a card (browsing or mid-
search), get a header plus one row of rater cells, correct what you need, and
close — the Leaderboard behind it keeps its search text and scroll position
because nothing navigates away.

The row itself is :class:`~ost_tracker.ui.rate_strip.RateStrip`, shared with
the detail view's inline rating strip, so both surfaces stay behaviourally
identical (same cells, same upsert write path, same locked self-rating).
"""

from __future__ import annotations

from PySide6.QtWidgets import QDialog, QHBoxLayout, QLabel, QVBoxLayout, QWidget

from ost_tracker.db import ost_repo
from ost_tracker.ui import icons, theme
from ost_tracker.ui.image_utils import cover_pixmap
from ost_tracker.ui.playback import TransportBar
from ost_tracker.ui.rate_strip import RateStrip
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import ghost_button

_COVER_SIZE = 84


class QuickRateDialog(QDialog):
    def __init__(self, ost_id: int, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost = ost_repo.get_ost(ost_id)
        self.setWindowTitle("Quick Rate")
        self._build_ui()
        self.strip.focus_first_incomplete()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(14)

        self.strip = RateStrip(self._ost)
        # From the last cell, Enter means "the one-off edit is done".
        self.strip.completed.connect(self.accept)

        if self._ost is None:
            root.addWidget(QLabel("This OST no longer exists."))
            return

        root.addLayout(self._build_header())
        root.addWidget(self.strip)

    def _build_header(self) -> QHBoxLayout:
        header = QHBoxLayout()
        header.setSpacing(14)

        cover = QLabel()
        cover.setFixedSize(_COVER_SIZE, _COVER_SIZE)
        cover.setPixmap(
            cover_pixmap(self._ost.cover_image_path, self._ost.title, _COVER_SIZE, radius=8)
        )
        header.addWidget(cover)

        text_col = QVBoxLayout()
        text_col.setSpacing(2)
        title = QLabel(self._ost.title)
        title.setFont(theme.display_font(15))
        title.setWordWrap(True)
        text_col.addWidget(title)
        meta_bits = [b for b in (self._ost.source, self._ost.submitter_name) if b]
        meta = QLabel("  ·  ".join(meta_bits) or "—")
        meta.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:12px;")
        text_col.addWidget(meta)
        # In-app playback (searches for a stream even without a saved link).
        self.transport = TransportBar()
        self.transport.set_ost(self._ost)
        text_col.addWidget(self.transport)
        text_col.addStretch(1)
        header.addLayout(text_col, 1)

        actions = QVBoxLayout()
        details = ghost_button(" Full details", icons.icon("fa5s.expand-alt"))
        details.clicked.connect(self._open_details)
        actions.addWidget(details)
        actions.addStretch(1)
        header.addLayout(actions)
        return header

    # --- back-compat surface (tests and callers address the dialog) ----------

    @property
    def _cells(self):
        return self.strip._cells

    @property
    def _people(self):
        return self.strip._people

    @property
    def _self_col(self):
        return self.strip._self_col

    def _save_cell(self, c: int) -> None:
        self.strip._save_cell(c)

    def _on_enter(self, c: int) -> None:
        self.strip._on_enter(c)

    def _move_horizontal(self, c: int, step: int) -> None:
        self.strip._move_horizontal(c, step)

    # --- actions --------------------------------------------------------------

    def _open_details(self) -> None:
        ost_id = self._ost.id
        self.accept()
        bus().open_detail_requested.emit(ost_id)
