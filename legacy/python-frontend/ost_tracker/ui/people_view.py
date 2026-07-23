"""People screen — a bare roster list, not a record editor.

One "+ Add person" affordance reveals an inline input row directly in the
list; Enter commits and the new row animates in (slide + brief gold flash,
the "noticeable" motion tier — see ``_flash_in``). Renames are click-to-edit
in the row itself (double-click the name, Enter commits, Esc cancels) and
deletes are a bare per-row icon armed by a first click and confirmed by a
second — no forms, no side panel, no modal.

Per-rater leniency lives here too (relocated from the retired Stats tab): it
is data about raters as people, so each row carries a dim mono readout of the
average score that person hands out.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QEasingCurve, Qt, QTimer, QVariantAnimation, Signal
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QScrollArea,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.services import rater_stats
from ost_tracker.ui import icons, theme
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import TitleBlock, primary_button

# The add/flash motion tier: noticeable but snappy (per the motion tokens).
_SLIDE_MS = 180
_FLASH_MS = 380
_SLIDE_PX = 24
_DISARM_MS = 3000  # an armed delete quietly disarms after this


def _leniency_text(stat) -> str:
    if stat is None or stat.average_given is None:
        return "no ratings yet"
    return f"gives {stat.average_given:.2f} avg · {stat.rating_count} rated"


class _PersonRow(QFrame):
    """One roster row: name (click-to-edit), leniency readout, bare delete."""

    delete_requested = Signal(int)   # person_id
    renamed = Signal()

    def __init__(self, person, stat, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.person_id = person.id
        self._name = person.name
        self._armed = False
        self.setObjectName("personRow")
        self._set_row_style(None)

        row = QHBoxLayout(self)
        row.setContentsMargins(14, 8, 10, 8)
        row.setSpacing(10)

        self.name_label = QLabel(person.name)
        self.name_label.setStyleSheet("font-size:13px;")
        self.name_label.setToolTip("Double-click to rename")
        row.addWidget(self.name_label)

        self.name_edit = QLineEdit(person.name)
        self.name_edit.setVisible(False)
        self.name_edit.setMaximumWidth(240)
        self.name_edit.returnPressed.connect(self._commit_rename)
        row.addWidget(self.name_edit)

        row.addStretch(1)

        self.leniency = QLabel(_leniency_text(stat))
        self.leniency.setFont(theme.mono_font(9))
        self.leniency.setStyleSheet(f"color:{theme.TEXT_FAINT};")
        self.leniency.setToolTip("Leniency — the average score this person gives")
        row.addWidget(self.leniency)

        # Armed-delete inline notice (impact summary), hidden until first click.
        self.impact = QLabel("")
        self.impact.setStyleSheet(f"color:{theme.DANGER_TEXT}; font-size:10px;")
        self.impact.setVisible(False)
        row.addWidget(self.impact)

        self.delete_btn = QToolButton()
        self.delete_btn.setIcon(icons.delete())
        self.delete_btn.setCursor(Qt.PointingHandCursor)
        self.delete_btn.setToolTip("Remove (click twice)")
        self.delete_btn.setStyleSheet("QToolButton { border: none; background: transparent; padding: 2px; }")
        self.delete_btn.clicked.connect(self._on_delete_clicked)
        row.addWidget(self.delete_btn)

        self._disarm_timer = QTimer(self)
        self._disarm_timer.setSingleShot(True)
        self._disarm_timer.setInterval(_DISARM_MS)
        self._disarm_timer.timeout.connect(self._disarm)

    # --- rename (click-to-edit, no Save button) ---------------------------

    def mouseDoubleClickEvent(self, event) -> None:  # noqa: N802
        self.start_rename()
        super().mouseDoubleClickEvent(event)

    def start_rename(self) -> None:
        self.name_edit.setText(self._name)
        self.name_label.setVisible(False)
        self.name_edit.setVisible(True)
        self.name_edit.setFocus()
        self.name_edit.selectAll()

    def _commit_rename(self) -> None:
        name = self.name_edit.text().strip()
        if not name or name == self._name:
            self._cancel_rename()
            return
        try:
            people_repo.rename_person(self.person_id, name)
        except Exception as exc:  # duplicate name (UNIQUE), etc.
            QMessageBox.warning(self, "Could not rename", str(exc))
            self.name_edit.setFocus()
            return
        self._name = name
        self.name_label.setText(name)
        self._cancel_rename()
        bus().people_changed.emit()
        self.renamed.emit()

    def _cancel_rename(self) -> None:
        self.name_edit.setVisible(False)
        self.name_label.setVisible(True)

    def keyPressEvent(self, event) -> None:  # noqa: N802
        if self.name_edit.isVisible() and event.key() == Qt.Key_Escape:
            self._cancel_rename()
            return
        super().keyPressEvent(event)

    # --- delete (bare icon, second click confirms) -------------------------

    def _on_delete_clicked(self) -> None:
        if not self._armed:
            self._arm()
            return
        self._disarm_timer.stop()
        self.delete_requested.emit(self.person_id)

    def _arm(self) -> None:
        self._armed = True
        submitted = len(ost_repo.osts_by_submitter(self.person_id))
        ratings = len(rating_repo.scores_by_rater(self.person_id))
        bits = ["click again to remove"]
        if ratings:
            bits.append(f"deletes {ratings} rating{'s' if ratings != 1 else ''}")
        if submitted:
            bits.append(f"orphans {submitted} OST{'s' if submitted != 1 else ''}")
        self.impact.setText(" · ".join(bits))
        self.impact.setVisible(True)
        self.leniency.setVisible(False)
        self.delete_btn.setIcon(icons.icon("fa5s.trash-alt", theme.DANGER))
        self._set_row_style(theme.DANGER_BORDER)
        self._disarm_timer.start()

    def _disarm(self) -> None:
        self._armed = False
        self.impact.setVisible(False)
        self.leniency.setVisible(True)
        self.delete_btn.setIcon(icons.delete())
        self._set_row_style(None)

    # --- styling / animation ------------------------------------------------

    def _set_row_style(self, border: Optional[str], bg_rgba: str | None = None) -> None:
        bg = bg_rgba or theme.SURFACE
        self.setStyleSheet(
            f"#personRow {{ background:{bg}; border:1px solid {border or theme.BORDER};"
            f" border-radius:8px; }}"
        )

    def set_leniency(self, stat) -> None:
        self.leniency.setText(_leniency_text(stat))

    def flash_in(self) -> None:
        """Entry flourish for a freshly-added person: the row slides in from the
        left while a gold wash fades back to the resting surface. Deliberately
        GOLD (the achievement colour), not the green accent — per the §1 spec."""
        gold = QColor(theme.GOLD)
        margins = self.layout().contentsMargins()
        base_left = margins.left()

        anim = QVariantAnimation(self)
        anim.setStartValue(0.0)
        anim.setEndValue(1.0)
        anim.setDuration(_SLIDE_MS)
        anim.setEasingCurve(QEasingCurve.OutCubic)

        def _step(t: float) -> None:
            margins.setLeft(base_left + int(_SLIDE_PX * (1.0 - t)))
            self.layout().setContentsMargins(margins)

        anim.valueChanged.connect(_step)
        anim.start()
        self._slide_anim = anim  # keep alive

        flash = QVariantAnimation(self)
        flash.setStartValue(110)
        flash.setEndValue(0)
        flash.setDuration(_FLASH_MS)
        flash.setEasingCurve(QEasingCurve.OutCubic)

        def _wash(alpha: int) -> None:
            if alpha <= 0:
                self._set_row_style(None)
                return
            rgba = f"rgba({gold.red()},{gold.green()},{gold.blue()},{alpha / 255:.3f})"
            self._set_row_style(theme.GOLD, bg_rgba=rgba)

        flash.valueChanged.connect(_wash)
        flash.finished.connect(lambda: self._set_row_style(None))
        flash.start()
        self._flash_anim = flash


class PeopleScreen(QWidget):
    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._rows: dict[int, _PersonRow] = {}
        self._just_added: Optional[int] = None
        self._build_ui()
        b = bus()
        b.ratings_changed.connect(self._refresh_leniency)
        b.osts_changed.connect(self._refresh_leniency)
        self._reload()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN, theme.PAGE_MARGIN_BOTTOM)
        root.setSpacing(theme.HEADER_GAP)

        header = QHBoxLayout()
        header.addWidget(TitleBlock("People", "The competitors — add these first", "fa5s.users"))
        header.addStretch(1)
        self.add_btn = primary_button(" Add person", icons.add())
        self.add_btn.clicked.connect(self.start_add)
        header.addWidget(self.add_btn)
        root.addLayout(header)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        self._list_layout = QVBoxLayout(host)
        self._list_layout.setContentsMargins(0, 0, 0, 0)
        self._list_layout.setSpacing(6)
        self._list_layout.setAlignment(Qt.AlignTop)

        # The inline add row lives inside the list itself (revealed on demand,
        # first when the roster is empty) — there is no separate form.
        self.add_row = QFrame()
        self.add_row.setObjectName("personAddRow")
        self.add_row.setStyleSheet(
            f"#personAddRow {{ background:{theme.SURFACE}; border:1px dashed {theme.BORDER};"
            f" border-radius:8px; }}"
        )
        add_layout = QHBoxLayout(self.add_row)
        add_layout.setContentsMargins(14, 6, 10, 6)
        self.add_edit = QLineEdit()
        self.add_edit.setPlaceholderText("Name — Enter adds, Esc closes")
        self.add_edit.returnPressed.connect(self._commit_add)
        add_layout.addWidget(self.add_edit)
        self.add_row.setVisible(False)

        self._list_layout.addWidget(self.add_row)
        scroll.setWidget(host)
        root.addWidget(scroll, 1)

        self.empty_hint = QLabel("No people yet — add the competitors with “Add person”.")
        self.empty_hint.setStyleSheet(f"color:{theme.TEXT_DIM};")
        self.empty_hint.setAlignment(Qt.AlignCenter)
        root.addWidget(self.empty_hint)

    # --- data ---------------------------------------------------------------

    def _reload(self) -> None:
        for row_widget in self._rows.values():
            row_widget.deleteLater()
        self._rows.clear()

        people = people_repo.list_people()
        stats = {s.person_id: s for s in rater_stats.rater_leniency()}
        # Insert above the add row so it stays pinned to the list's tail.
        for person in people:
            row_widget = _PersonRow(person, stats.get(person.id))
            row_widget.delete_requested.connect(self._delete)
            self._list_layout.insertWidget(self._list_layout.count() - 1, row_widget)
            self._rows[person.id] = row_widget

        self.empty_hint.setVisible(not people)
        if not people:
            self.start_add()

        if self._just_added is not None:
            fresh = self._rows.get(self._just_added)
            self._just_added = None
            if fresh is not None:
                fresh.flash_in()

    def _refresh_leniency(self) -> None:
        stats = {s.person_id: s for s in rater_stats.rater_leniency()}
        for person_id, row_widget in self._rows.items():
            row_widget.set_leniency(stats.get(person_id))

    # --- add ------------------------------------------------------------------

    def start_add(self) -> None:
        self.add_row.setVisible(True)
        self.add_edit.setFocus()

    def keyPressEvent(self, event) -> None:  # noqa: N802
        if self.add_row.isVisible() and event.key() == Qt.Key_Escape:
            self.add_edit.clear()
            self.add_row.setVisible(False)
            return
        super().keyPressEvent(event)

    def _commit_add(self) -> None:
        name = self.add_edit.text().strip()
        if not name:
            return
        try:
            person = people_repo.add_person(name)
        except Exception as exc:  # duplicate name (UNIQUE), etc.
            QMessageBox.warning(self, "Could not add", str(exc))
            return
        # Stay open and cleared: seeding the roster is a run of quick adds.
        self.add_edit.clear()
        self.add_edit.setFocus()
        self._just_added = person.id
        bus().people_changed.emit()
        self._reload()

    # --- delete ----------------------------------------------------------------

    def _delete(self, person_id: int) -> None:
        person = people_repo.get_person(person_id)
        if person is None:
            return
        submitted = len(ost_repo.osts_by_submitter(person_id))
        ratings = len(rating_repo.scores_by_rater(person_id))
        people_repo.delete_person(person_id)
        bus().people_changed.emit()
        if submitted or ratings:
            bus().osts_changed.emit()
            bus().ratings_changed.emit()
        self._reload()
