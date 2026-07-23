"""Dark theme, typography, and the one authoritative stylesheet.

A high-contrast dark theme: near-black base, pure-white text, emerald-green
selection/focus accent, gold rank/achievement, rust-orange tertiary variety.
Flat fills, no gradients. The signature motif (chamfered leaderboard
cards + diamond rank badges) is deliberately reserved for the leaderboard so it
stays signature; everything else stays disciplined.

All colours and font names come from :mod:`ost_tracker.ui.tokens` — this module
holds zero hex literals. We apply ONE self-contained QSS over a Fusion base
palette (no third-party theme library), so no library default can leak through:
with ``QPalette.Highlight`` set to the accent, there is simply no blue anywhere
for Qt to fall back to.
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtGui import QColor, QFont, QPalette
from PySide6.QtWidgets import QApplication

from ost_tracker.ui import fonts
from ost_tracker.ui.tokens import (
    ACCENT,
    ACCENT_2,
    ACCENT_DIM,
    ACCENT_HOVER,
    ACCENT_SOFT,
    ACCENT_TERTIARY,
    BASE_INPUT,
    BG,
    BORDER,
    BORDER_DARK,
    BORDER_HOVER,
    BRONZE,
    CARD_GAP,
    DANGER,
    DANGER_BORDER,
    DANGER_HOVER_BG,
    DANGER_TEXT,
    GOLD,
    HEADER_GAP,
    HOT,
    INCOMPLETE_TINT,
    INK,
    MISSING_BORDER,
    MISSING_FILL,
    MISSING_TEXT,
    ON_ACCENT,
    PAGE_MARGIN,
    PAGE_MARGIN_BOTTOM,
    RATE_STRIP_GREEN,
    RATE_STRIP_GREEN_SOFT,
    ROW_GAP,
    SCORE_HIGH,
    SCORE_LOW,
    SCORE_MID,
    SELF_TINT,
    SIDEBAR_BG,
    SILVER,
    SURFACE,
    SURFACE_HOVER,
    SURFACE_RAISED,
    TEXT,
    TEXT_DIM,
    TEXT_FAINT,
)

# Typography aliases (kept for the many `theme.DISPLAY_FONT` call sites).
DISPLAY_FONT = fonts.DISPLAY_FAMILY   # headers: Chakra Petch, bold, uppercase
BODY_FONT = fonts.BODY_FAMILY         # body: IBM Plex Sans
MONO_FONT = fonts.MONO_FAMILY         # numeric readouts: JetBrains Mono

# theme re-exports every token so call sites can use `theme.X`; declaring the
# public surface here keeps those re-exports intentional (not dead imports).
__all__ = [
    "ACCENT", "ACCENT_2", "ACCENT_HOVER", "ACCENT_DIM", "ACCENT_SOFT", "ACCENT_TERTIARY", "HOT",
    "BG", "SIDEBAR_BG", "SURFACE", "SURFACE_RAISED", "SURFACE_HOVER", "BORDER", "BORDER_DARK", "BORDER_HOVER",
    "BASE_INPUT", "TEXT", "TEXT_DIM", "TEXT_FAINT", "ON_ACCENT", "INK",
    "SCORE_HIGH", "SCORE_MID", "SCORE_LOW", "GOLD", "SILVER", "BRONZE",
    "SELF_TINT", "DANGER", "DANGER_TEXT", "DANGER_BORDER", "DANGER_HOVER_BG", "INCOMPLETE_TINT",
    "RATE_STRIP_GREEN", "RATE_STRIP_GREEN_SOFT",
    "MISSING_FILL", "MISSING_BORDER", "MISSING_TEXT",
    "PAGE_MARGIN", "PAGE_MARGIN_BOTTOM", "HEADER_GAP", "ROW_GAP", "CARD_GAP",
    "DISPLAY_FONT", "BODY_FONT", "MONO_FONT",
    "score_color", "medal_color", "display_font", "mono_font", "extra_qss", "apply_theme",
]

# Glyph assets referenced by the QSS. Absolute paths so `url(...)` resolves
# inside a packaged .app (a relative url would not).
_ASSET_DIR = Path(__file__).resolve().parent.parent / "assets"
_CHECK_SVG = (_ASSET_DIR / "check.svg").as_posix()
_CHEVRON_SVG = (_ASSET_DIR / "chevron.svg").as_posix()


def score_color(score: float) -> str:
    if score >= 8:
        return SCORE_HIGH
    if score >= 5:
        return SCORE_MID
    return SCORE_LOW


def medal_color(rank: int | None) -> str | None:
    """Gold/silver/bronze for the top 3, else None (neutral chip)."""
    return {1: GOLD, 2: SILVER, 3: BRONZE}.get(rank) if rank else None


def display_font(point_size: int, *, weight: QFont.Weight = QFont.Bold, upper: bool = True) -> QFont:
    """A Chakra Petch display font — bold, uppercase, tight letter-spacing — for
    headers and the leaderboard motif."""
    f = QFont(DISPLAY_FONT)
    f.setPointSize(point_size)
    f.setWeight(weight)
    f.setCapitalization(QFont.AllUppercase if upper else QFont.MixedCase)
    f.setLetterSpacing(QFont.PercentageSpacing, 98)  # tight
    return f


def mono_font(point_size: int, *, weight: QFont.Weight = QFont.Bold) -> QFont:
    """A JetBrains Mono font for scores and numeric readouts."""
    f = QFont(MONO_FONT)
    f.setPointSize(point_size)
    f.setWeight(weight)
    return f


def _fusion_dark_palette() -> QPalette:
    """A fully-populated dark palette. Every role is set (incl. the Inactive
    group and mid-tones) so any widget Fusion draws without an explicit QSS rule
    still reads on-brand and never falls back to a stock grey/blue."""
    p = QPalette()
    p.setColor(QPalette.Window, QColor(BG))
    p.setColor(QPalette.WindowText, QColor(TEXT))
    p.setColor(QPalette.Base, QColor(BASE_INPUT))
    p.setColor(QPalette.AlternateBase, QColor(SURFACE_RAISED))
    p.setColor(QPalette.ToolTipBase, QColor(SURFACE_RAISED))
    p.setColor(QPalette.ToolTipText, QColor(TEXT))
    p.setColor(QPalette.Text, QColor(TEXT))
    p.setColor(QPalette.Button, QColor(SURFACE_RAISED))
    p.setColor(QPalette.ButtonText, QColor(TEXT))
    p.setColor(QPalette.BrightText, QColor(HOT))
    p.setColor(QPalette.Link, QColor(ACCENT))
    p.setColor(QPalette.Highlight, QColor(ACCENT))
    p.setColor(QPalette.HighlightedText, QColor(ON_ACCENT))
    p.setColor(QPalette.PlaceholderText, QColor(TEXT_DIM))
    # On-brand bevel/border ramp so Fusion-drawn edges aren't grey.
    p.setColor(QPalette.Light, QColor(SURFACE_HOVER))
    p.setColor(QPalette.Midlight, QColor(SURFACE_RAISED))
    p.setColor(QPalette.Mid, QColor(BORDER))
    p.setColor(QPalette.Dark, QColor(SIDEBAR_BG))
    p.setColor(QPalette.Shadow, QColor(INK))
    # Keep selection green when the window loses focus (else it greys out).
    p.setColor(QPalette.Inactive, QPalette.Highlight, QColor(ACCENT))
    p.setColor(QPalette.Inactive, QPalette.HighlightedText, QColor(ON_ACCENT))
    disabled = QColor(TEXT_FAINT)
    p.setColor(QPalette.Disabled, QPalette.Text, disabled)
    p.setColor(QPalette.Disabled, QPalette.ButtonText, disabled)
    p.setColor(QPalette.Disabled, QPalette.WindowText, disabled)
    p.setColor(QPalette.Disabled, QPalette.Highlight, QColor(SURFACE_HOVER))
    return p


def extra_qss() -> str:
    return f"""
    QMainWindow, QDialog {{ background-color: {BG}; }}
    QWidget {{ font-family: "{BODY_FONT}"; color: {TEXT}; }}
    QLabel {{ background: transparent; color: {TEXT}; }}
    QLabel:disabled {{ color: {TEXT_FAINT}; }}
    QLabel#iconChip {{
        border: 1px solid {BORDER_DARK};
        border-radius: 9px;
    }}
    QAbstractItemView {{ outline: 0; }}

    /* Sidebar navigation */
    QListWidget#sidebar {{
        background-color: {SIDEBAR_BG};
        border: none;
        outline: 0;
        padding: 6px 8px;
    }}
    QListWidget#sidebar::item {{
        color: {TEXT_DIM};
        padding: 9px 12px;
        margin: 2px 4px;
        border-radius: 8px;
        border-left: 3px solid transparent;
        font-family: "{DISPLAY_FONT}";
        font-weight: 600;
    }}
    QListWidget#sidebar::item:hover {{ background-color: {SURFACE_HOVER}; color: {TEXT}; }}
    /* Active: emerald-green fill AND a gold accent bar — never colour alone. */
    QListWidget#sidebar::item:selected {{
        background-color: {ACCENT};
        color: {ON_ACCENT};
        border-left: 3px solid {GOLD};
    }}

    /* Bare buttons (QMessageBox, dialogs) — never leave to Fusion chrome. */
    QPushButton {{
        background-color: {SURFACE_RAISED};
        color: {TEXT};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 7px 14px;
    }}
    QPushButton:hover {{ border-color: {ACCENT}; }}
    QPushButton:pressed {{ background-color: {SURFACE_HOVER}; }}
    QPushButton:default {{ border-color: {ACCENT}; }}
    QPushButton:disabled {{ background-color: {SURFACE}; color: {TEXT_FAINT}; }}

    QPushButton#primaryButton {{
        background-color: {ACCENT};
        color: {ON_ACCENT};
        border: none;
        border-radius: 8px;
        padding: 8px 16px;
        font-weight: 700;
    }}
    QPushButton#primaryButton:hover {{ background-color: {ACCENT_HOVER}; border: none; }}
    QPushButton#primaryButton:pressed {{ background-color: {ACCENT_DIM}; }}
    QPushButton#primaryButton:disabled {{ background-color: {SURFACE_RAISED}; color: {TEXT_FAINT}; }}

    QPushButton#ghostButton {{
        background-color: {SURFACE_RAISED};
        color: {TEXT};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 7px 14px;
    }}
    QPushButton#ghostButton:hover {{ border-color: {ACCENT}; }}
    QPushButton#ghostButton:pressed {{ background-color: {SURFACE_HOVER}; }}

    QPushButton#dangerButton {{
        background-color: transparent;
        color: {DANGER_TEXT};
        border: 1px solid {DANGER_BORDER};
        border-radius: 8px;
        padding: 7px 14px;
    }}
    QPushButton#dangerButton:hover {{ background-color: {DANGER_HOVER_BG}; color: {ON_ACCENT}; border-color: {DANGER}; }}

    /* Tool buttons (cover picker tiles, icon buttons) */
    QToolButton {{
        background-color: {SURFACE_RAISED};
        color: {TEXT};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 6px;
    }}
    QToolButton:hover {{ border-color: {ACCENT}; color: {TEXT}; }}
    QToolButton:pressed {{ background-color: {SURFACE_HOVER}; }}
    QToolButton:checked {{ background-color: {ACCENT_SOFT}; border-color: {ACCENT}; }}
    QToolButton::menu-indicator {{ image: none; }}

    /* Form controls */
    QComboBox {{
        background-color: {SURFACE_RAISED};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 6px 11px;
        color: {TEXT};
        min-height: 22px;
    }}
    QComboBox:hover {{ border-color: {BORDER_HOVER}; }}
    QComboBox:focus, QComboBox:on {{ border-color: {ACCENT}; }}
    QComboBox::drop-down {{ border: none; width: 22px; }}
    QComboBox::down-arrow {{ image: url({_CHEVRON_SVG}); width: 12px; height: 12px; }}
    QComboBox QAbstractItemView {{
        background-color: {SURFACE_RAISED};
        border: 1px solid {BORDER};
        outline: 0;
        selection-background-color: {ACCENT};
        selection-color: {ON_ACCENT};
    }}

    QLineEdit, QTextEdit {{
        background-color: {BASE_INPUT};
        border: 1px solid {BORDER};
        border-radius: 8px;
        padding: 6px 10px;
        color: {TEXT};
        selection-background-color: {ACCENT};
        selection-color: {ON_ACCENT};
    }}
    QLineEdit:focus, QTextEdit:focus {{ border-color: {ACCENT}; }}
    QLineEdit:disabled, QTextEdit:disabled {{ color: {TEXT_FAINT}; }}
    QLineEdit#scoreEdit {{
        font-family: "{MONO_FONT}";
        font-weight: 700;
        font-size: 15px;
    }}

    /* Checkboxes */
    QCheckBox {{ color: {TEXT}; spacing: 8px; }}
    QCheckBox::indicator {{
        width: 16px; height: 16px;
        border: 1px solid {BORDER};
        border-radius: 4px;
        background: {SURFACE_RAISED};
    }}
    QCheckBox::indicator:hover {{ border-color: {ACCENT}; }}
    QCheckBox::indicator:checked {{
        background: {ACCENT};
        border-color: {ACCENT};
        image: url({_CHECK_SVG});
    }}
    QCheckBox::indicator:disabled {{ border-color: {BORDER}; background: {SURFACE}; }}
    QCheckBox::indicator:checked:disabled {{ background: {ACCENT_DIM}; }}

    /* Lists & tables (both the Widget and View base classes) */
    QListWidget, QListView, QTreeView {{
        background-color: {SURFACE};
        border: 1px solid {BORDER};
        border-radius: 8px;
        outline: 0;
    }}
    QListWidget::item, QListView::item {{ padding: 6px 8px; border-radius: 6px; }}
    QListWidget::item:hover, QListView::item:hover {{ background-color: {SURFACE_HOVER}; }}
    QListWidget::item:selected, QListView::item:selected {{ background-color: {ACCENT}; color: {ON_ACCENT}; }}
    QTreeView::branch {{ background: transparent; }}

    QHeaderView::section {{
        background-color: {SURFACE_RAISED};
        color: {TEXT_DIM};
        border: none;
        border-bottom: 1px solid {BORDER};
        padding: 6px 8px;
        font-weight: 600;
    }}
    QTableWidget, QTableView {{
        background-color: {SURFACE};
        alternate-background-color: {SURFACE_RAISED};
        gridline-color: {BORDER};
        border: 1px solid {BORDER};
        border-radius: 8px;
        outline: 0;
    }}
    QTableWidget::item, QTableView::item {{ padding: 3px 6px; }}
    QTableWidget::item:selected, QTableView::item:selected {{ background-color: {ACCENT_SOFT}; color: {TEXT}; }}

    /* Scroll areas & splitters */
    QScrollArea {{ border: none; background: transparent; }}
    QAbstractScrollArea::corner {{ background: transparent; }}
    QSplitter::handle {{ background: {BORDER}; }}
    QSplitter::handle:hover {{ background: {ACCENT}; }}
    QSplitter::handle:horizontal {{ width: 2px; }}
    QSplitter::handle:vertical {{ height: 2px; }}

    /* Scrollbars */
    QScrollBar:vertical {{ background: transparent; width: 12px; margin: 2px; }}
    QScrollBar::handle:vertical {{ background: {SURFACE_HOVER}; border-radius: 5px; min-height: 30px; }}
    QScrollBar::handle:vertical:hover {{ background: {BORDER_HOVER}; }}
    QScrollBar:horizontal {{ background: transparent; height: 12px; margin: 2px; }}
    QScrollBar::handle:horizontal {{ background: {SURFACE_HOVER}; border-radius: 5px; min-width: 30px; }}
    QScrollBar::handle:horizontal:hover {{ background: {BORDER_HOVER}; }}
    QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; width: 0; }}
    QScrollBar::add-page, QScrollBar::sub-page {{ background: transparent; }}

    /* Menus (native on macOS; these guard context menus / non-native builds) */
    QMenuBar {{ background-color: {SIDEBAR_BG}; color: {TEXT}; }}
    QMenuBar::item {{ background: transparent; padding: 4px 10px; }}
    QMenuBar::item:selected {{ background-color: {SURFACE_HOVER}; }}
    QMenu {{ background-color: {SURFACE_RAISED}; border: 1px solid {BORDER}; color: {TEXT}; }}
    QMenu::item {{ padding: 6px 22px; }}
    QMenu::item:selected {{ background-color: {ACCENT}; color: {ON_ACCENT}; }}
    QMenu::separator {{ background: {BORDER}; height: 1px; margin: 4px 8px; }}

    /* Tabs (defensive — no QTabWidget today, but keeps the language square) */
    QTabBar::tab {{
        background: {SURFACE_RAISED};
        color: {TEXT_DIM};
        padding: 7px 14px;
        border: 1px solid {BORDER};
    }}
    QTabBar::tab:selected {{ background: {SURFACE}; color: {TEXT}; border-bottom: 2px solid {ACCENT}; }}
    QTabBar::tab:hover {{ color: {TEXT}; }}

    QToolTip {{
        background-color: {SURFACE_RAISED};
        color: {TEXT};
        border: 1px solid {BORDER};
        border-radius: 6px;
        padding: 4px 8px;
    }}
    """


def apply_theme(app: QApplication) -> None:
    """Apply fonts, the Fusion base palette, and the authoritative stylesheet.

    No third-party theme library is used: Fusion honours the QPalette, so with
    ``Highlight`` = the accent there is no stock blue/green for Qt to fall back
    to, and the QSS above styles every widget + sub-control + state explicitly.
    """
    import os

    fonts.load_fonts()
    if os.environ.get("OST_TRACKER_FONT_STRICT") == "1":
        fonts.assert_fonts_resolve()

    app.setStyle("Fusion")
    app.setPalette(_fusion_dark_palette())
    app.setStyleSheet(extra_qss())

    base = QFont(BODY_FONT)
    base.setPointSize(10)
    app.setFont(base)
