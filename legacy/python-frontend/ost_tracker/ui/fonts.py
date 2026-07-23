"""Bundle, register, and verify the app's typefaces.

The design leans on three specific families — Chakra Petch (display), IBM Plex
Sans (body) and JetBrains Mono (numeric readouts). They ship as static .ttf
files under ``assets/fonts`` and are registered with Qt at startup via
``QFontDatabase.addApplicationFont`` so the app looks identical on machines that
don't have them installed. ``addApplicationFont`` needs *absolute* paths, so we
resolve them from this file's location.

Loading is best-effort so the app still launches, but the three *required*
families are verifiable: :func:`verify_fonts` builds a real widget per role and
reads back the resolved family via ``QFontInfo`` — catching the silent
system-font fallback that a plain load check would miss. :func:`assert_fonts_resolve`
turns any mismatch into a loud error (used in strict/CI runs).
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtGui import QFontDatabase

# Family names as Qt registers them (re-exported from the token module).
from ost_tracker.ui.tokens import BODY_FAMILY, DISPLAY_FAMILY, MONO_FAMILY

__all__ = [
    "DISPLAY_FAMILY",
    "BODY_FAMILY",
    "MONO_FAMILY",
    "load_fonts",
    "loaded_families",
    "missing_families",
    "enable_font_logging",
    "verify_fonts",
    "assert_fonts_resolve",
]

_FONT_DIR = Path(__file__).resolve().parent.parent / "assets" / "fonts"
_FONT_FILES = (
    "ChakraPetch-Bold.ttf",
    "ChakraPetch-SemiBold.ttf",
    "ChakraPetch-Medium.ttf",
    "IBMPlexSans.ttf",
    "JetBrainsMono.ttf",
)

# Qt sometimes registers a family under a style-name variant (e.g. Qt may report
# "IBM Plex Sans Text"). Map each required family to the resolved names we accept.
_ACCEPTED = {
    DISPLAY_FAMILY: {"chakra petch"},
    BODY_FAMILY: {"ibm plex sans", "ibm plex sans text"},
    MONO_FAMILY: {"jetbrains mono", "jetbrains mono nl"},
}

_loaded = False
_loaded_families: set[str] = set()
_failures: list[str] = []


def load_fonts() -> None:
    """Register the bundled fonts once. Idempotent and never raises.

    Qt silently falls back to the system font when ``addApplicationFont`` fails
    (returns ``-1``), so we check the return value explicitly and record any
    failure rather than letting a missing bundle quietly degrade the whole type
    system. Call :func:`missing_families` or :func:`verify_fonts` to assert success.
    """
    global _loaded
    if _loaded:
        return
    for name in _FONT_FILES:
        path = _FONT_DIR / name
        try:
            if not path.exists():
                _failures.append(f"{name}: not found at {path}")
                continue
            fid = QFontDatabase.addApplicationFont(str(path))
            if fid == -1:
                _failures.append(f"{name}: addApplicationFont returned -1")
                continue
            for fam in QFontDatabase.applicationFontFamilies(fid):
                _loaded_families.add(fam)
        except Exception as exc:  # never block launch on a font
            _failures.append(f"{name}: {exc}")
    if _failures:
        import sys

        print("[fonts] load warnings: " + " | ".join(_failures), file=sys.stderr)
    _loaded = True


def loaded_families() -> set[str]:
    return set(_loaded_families)


def missing_families() -> list[str]:
    """Which of the three required families failed to load (empty == all good)."""
    return [f for f in (DISPLAY_FAMILY, BODY_FAMILY, MONO_FAMILY) if f not in _loaded_families]


def enable_font_logging() -> None:
    """Turn on Qt's font-substitution logging so any fallback is visible on stderr."""
    from PySide6.QtCore import QLoggingCategory

    QLoggingCategory.setFilterRules("qt.qpa.fonts=true")


def _accepted_for(intended: str) -> set[str]:
    # Base accepted names plus whatever the bundled TTFs actually registered.
    accepted = set(_ACCEPTED.get(intended, {intended.lower()}))
    for fam in _loaded_families:
        if fam.lower().startswith(intended.lower()):
            accepted.add(fam.lower())
    return accepted


def verify_fonts() -> list[str]:
    """Build a widget per role and confirm the resolved family is our font, not a
    system fallback. Returns human-readable mismatches (empty == all good).

    Requires a live QApplication (font resolution needs the GUI font database).
    """
    from PySide6.QtWidgets import QApplication, QLabel

    if QApplication.instance() is None:
        return ["verify_fonts: no QApplication instance"]

    from PySide6.QtGui import QFont, QFontInfo

    from ost_tracker.ui import theme  # lazy: avoid fonts<->theme import cycle

    enable_font_logging()
    load_fonts()

    problems: list[str] = list(missing_families())
    roles = [
        ("display", theme.display_font(20), DISPLAY_FAMILY),
        ("body", QFont(BODY_FAMILY, 12), BODY_FAMILY),
        ("mono", theme.mono_font(14), MONO_FAMILY),
    ]
    for role, font, intended in roles:
        label = QLabel()
        label.setFont(font)
        resolved = QFontInfo(label.font()).family()
        if resolved.lower() not in _accepted_for(intended):
            problems.append(f"{role}: requested {intended!r} but resolved {resolved!r}")
    return problems


def assert_fonts_resolve() -> None:
    """Raise if any required font did not resolve. For strict/CI runs."""
    problems = verify_fonts()
    if problems:
        raise RuntimeError("Fonts did not resolve to bundled families: " + "; ".join(problems))
