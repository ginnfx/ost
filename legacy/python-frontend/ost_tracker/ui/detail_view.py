"""Full OST detail view (Phase 5).

Shows the large cover, metadata, aggregate stats (average, spread, stddev,
rank), and every rater's score. Supports editing/deleting the OST, overriding
the cover (re-fetch, local file, or pasted URL), and opening the external link.

Design note on locked-reveal: the detail view is the operator's data-entry and
verification surface (one person enters everyone's scores by hand), so it always
shows scores. The locked-reveal feature governs the *leaderboard grid's*
presentation, which is what an audience sees — not this working view.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.services import statistics
from ost_tracker.ui import icons, theme
from ost_tracker.ui.cover_worker import cover_service
from ost_tracker.ui.image_utils import cover_pixmap
from ost_tracker.ui.playback import TransportBar
from ost_tracker.ui.rate_strip import RateStrip
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import danger_button, ghost_button

_COVER_SIZE = 260


class DetailView(QWidget):
    back_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost_id: Optional[int] = None
        self._build_ui()
        self._connect_signals()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)

        # Top bar with a back button.
        topbar = QHBoxLayout()
        topbar.setContentsMargins(theme.PAGE_MARGIN, 12, theme.PAGE_MARGIN, 0)
        back = ghost_button(" Back", icons.back())
        back.clicked.connect(self.back_requested.emit)
        topbar.addWidget(back, 0, Qt.AlignLeft)
        topbar.addStretch(1)
        outer.addLayout(topbar)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        outer.addWidget(scroll, 1)

        body = QWidget()
        scroll.setWidget(body)
        self._columns = QHBoxLayout(body)
        self._columns.setContentsMargins(20, 16, 20, 20)
        self._columns.setSpacing(24)
        self._columns.setAlignment(Qt.AlignTop)

        # Left column: cover + cover actions + status.
        left = QVBoxLayout()
        self.cover_label = QLabel()
        self.cover_label.setFixedSize(_COVER_SIZE, _COVER_SIZE)
        left.addWidget(self.cover_label)

        # In-app playback for the OST's external link (hidden when no link).
        self.transport = TransportBar()
        left.addWidget(self.transport)

        self.cover_status = QLabel("")
        self.cover_status.setStyleSheet(f"color: {theme.TEXT_DIM}; font-size: 11px;")
        self.cover_status.setWordWrap(True)
        left.addWidget(self.cover_status)

        # One entry point for cover art: the picker fans out to every source
        # (iTunes, MusicBrainz, Bing if configured, YouTube) and also holds the
        # paste-URL / choose-file fallbacks.
        find_cover = ghost_button(" Find Cover Art", icons.image())
        find_cover.clicked.connect(self._choose_cover)
        left.addWidget(find_cover)

        left.addStretch(1)
        self._columns.addLayout(left, 0)

        # Right column: metadata, stats, per-rater scores, edit/delete.
        right = QVBoxLayout()
        right.setSpacing(10)

        self.title_label = QLabel()
        self.title_label.setFont(theme.display_font(22))
        self.title_label.setWordWrap(True)
        right.addWidget(self.title_label)

        self.meta_label = QLabel()
        self.meta_label.setStyleSheet(f"color: {theme.TEXT_DIM}; font-size: 13px;")
        right.addWidget(self.meta_label)

        self.link_button = QPushButton()
        self.link_button.setIcon(icons.link())
        self.link_button.setCursor(Qt.PointingHandCursor)
        self.link_button.clicked.connect(self._open_link)
        self.link_button.setFlat(True)
        self.link_button.setStyleSheet(f"text-align:left; color:{theme.ACCENT};")
        right.addWidget(self.link_button, 0, Qt.AlignLeft)

        # Stats strip.
        self.stats_frame = QFrame()
        self.stats_frame.setObjectName("statsStrip")
        self.stats_frame.setStyleSheet(
            f"#statsStrip {{ background:{theme.SURFACE_RAISED}; }}"
        )
        self._stats_layout = QGridLayout(self.stats_frame)
        self._stats_layout.setContentsMargins(14, 12, 14, 12)
        self._stats_layout.setHorizontalSpacing(28)
        right.addWidget(self.stats_frame)

        scores_heading = QLabel("Scores by rater")
        scores_heading.setFont(theme.display_font(12))
        scores_heading.setStyleSheet(f"color:{theme.TEXT};")
        right.addWidget(scores_heading)

        self.scores_container = QWidget()
        self.scores_layout = QVBoxLayout(self.scores_container)
        self.scores_layout.setContentsMargins(0, 0, 0, 0)
        self.scores_layout.setSpacing(4)
        right.addWidget(self.scores_container)

        # Inline rating: the same RateStrip Quick Rate uses, embedded so a
        # track can be rated without leaving this screen. Deliberately kept in
        # the retired green as PLACEHOLDER styling (the one sanctioned green in
        # the app) until the owner signs off on its final look.
        self.rate_frame = QFrame()
        self.rate_frame.setObjectName("inlineRateStrip")
        self.rate_frame.setStyleSheet(
            f"#inlineRateStrip {{ background:{theme.RATE_STRIP_GREEN_SOFT};"
            f" border:1px solid {theme.RATE_STRIP_GREEN}; border-radius:10px; }}"
        )
        rate_box = QVBoxLayout(self.rate_frame)
        rate_box.setContentsMargins(12, 10, 12, 10)
        rate_box.setSpacing(6)
        rate_heading = QLabel("Rate this OST")
        rate_heading.setFont(theme.display_font(11))
        rate_heading.setStyleSheet(f"color:{theme.RATE_STRIP_GREEN};")
        rate_box.addWidget(rate_heading)
        self._rate_box = rate_box
        self.rate_strip: RateStrip | None = None
        right.addWidget(self.rate_frame)

        # Edit / delete.
        actions = QHBoxLayout()
        edit_btn = ghost_button(" Edit", icons.edit())
        edit_btn.clicked.connect(self._edit)
        delete_btn = danger_button(" Delete", icons.delete())
        delete_btn.clicked.connect(self._delete)
        actions.addWidget(edit_btn)
        actions.addWidget(delete_btn)
        actions.addStretch(1)
        right.addLayout(actions)

        right.addStretch(1)
        self._columns.addLayout(right, 1)

    def _connect_signals(self) -> None:
        b = bus()
        b.ratings_changed.connect(self._maybe_reload)
        b.osts_changed.connect(self._maybe_reload)
        b.people_changed.connect(self._maybe_reload)
        cover_service().fetch_started.connect(self._on_fetch_started)
        cover_service().fetch_finished.connect(self._on_fetch_finished)

    # --- data ---------------------------------------------------------------

    def load(self, ost_id: int) -> bool:
        if ost_repo.get_ost(ost_id) is None:
            return False
        self._ost_id = ost_id
        self._rebuild()
        return True

    def _maybe_reload(self) -> None:
        if self._ost_id is None:
            return
        if ost_repo.get_ost(self._ost_id) is None:
            # The OST was deleted elsewhere; return to the grid.
            self._ost_id = None
            self.back_requested.emit()
            return
        self._rebuild()

    def _rebuild(self) -> None:
        stats = ost_repo.get_ost_stats(self._ost_id)
        if stats is None:
            return
        ost = stats.ost

        self.cover_label.setPixmap(cover_pixmap(ost.cover_image_path, ost.title, _COVER_SIZE, radius=14))
        self.transport.set_ost(ost)
        self.title_label.setText(ost.title)

        meta_bits = []
        if ost.source:
            meta_bits.append(ost.source)
        meta_bits.append(f"Submitted by {ost.submitter_name}" if ost.submitter_name else "No submitter")
        self.meta_label.setText("  ·  ".join(meta_bits))

        if ost.external_link:
            self.link_button.setText(f" {ost.external_link}")
            self.link_button.setVisible(True)
        else:
            self.link_button.setVisible(False)

        self._rebuild_stats(stats)
        self._rebuild_scores(ost)
        self._ensure_rate_strip(ost)

    def _ensure_rate_strip(self, ost) -> None:
        """Keep one persistent strip per loaded OST. Rebuilding it on every
        ratings_changed would eat the user's focus mid-entry (each cell save
        emits that signal), so an existing strip is only refreshed."""
        current_people = [p.id for p in people_repo.list_people()]
        if (
            self.rate_strip is not None
            and self.rate_strip.ost_id == ost.id
            and [p.id for p in self.rate_strip._people] == current_people
        ):
            self.rate_strip.refresh_external()
            return
        if self.rate_strip is not None:
            self.rate_strip.deleteLater()
        self.rate_strip = RateStrip(ost)
        self._rate_box.addWidget(self.rate_strip)

    def _rebuild_stats(self, stats) -> None:
        # Clear.
        while self._stats_layout.count():
            item = self._stats_layout.takeAt(0)
            w = item.widget()
            if w:
                w.deleteLater()

        total_people = people_repo.count_people()
        avg = f"{stats.average:.2f}" if stats.average is not None else "—"
        spread = statistics.spread_label(stats.minimum, stats.maximum)
        stddev = f"{stats.stddev:.2f}" if stats.stddev is not None else "—"
        rank = f"#{stats.rank}" if stats.rank is not None else "—"
        rated = f"{stats.rating_count}/{total_people}"

        cells = [
            ("Average", avg),
            ("Spread", spread),
            ("Std dev", stddev),
            ("Rank", rank),
            ("Rated", rated),
        ]
        for col, (label, value) in enumerate(cells):
            lbl = QLabel(label.upper())
            lbl.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:10px; letter-spacing:1px;")
            val = QLabel(value)
            val.setFont(theme.mono_font(15))
            val.setStyleSheet(f"color:{theme.TEXT};")
            self._stats_layout.addWidget(lbl, 0, col)
            self._stats_layout.addWidget(val, 1, col)

    def _rebuild_scores(self, ost) -> None:
        while self.scores_layout.count():
            item = self.scores_layout.takeAt(0)
            w = item.widget()
            if w:
                w.deleteLater()

        scored = {r.rater_id: r.score for r in rating_repo.ratings_for_ost(self._ost_id)}
        people = people_repo.list_people()
        if not people:
            self.scores_layout.addWidget(QLabel("No people yet — add them in Settings (⌘,)."))
            return

        for person in people:
            is_self = person.id == ost.submitter_id
            row = QWidget()
            rl = QHBoxLayout(row)
            rl.setContentsMargins(0, 0, 0, 0)
            name = QLabel(person.name)
            rl.addWidget(name)
            if is_self:
                tag = QLabel("SELF")
                tag.setStyleSheet(
                    f"color:{theme.GOLD}; background:{theme.SELF_TINT};"
                    f" border:1px solid {theme.GOLD}; border-radius:6px;"
                    f" padding:0px 5px; font-size:9px; font-weight:800;"
                )
                rl.addWidget(tag)
            rl.addStretch(1)
            score = scored.get(person.id)
            if score is None:
                chip = QLabel("—")
                chip.setStyleSheet(f"color:{theme.TEXT_DIM};")
            else:
                chip = QLabel(str(score))
                chip.setAlignment(Qt.AlignCenter)
                chip.setFixedWidth(34)
                chip.setFont(theme.mono_font(11))  # score readout in mono
                # Self-ratings read gold; everyone else uses the score-heat colour.
                bg = theme.GOLD if is_self else theme.score_color(score)
                fg = theme.INK if is_self else theme.ON_ACCENT
                chip.setStyleSheet(
                    f"background:{bg}; color:{fg};"
                    f" border-radius:8px; padding:1px 6px;"
                )
            rl.addWidget(chip)
            self.scores_layout.addWidget(row)

    # --- cover actions ------------------------------------------------------

    def _choose_cover(self) -> None:
        ost = ost_repo.get_ost(self._ost_id)
        if not ost:
            return
        from ost_tracker.ui.cover_picker import CoverPickerDialog

        CoverPickerDialog(ost, self).exec()

    def _on_fetch_started(self, ost_id: int) -> None:
        if ost_id == self._ost_id:
            self.cover_status.setText("Fetching cover art…")

    def _on_fetch_finished(self, ost_id: int, result) -> None:
        if ost_id != self._ost_id:
            return
        if result.found:
            self.cover_status.setText(f"Cover found via {result.source.value}.")
        else:
            self.cover_status.setText("No cover found — override manually below.")

    # --- edit / delete / link ----------------------------------------------

    def _edit(self) -> None:
        ost = ost_repo.get_ost(self._ost_id)
        if not ost:
            return
        from ost_tracker.ui.edit_ost_dialog import EditOstDialog

        EditOstDialog(ost, self).exec()

    def _delete(self) -> None:
        ost = ost_repo.get_ost(self._ost_id)
        if not ost:
            return
        confirm = QMessageBox.question(
            self,
            "Delete OST?",
            f"Delete “{ost.title}” and all its ratings? This can't be undone.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm == QMessageBox.Yes:
            ost_repo.delete_ost(ost.id)
            self._ost_id = None
            bus().osts_changed.emit()
            bus().ratings_changed.emit()
            self.back_requested.emit()

    def _open_link(self) -> None:
        ost = ost_repo.get_ost(self._ost_id)
        if ost and ost.external_link:
            QDesktopServices.openUrl(QUrl(ost.external_link))
