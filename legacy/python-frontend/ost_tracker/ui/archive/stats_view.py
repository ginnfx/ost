"""Stats tab (screen 7).

Two tables: per-OST stats (rank, average, std dev, spread) and per-rater
leniency (the average score each person hands out). The per-OST table is the
leaderboard in numeric form, so it is gated behind the locked-reveal exactly
like the grid. Per-rater leniency is a fairness/process metric about raters, not
the competition outcome, so it stays visible.
"""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo
from ost_tracker.services import rater_stats, reveal, statistics
from ost_tracker.ui import theme
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import EmptyState, TitleBlock, ghost_button


def _num_item(text: str) -> QTableWidgetItem:
    item = QTableWidgetItem(text)
    item.setTextAlignment(Qt.AlignCenter)
    item.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable)
    item.setFont(theme.mono_font(11))  # numeric readouts in JetBrains Mono
    return item


def _text_item(text: str) -> QTableWidgetItem:
    item = QTableWidgetItem(text)
    item.setFlags(Qt.ItemIsEnabled | Qt.ItemIsSelectable)
    return item


def _read_only_table(headers: list[str], stretch_col: int) -> QTableWidget:
    table = QTableWidget(0, len(headers))
    table.setHorizontalHeaderLabels(headers)
    table.verticalHeader().setVisible(False)
    table.setEditTriggers(QAbstractItemView.NoEditTriggers)
    table.setSelectionBehavior(QAbstractItemView.SelectRows)
    table.setShowGrid(False)
    table.setAlternatingRowColors(True)
    header = table.horizontalHeader()
    # Size columns to content, except the flexible column (Title/Rater), which
    # absorbs the slack so the table doesn't spread narrow columns evenly.
    for col in range(len(headers)):
        mode = QHeaderView.Stretch if col == stretch_col else QHeaderView.ResizeToContents
        header.setSectionResizeMode(col, mode)
    header.setHighlightSections(False)
    return table


class StatsScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM
        )
        root.setSpacing(theme.HEADER_GAP)

        root.addWidget(TitleBlock("Stats", "Per-OST rankings and per-rater leniency", "fa5s.chart-bar"))

        # Content lives in its own container so it can be swapped for an empty
        # state wholesale when there's nothing to show yet.
        self.content = QWidget()
        content_layout = QVBoxLayout(self.content)
        content_layout.setContentsMargins(0, 0, 0, 0)
        content_layout.setSpacing(8)

        self.ost_heading = QLabel("Per-OST")
        self.ost_heading.setStyleSheet("font-weight:bold;")
        content_layout.addWidget(self.ost_heading)

        self.locked_notice = QWidget()
        ln = QHBoxLayout(self.locked_notice)
        ln.setContentsMargins(0, 0, 0, 0)
        lbl = QLabel("🔒  Per-OST stats are hidden until the reveal.")
        lbl.setStyleSheet(f"color:{theme.TEXT_DIM};")
        ln.addWidget(lbl)
        reveal_btn = ghost_button("Reveal now")
        reveal_btn.clicked.connect(self._reveal_now)
        ln.addWidget(reveal_btn)
        ln.addStretch(1)
        content_layout.addWidget(self.locked_notice)

        self.ost_table = _read_only_table(
            ["Rank", "Title", "Submitter", "Average", "Std Dev", "Spread", "Rated"], stretch_col=1
        )
        content_layout.addWidget(self.ost_table, 2)

        self.rater_heading = QLabel("Per-rater leniency")
        self.rater_heading.setStyleSheet("font-weight:bold;")
        content_layout.addWidget(self.rater_heading)
        self.rater_table = _read_only_table(["Rater", "Avg score given", "Ratings"], stretch_col=0)
        content_layout.addWidget(self.rater_table, 1)

        root.addWidget(self.content, 1)

        self.empty_state = EmptyState()
        root.addWidget(self.empty_state, 1)

        b = bus()
        b.ratings_changed.connect(self.refresh)
        b.osts_changed.connect(self.refresh)
        b.people_changed.connect(self.refresh)
        b.reveal_changed.connect(self.refresh)
        self.refresh()

    def refresh(self) -> None:
        if not EmptyState.has_data():
            self.content.setVisible(False)
            self.empty_state.setVisible(True)
            self.empty_state.configure_needs_data("Add OSTs and enter ratings to see stats.")
            return
        self.content.setVisible(True)
        self.empty_state.setVisible(False)

        visible = reveal.scores_visible()
        self.locked_notice.setVisible(not visible)
        self.ost_table.setVisible(visible)
        if visible:
            self._fill_ost_table()
        self._fill_rater_table()

    def _fill_ost_table(self) -> None:
        stats = ost_repo.list_osts_with_stats()
        stats.sort(key=lambda s: (s.rank is None, s.rank or 0, s.ost.title.lower()))
        total_people = people_repo.count_people()
        self.ost_table.setRowCount(len(stats))
        for row, s in enumerate(stats):
            avg = f"{s.average:.2f}" if s.average is not None else "—"
            std = f"{s.stddev:.2f}" if s.stddev is not None else "—"
            spread = statistics.spread_label(s.minimum, s.maximum)
            rank = str(s.rank) if s.rank is not None else "—"
            self.ost_table.setItem(row, 0, _num_item(rank))
            self.ost_table.setItem(row, 1, _text_item(s.ost.title))
            self.ost_table.setItem(row, 2, _text_item(s.ost.submitter_name or "—"))
            self.ost_table.setItem(row, 3, _num_item(avg))
            self.ost_table.setItem(row, 4, _num_item(std))
            self.ost_table.setItem(row, 5, _num_item(spread))
            self.ost_table.setItem(row, 6, _num_item(f"{s.rating_count}/{total_people}"))

    def _fill_rater_table(self) -> None:
        stats = rater_stats.rater_leniency()
        self.rater_table.setRowCount(len(stats))
        for row, s in enumerate(stats):
            avg = f"{s.average_given:.2f}" if s.average_given is not None else "—"
            self.rater_table.setItem(row, 0, _text_item(s.name))
            self.rater_table.setItem(row, 1, _num_item(avg))
            self.rater_table.setItem(row, 2, _num_item(str(s.rating_count)))

    def _reveal_now(self) -> None:
        from PySide6.QtWidgets import QMessageBox

        confirm = QMessageBox.question(
            self,
            "Reveal the leaderboard?",
            "This reveals all scores and rankings now. Continue?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm == QMessageBox.Yes:
            reveal.set_manually_unlocked(True)
            bus().reveal_changed.emit()
