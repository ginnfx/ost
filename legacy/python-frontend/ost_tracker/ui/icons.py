"""Consistent icon set via qtawesome, with a graceful fallback to an empty
icon if the font backend is unavailable (keeps the app launchable anywhere)."""

from __future__ import annotations

from PySide6.QtGui import QIcon

from ost_tracker.ui.theme import TEXT, TEXT_DIM

_DEFAULT_COLOR = TEXT


def icon(name: str, color: str = _DEFAULT_COLOR) -> QIcon:
    try:
        import qtawesome as qta

        return qta.icon(name, color=color)
    except Exception:
        return QIcon()


# Named shortcuts so screens don't hard-code Font Awesome identifiers.
def add() -> QIcon:
    return icon("fa5s.plus")


def edit() -> QIcon:
    return icon("fa5s.pen")


def delete() -> QIcon:
    return icon("fa5s.trash-alt")


def refresh() -> QIcon:
    return icon("fa5s.sync-alt")


def search() -> QIcon:
    return icon("fa5s.search", TEXT_DIM)


def link() -> QIcon:
    return icon("fa5s.external-link-alt")


def back() -> QIcon:
    return icon("fa5s.arrow-left")


def lock() -> QIcon:
    return icon("fa5s.lock")


def unlock() -> QIcon:
    return icon("fa5s.lock-open")


def image() -> QIcon:
    return icon("fa5s.image")


def trophy(color: str = _DEFAULT_COLOR) -> QIcon:
    return icon("fa5s.trophy", color)
