"""Theme regression tests: the three bundled fonts must resolve (not fall back
to a system font), and the palette must carry the brand accent with no purple.

These guard the two silent-failure modes the UI spec calls out: a font quietly
falling back to Arial/SF, and a library default (blue/purple) leaking into the
selection highlight.
"""

from __future__ import annotations

import pytest
from PySide6.QtGui import QPalette
from PySide6.QtWidgets import QApplication

from ost_tracker.ui import fonts, theme, tokens


@pytest.fixture()
def app(qtbot):
    # qtbot provides the QApplication; apply the real theme onto it.
    theme.apply_theme(QApplication.instance())
    return QApplication.instance()


def test_required_fonts_load(app):
    fonts.load_fonts()
    assert fonts.missing_families() == []


def test_fonts_resolve_not_system_fallback(app):
    # Every role must resolve to its bundled family, not a system substitute.
    assert fonts.verify_fonts() == []


def test_palette_highlight_is_accent(app):
    pal = app.palette()
    assert pal.color(QPalette.Highlight).name().lower() == tokens.ACCENT.lower()
    assert pal.color(QPalette.Inactive, QPalette.Highlight).name().lower() == tokens.ACCENT.lower()


def _is_purple_or_blue(c) -> bool:
    # Purple/violet/blue = blue is the dominant channel. Warm hues (brown, gold,
    # rust, green) are red-dominant; the score-high green is green-dominant — both
    # are allowed. A small tolerance keeps near-neutral greys from tripping.
    return c.blue() > max(c.red(), c.green()) + 6


def test_no_purple_in_palette(app):
    # Machine-checkable form of the "no purple/violet/blue accent" ban.
    pal = app.palette()
    roles = [
        QPalette.Window, QPalette.Base, QPalette.Highlight, QPalette.Button,
        QPalette.Text, QPalette.WindowText, QPalette.Link, QPalette.Mid, QPalette.Dark,
    ]
    for role in roles:
        c = pal.color(role)
        assert not _is_purple_or_blue(c), f"{role} looks cool/purple: {c.name()}"


def test_tokens_have_no_purple():
    # Guard the token source directly: no token is blue-dominant.
    from PySide6.QtGui import QColor

    for name in dir(tokens):
        value = getattr(tokens, name)
        if isinstance(value, str) and value.startswith("#") and len(value) == 7:
            assert not _is_purple_or_blue(QColor(value)), f"token {name}={value} is blue/purple"
    # Placeholder gradients too (the old set was purple/violet).
    for top, bottom in tokens.PLACEHOLDER_GRADIENTS:
        for hexval in (top, bottom):
            assert not _is_purple_or_blue(QColor(hexval)), f"placeholder {hexval} is blue/purple"
