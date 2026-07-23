"""The main leaderboard grid (default view).

A reflowing wall of cover-art cards. Default sort is average descending — it's a
leaderboard. Sort/filter/search are client-side over a single query. The grid
re-queries and rebuilds whenever anything changes anywhere (ratings entered, OST
added, reveal flipped) via the signal bus, so no manual refresh is needed.

Locked-reveal: while scores are hidden the cards drop their rank/score badges,
the "Average score" sort is disabled, ordering falls back to newest (so position
can't leak the ranking), and a banner offers an early reveal.
"""

from __future__ import annotations

from PySide6.QtCore import (
    QEasingCurve,
    QMargins,
    QParallelAnimationGroup,
    QPoint,
    QPropertyAnimation,
    QTimer,
)
from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QGraphicsOpacityEffect,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.config import EXPECTED_PEOPLE, EXPECTED_OSTS
from ost_tracker.db import ost_repo, people_repo
from ost_tracker.services import reveal
from ost_tracker.ui import icons, theme
from ost_tracker.ui.card_widget import HOVER_CLEARANCE, OstCard
from ost_tracker.ui.flow_layout import FlowLayout
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import EmptyState, TitleBlock, primary_button

SORT_AVG = "Average score"
SORT_NEW = "Newest"
SORT_ALPHA = "Alphabetical (A–Z)"


class GridView(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        # Cards are kept keyed by OST id and reused across refreshes so they can
        # slide to new positions on a re-sort instead of being recreated.
        self._cards: dict[int, OstCard] = {}
        self._slide_anims: list = []
        self._reveal_anims: list = []
        self._build_ui()
        self._connect_signals()
        # Seed so the first render isn't mistaken for a live lock->reveal flip.
        self._was_visible = reveal.scores_visible()
        self.refresh()

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(
            theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM
        )
        root.setSpacing(theme.HEADER_GAP)

        # Toolbar: sort, submitter filter, live search, and the primary action.
        toolbar = QHBoxLayout()
        toolbar.setSpacing(10)

        toolbar.addWidget(TitleBlock("Leaderboard", "Ranked by average score", "fa5s.trophy"))
        toolbar.addStretch(1)

        toolbar.addWidget(QLabel("Sort"))
        self.sort_combo = QComboBox()
        self.sort_combo.addItems([SORT_AVG, SORT_NEW, SORT_ALPHA])
        self.sort_combo.currentIndexChanged.connect(self.refresh)
        toolbar.addWidget(self.sort_combo)

        toolbar.addWidget(QLabel("Submitter"))
        self.submitter_combo = QComboBox()
        self.submitter_combo.currentIndexChanged.connect(self.refresh)
        toolbar.addWidget(self.submitter_combo)

        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText("Search title…")
        self.search_edit.setClearButtonEnabled(True)
        self.search_edit.addAction(icons.search(), QLineEdit.LeadingPosition)
        self.search_edit.textChanged.connect(self.refresh)
        self.search_edit.setFixedWidth(220)
        toolbar.addWidget(self.search_edit)

        self.add_button = primary_button(" Add OST", icons.add())
        self.add_button.clicked.connect(self._add_ost_clicked)
        toolbar.addWidget(self.add_button)

        root.addLayout(toolbar)

        # Locked-reveal banner.
        self.banner = QFrame()
        self.banner.setObjectName("revealBanner")
        self.banner.setStyleSheet(
            f"#revealBanner {{ background-color: {theme.SURFACE_RAISED};"
            f" border: 1px solid {theme.BORDER}; border-radius: 10px; }}"
        )
        banner_layout = QHBoxLayout(self.banner)
        banner_layout.setContentsMargins(14, 10, 14, 10)
        self.banner_label = QLabel()
        self.banner_label.setStyleSheet(f"color: {theme.TEXT_DIM};")
        banner_layout.addWidget(self.banner_label)
        banner_layout.addStretch(1)
        self.reveal_button = primary_button(" Reveal now", icons.unlock())
        self.reveal_button.clicked.connect(self._reveal_now)
        banner_layout.addWidget(self.reveal_button)
        root.addWidget(self.banner)

        # Scrollable card area.
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self._cards_host = QWidget()
        # Vertical clearance = the card's lift + visible glow, reserved above
        # the first row AND between/below every row (one constant, no first-row
        # special case), so a hovered card never clips against the toolbar or
        # its neighbours.
        self.flow = FlowLayout(
            self._cards_host, margin=0, spacing=theme.CARD_GAP, vspacing=HOVER_CLEARANCE
        )
        self.flow.setContentsMargins(QMargins(0, HOVER_CLEARANCE, 0, HOVER_CLEARANCE))
        self.scroll.setWidget(self._cards_host)
        root.addWidget(self.scroll, 1)

        self.empty_state = EmptyState()
        root.addWidget(self.empty_state, 1)

    def _connect_signals(self) -> None:
        b = bus()
        b.osts_changed.connect(self.refresh)
        b.ratings_changed.connect(self.refresh)
        b.people_changed.connect(self._reload_submitters)
        b.reveal_changed.connect(self.refresh)

    # --- data ---------------------------------------------------------------

    def _reload_submitters(self) -> None:
        current = self.submitter_combo.currentData()
        self.submitter_combo.blockSignals(True)
        self.submitter_combo.clear()
        self.submitter_combo.addItem("All submitters", None)
        for person in people_repo.list_people():
            self.submitter_combo.addItem(person.name, person.id)
        # Restore prior selection if still present.
        idx = self.submitter_combo.findData(current)
        self.submitter_combo.setCurrentIndex(idx if idx >= 0 else 0)
        self.submitter_combo.blockSignals(False)
        self.refresh()

    def refresh(self) -> None:
        # Submitter combo is lazily populated on first refresh.
        if self.submitter_combo.count() == 0:
            self._reload_submitters()
            return

        visible = reveal.scores_visible()
        self._update_banner(visible)
        self._update_sort_availability(visible)

        stats = ost_repo.list_osts_with_stats()

        # Filter by submitter.
        submitter_id = self.submitter_combo.currentData()
        if submitter_id is not None:
            stats = [s for s in stats if s.ost.submitter_id == submitter_id]

        # Live title search.
        query = self.search_edit.text().strip().lower()
        if query:
            stats = [s for s in stats if query in s.ost.title.lower()]

        stats = self._sort(stats, visible)
        self._render(stats)

    def _sort(self, stats: list, visible: bool) -> list:
        sort_mode = self.sort_combo.currentText()
        if not visible or sort_mode == SORT_NEW:
            if not visible:
                sort_mode = SORT_NEW  # never order by score while locked
        if sort_mode == SORT_ALPHA:
            return sorted(stats, key=lambda s: s.ost.title.lower())
        if sort_mode == SORT_NEW:
            return sorted(stats, key=lambda s: (s.ost.created_at, s.ost.id), reverse=True)
        # Average descending: rated first (by avg), then unrated by title.
        return sorted(
            stats,
            key=lambda s: (s.average is None, -(s.average or 0), s.ost.title.lower()),
        )

    def _render(self, stats: list) -> None:
        visible = reveal.scores_visible()

        # Remember where each retained card currently sits, so we can slide it
        # from there to its new slot after the layout reflows.
        prev_ids = set(self._cards.keys())
        old_pos = {oid: c.pos() for oid, c in self._cards.items()}
        new_ids = {s.ost.id for s in stats}

        # Drop cards for OSTs that are gone (deleted or filtered out).
        for oid in list(self._cards):
            if oid not in new_ids:
                self._cards[oid].deleteLater()
                del self._cards[oid]

        # Detach every item from the layout without destroying the widgets, then
        # re-add in the new order, creating cards only for genuinely new OSTs.
        while self.flow.count():
            self.flow.takeAt(0)

        fresh_ids: list[int] = []
        for s in stats:
            oid = s.ost.id
            card = self._cards.get(oid)
            if card is None:
                card = OstCard(s, show_scores=visible)
                card.clicked.connect(self._open_quick_rate)
                self._cards[oid] = card
                fresh_ids.append(oid)
            else:
                card.set_stats(s, visible)
            self.flow.addWidget(card)

        is_empty = len(stats) == 0
        self.scroll.setVisible(not is_empty)
        self.empty_state.setVisible(is_empty)
        if is_empty:
            self._configure_empty_state()
            self._was_visible = visible
            return

        # Force the flow layout to recompute positions NOW, synchronously, so the
        # cards are correctly placed this pass (top-left first) instead of keeping
        # stale slots until some later resize. This is what fixes filtered results
        # collapsing to the top-left.
        self.flow.invalidate()
        self.flow.activate()

        just_revealed = visible and not self._was_visible
        self._was_visible = visible
        # A changed visible *set* (search / filter / add / delete) is not a
        # re-sort: cards are already placed by activate(), so don't slide them in
        # from old slots. Only a pure reorder of the same set animates.
        set_changed = prev_ids != new_ids
        QTimer.singleShot(
            0, lambda: self._animate_layout(old_pos, fresh_ids, just_revealed, set_changed)
        )

    def _animate_layout(self, old_pos: dict, fresh_ids: list, just_revealed: bool,
                        set_changed: bool) -> None:
        if just_revealed:
            self._play_reveal_sequence()
            return
        if set_changed:
            return  # positions already final from activate(); no slide-in
        # Pure re-sort of the same cards: slide each from where it was to its new slot.
        self._slide_anims = []
        for oid, card in self._cards.items():
            if oid in fresh_ids:
                continue
            new_p = card.pos()
            old_p = old_pos.get(oid)
            if old_p is None or old_p == new_p:
                continue
            anim = QPropertyAnimation(card, b"pos", card)
            anim.setDuration(260)
            anim.setEasingCurve(QEasingCurve.OutCubic)
            anim.setStartValue(old_p)
            anim.setEndValue(new_p)
            anim.start()
            self._slide_anims.append(anim)

    def _play_reveal_sequence(self) -> None:
        """The payoff: when scores unlock, cards fade + rise into place one after
        another in rank order. Transient opacity effects only (removed on finish),
        so no card holds an effect at rest."""
        cards = [self.flow.itemAt(i).widget() for i in range(self.flow.count())]
        cards = [c for c in cards if c is not None]
        self._reveal_anims = []
        for i, card in enumerate(cards):
            eff = QGraphicsOpacityEffect(card)
            eff.setOpacity(0.0)
            card.setGraphicsEffect(eff)
            rest = card.pos()
            card.move(rest.x(), rest.y() + 14)

            fade = QPropertyAnimation(eff, b"opacity", card)
            fade.setDuration(360)
            fade.setEasingCurve(QEasingCurve.OutCubic)
            fade.setStartValue(0.0)
            fade.setEndValue(1.0)

            rise = QPropertyAnimation(card, b"pos", card)
            rise.setDuration(360)
            rise.setEasingCurve(QEasingCurve.OutCubic)
            rise.setStartValue(QPoint(rest.x(), rest.y() + 14))
            rise.setEndValue(rest)

            group = QParallelAnimationGroup(card)
            group.addAnimation(fade)
            group.addAnimation(rise)
            group.finished.connect(lambda c=card: c.setGraphicsEffect(None))
            QTimer.singleShot(i * 55, group.start)
            self._reveal_anims.append(group)

    def _configure_empty_state(self) -> None:
        # If nobody has been added, the real next step is People, not Add OST.
        if people_repo.count_people() == 0:
            self.empty_state.configure(
                "No people yet",
                "Add the competitors before you can add or rank OSTs.",
                " Go to People",
                lambda: bus().navigate_requested.emit("people"),
                icon_name="fa5s.users",
                button_icon=icons.icon("fa5s.users"),
            )
        elif self.search_edit.text().strip() or self.submitter_combo.currentData() is not None:
            self.empty_state.configure(
                "No matches",
                "No OSTs match the current search or submitter filter.",
                " Add OST",
                self._add_ost_clicked,
                icon_name="fa5s.search",
                button_icon=icons.add(),
            )
        else:
            self.empty_state.configure(
                "No OSTs yet",
                "Add the first submission — cover art is fetched automatically.",
                " Add OST",
                self._add_ost_clicked,
                icon_name="fa5s.compact-disc",
                button_icon=icons.add(),
            )

    def _open_quick_rate(self, ost_id: int) -> None:
        """Card click: rate this one track in place. Modal, so the grid keeps
        its search text, filter, and scroll position untouched behind it; the
        detail view stays reachable via the dialog's Full-details button."""
        from ost_tracker.ui.quick_rate_dialog import QuickRateDialog

        QuickRateDialog(ost_id, self.window()).exec()

    def _add_ost_clicked(self) -> None:
        # MainWindow.open_add_ost redirects to People if there are no people.
        # An active submitter filter travels along so the dialog opens
        # pre-assigned to that person.
        bus().open_add_ost_requested.emit("", "", self.submitter_combo.currentData())

    # --- reveal banner ------------------------------------------------------

    def _update_banner(self, visible: bool) -> None:
        if visible:
            self.banner.setVisible(False)
            return
        self.banner.setVisible(True)
        filled = reveal.filled_cells()
        expected = reveal.expected_cells() or (EXPECTED_PEOPLE * EXPECTED_OSTS)
        self.banner_label.setText(
            f"🔒  Leaderboard hidden until the reveal — {filled}/{expected} ratings entered"
        )

    def _update_sort_availability(self, visible: bool) -> None:
        # Disable "Average score" while locked so position can't leak rank.
        model = self.sort_combo.model()
        item = model.item(0)
        if item is not None:
            item.setEnabled(visible)
        if not visible and self.sort_combo.currentIndex() == 0:
            self.sort_combo.blockSignals(True)
            self.sort_combo.setCurrentIndex(1)  # Newest
            self.sort_combo.blockSignals(False)

    def _reveal_now(self) -> None:
        confirm = QMessageBox.question(
            self,
            "Reveal the leaderboard?",
            "This reveals all scores and rankings now, before every rating is in.\n"
            "You can't un-see it. Continue?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm == QMessageBox.Yes:
            reveal.set_manually_unlocked(True)
            bus().reveal_changed.emit()

    def focus_search(self) -> None:
        self.search_edit.setFocus()
        self.search_edit.selectAll()
