"""Reusable UI building blocks: styled buttons with a clear hierarchy, and a
configurable empty-state panel whose call-to-action actually resolves the empty
state (navigate to People, open Add OST, …) rather than describing it in text.
"""

from __future__ import annotations

from typing import Callable, Optional

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import (
    QButtonGroup,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo, people_repo
from ost_tracker.ui import icons, theme
from ost_tracker.ui.signals import bus


class TitleBlock(QWidget):
    """A unified screen header: an accent icon chip, a bold title, and an
    optional dim subtitle. Used at the top-left of every screen so headings look
    identical everywhere."""

    def __init__(
        self,
        title: str,
        subtitle: str | None = None,
        icon_name: str | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(12)

        if icon_name:
            chip = QLabel()
            chip.setFixedSize(34, 34)
            chip.setAlignment(Qt.AlignCenter)
            chip.setObjectName("iconChip")
            chip.setPixmap(icons.icon(icon_name, theme.ACCENT).pixmap(18, 18))
            chip.setStyleSheet(
                f"background: {theme.SURFACE_RAISED};"
            )
            row.addWidget(chip)

        text_col = QVBoxLayout()
        text_col.setContentsMargins(0, 0, 0, 0)
        text_col.setSpacing(1)
        title_lbl = QLabel(title)
        title_lbl.setFont(theme.display_font(18))
        title_lbl.setStyleSheet(f"color:{theme.TEXT};")
        text_col.addWidget(title_lbl)
        if subtitle:
            sub = QLabel(subtitle)
            sub.setStyleSheet(f"color:{theme.TEXT_DIM}; font-size:11px;")
            text_col.addWidget(sub)
        row.addLayout(text_col)


def attach_source_completer(edit) -> None:
    """Autocomplete a source/franchise field against the distinct values
    already in the library, so a franchise entered once never needs retyping
    exactly. Case-insensitive, matches anywhere in the string."""
    from PySide6.QtWidgets import QCompleter

    completer = QCompleter(ost_repo.list_sources(), edit)
    completer.setCaseSensitivity(Qt.CaseInsensitive)
    completer.setFilterMode(Qt.MatchContains)
    edit.setCompleter(completer)


def primary_button(text: str, icon: Optional[QIcon] = None) -> QPushButton:
    btn = QPushButton(text)
    btn.setObjectName("primaryButton")
    btn.setCursor(Qt.PointingHandCursor)
    if icon is not None:
        btn.setIcon(icon)
    return btn


def ghost_button(text: str, icon: Optional[QIcon] = None) -> QPushButton:
    btn = QPushButton(text)
    btn.setObjectName("ghostButton")
    btn.setCursor(Qt.PointingHandCursor)
    if icon is not None:
        btn.setIcon(icon)
    return btn


def danger_button(text: str, icon: Optional[QIcon] = None) -> QPushButton:
    btn = QPushButton(text)
    btn.setObjectName("dangerButton")
    btn.setCursor(Qt.PointingHandCursor)
    if icon is not None:
        btn.setIcon(icon)
    return btn


class EmptyState(QWidget):
    """A centered icon + title + subtitle + a single primary call-to-action.

    Reconfigurable via :meth:`configure` so the same widget can present
    "add people first" vs. "add an OST" depending on runtime state.
    """

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        layout.setSpacing(10)

        self._icon = QLabel()
        self._icon.setAlignment(Qt.AlignCenter)
        self._icon.setFixedSize(84, 84)
        self._icon.setStyleSheet(
            f"background:{theme.ACCENT_SOFT}; border-radius:42px;"
        )
        layout.addWidget(self._icon, 0, Qt.AlignCenter)

        self._title = QLabel()
        self._title.setAlignment(Qt.AlignCenter)
        self._title.setStyleSheet("font-size: 19px; font-weight: 700;")
        layout.addWidget(self._title)

        self._subtitle = QLabel()
        self._subtitle.setAlignment(Qt.AlignCenter)
        self._subtitle.setWordWrap(True)
        self._subtitle.setStyleSheet(f"color: {theme.TEXT_DIM}; font-size: 13px;")
        layout.addWidget(self._subtitle)

        self._button = primary_button("")
        self._button.setMinimumWidth(180)
        layout.addWidget(self._button, 0, Qt.AlignCenter)

        self._callback: Optional[Callable[[], None]] = None
        self._button.clicked.connect(self._on_click)

    def _on_click(self) -> None:
        if self._callback is not None:
            self._callback()

    def configure(
        self,
        title: str,
        subtitle: str,
        button_text: str,
        on_click: Callable[[], None],
        icon_name: str = "fa5s.inbox",
        button_icon: Optional[QIcon] = None,
    ) -> None:
        self._title.setText(title)
        self._subtitle.setText(subtitle)
        self._button.setText(button_text)
        self._button.setIcon(button_icon if button_icon is not None else QIcon())
        self._callback = on_click
        pm = icons.icon(icon_name, theme.ACCENT_HOVER).pixmap(38, 38)
        self._icon.setPixmap(pm)

    def configure_needs_data(self, no_osts_subtitle: str) -> None:
        """Standard two-branch empty state for screens that need people + OSTs:
        route to People if nobody exists yet, otherwise to Add OST."""
        if people_repo.count_people() == 0:
            self.configure(
                "No people yet",
                "Add the competitors first — every screen depends on them.",
                " Go to People",
                lambda: bus().navigate_requested.emit("people"),
                icon_name="fa5s.users",
                button_icon=icons.icon("fa5s.users"),
            )
        else:
            self.configure(
                "No OSTs yet",
                no_osts_subtitle,
                " Add OST",
                lambda: bus().open_add_ost_requested.emit("", "", None),
                icon_name="fa5s.compact-disc",
                button_icon=icons.add(),
            )

    @staticmethod
    def has_data() -> bool:
        return people_repo.count_people() > 0 and ost_repo.count_osts() > 0


# A joined pill toggle used to switch views *within* a screen (never for
# navigation between screens — that stays in the sidebar). The first and last
# segments get the rounded outer corners; middles stay square, so N buttons read
# as one control.
_SEG_QSS = """
QPushButton {{ background:{raised}; color:{dim}; border:1px solid {border};
    padding:7px 16px; font-weight:600; }}
QPushButton:hover {{ color:{text}; }}
QPushButton:checked {{ background:{accent}; color:{on_accent}; border-color:{accent}; }}
QPushButton#segLeft {{ border-top-left-radius:8px; border-bottom-left-radius:8px;
    border-right:none; }}
QPushButton#segMid {{ border-right:none; }}
QPushButton#segRight {{ border-top-right-radius:8px; border-bottom-right-radius:8px; }}
"""


class SegmentedControl(QWidget):
    """An exclusive, joined set of toggle buttons. Emits ``changed(index)``."""

    changed = Signal(int)

    def __init__(self, labels: list[str], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._group = QButtonGroup(self)
        self._group.setExclusive(True)
        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(0)
        self._buttons: list[QPushButton] = []
        last = len(labels) - 1
        for i, label in enumerate(labels):
            name = "segLeft" if i == 0 else "segRight" if i == last else "segMid"
            btn = QPushButton(label)
            btn.setObjectName(name)
            btn.setCheckable(True)
            btn.setCursor(Qt.PointingHandCursor)
            self._group.addButton(btn, i)
            row.addWidget(btn)
            self._buttons.append(btn)
        self.setStyleSheet(
            _SEG_QSS.format(
                raised=theme.SURFACE_RAISED, dim=theme.TEXT_DIM, border=theme.BORDER,
                text=theme.TEXT, accent=theme.ACCENT, on_accent=theme.ON_ACCENT,
            )
        )
        self._group.idClicked.connect(self.changed.emit)
        if self._buttons:
            self._buttons[0].setChecked(True)

    def setCurrentIndex(self, index: int) -> None:
        if 0 <= index < len(self._buttons):
            self._buttons[index].setChecked(True)

    def currentIndex(self) -> int:
        return self._group.checkedId()
