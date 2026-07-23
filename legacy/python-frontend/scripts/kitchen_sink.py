#!/usr/bin/env python3
"""Kitchen-sink: one of every styled widget, in every state, on one screen.

Manual visual QA + automated snapshotting for the theme. Runs the *real*
``apply_theme`` so what you see is production styling. With ``--snap`` it writes
each section to ``_shots/ks_*.png`` and exits without an event loop.

    python scripts/kitchen_sink.py            # interactive
    python scripts/kitchen_sink.py --snap     # dump section screenshots
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PySide6.QtGui import QFontInfo  # noqa: E402
from PySide6.QtWidgets import (  # noqa: E402
    QCheckBox,
    QComboBox,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.ui import snapshot, theme  # noqa: E402
from ost_tracker.ui.app import build_app  # noqa: E402
from ost_tracker.ui.card_widget import OstCard  # noqa: E402
from ost_tracker.ui.widgets import SegmentedControl, ghost_button, primary_button  # noqa: E402


def _section(title: str) -> tuple[QWidget, QVBoxLayout]:
    box = QWidget()
    box.setObjectName(f"ks_{title.lower().replace(' ', '_')}")
    lay = QVBoxLayout(box)
    lay.setContentsMargins(16, 16, 16, 16)
    lay.setSpacing(10)
    heading = QLabel(title)
    heading.setFont(theme.display_font(13))
    lay.addWidget(heading)
    return box, lay


def _row(*widgets) -> QWidget:
    w = QWidget()
    lay = QHBoxLayout(w)
    lay.setContentsMargins(0, 0, 0, 0)
    lay.setSpacing(10)
    for x in widgets:
        lay.addWidget(x)
    lay.addStretch(1)
    return w


def build_sections() -> dict[str, QWidget]:
    sections: dict[str, QWidget] = {}

    # Buttons in every state.
    box, lay = _section("Buttons")
    prim = primary_button("Primary")
    disabled_prim = primary_button("Disabled")
    disabled_prim.setEnabled(False)
    pressed = primary_button("Pressed")
    pressed.setDown(True)
    lay.addWidget(_row(prim, pressed, disabled_prim))
    lay.addWidget(_row(ghost_button("Ghost"), QPushButton("Bare"), QPushButton("Default")))
    sections["buttons"] = box

    # Segmented control.
    box, lay = _section("Segmented")
    lay.addWidget(_row(SegmentedControl(["Ranking", "Completed"])))
    lay.addWidget(_row(SegmentedControl(["By person", "By OST batch"])))
    sections["segmented"] = box

    # Inputs.
    box, lay = _section("Inputs")
    le = QLineEdit("Editable")
    ph = QLineEdit()
    ph.setPlaceholderText("Placeholder…")
    dis = QLineEdit("Disabled")
    dis.setEnabled(False)
    score = QLineEdit("7")
    score.setObjectName("scoreEdit")
    score.setFixedWidth(52)
    combo = QComboBox()
    combo.addItems(["Average score", "Title", "Newest"])
    lay.addWidget(_row(le, ph, dis, score, combo))
    sections["inputs"] = box

    # Checkboxes / tool buttons.
    box, lay = _section("Toggles")
    c1 = QCheckBox("Unchecked")
    c2 = QCheckBox("Checked")
    c2.setChecked(True)
    c3 = QCheckBox("Disabled")
    c3.setEnabled(False)
    c4 = QCheckBox("Checked disabled")
    c4.setChecked(True)
    c4.setEnabled(False)
    tb = QToolButton()
    tb.setText("Tool")
    tbc = QToolButton()
    tbc.setText("Checked")
    tbc.setCheckable(True)
    tbc.setChecked(True)
    lay.addWidget(_row(c1, c2, c3, c4, tb, tbc))
    sections["toggles"] = box

    # List + table (selected states).
    box, lay = _section("List and Table")
    lst = QListWidget()
    lst.addItems(["First", "Second (selected)", "Third"])
    lst.setCurrentRow(1)
    lst.setFixedWidth(220)
    tbl = QTableWidget(3, 3)
    tbl.setHorizontalHeaderLabels(["Rank", "Title", "Average"])
    for r in range(3):
        for c in range(3):
            it = QTableWidgetItem(f"{r + 1}.{c}")
            if c != 1:
                it.setFont(theme.mono_font(11))
            tbl.setItem(r, c, it)
    tbl.selectRow(1)
    lay.addWidget(_row(lst, tbl))
    sections["list_table"] = box

    # Signature cards: ranks 1/2/3 + unranked (chamfer + diamond badges).
    box, lay = _section("Cards (chamfer + diamond badges)")
    cards = QHBoxLayout()
    cards.setSpacing(theme.CARD_GAP)
    from ost_tracker.db import ost_repo

    stats = ost_repo.list_osts_with_stats()[:4]
    for s in stats:
        cards.addWidget(OstCard(s, show_scores=True))
    cards.addStretch(1)
    holder = QWidget()
    holder.setLayout(cards)
    lay.addWidget(holder)
    sections["cards"] = box

    # Font-proof strip: requested -> resolved.
    box, lay = _section("Fonts (requested vs resolved)")
    for family, font in [
        (theme.DISPLAY_FONT, theme.display_font(15, upper=False)),
        (theme.BODY_FONT, None),
        (theme.MONO_FONT, theme.mono_font(13)),
    ]:
        lbl = QLabel()
        if font is not None:
            lbl.setFont(font)
        lbl.setText(f"{family}  →  resolved: {QFontInfo(lbl.font()).family()}  (0123456789)")
        lay.addWidget(lbl)
    sections["fonts"] = box

    return sections


def build_kitchen_sink() -> tuple[QWidget, dict[str, QWidget]]:
    sections = build_sections()
    root = QWidget()
    root.setObjectName("kitchenSink")
    outer = QVBoxLayout(root)
    outer.setContentsMargins(24, 24, 24, 24)
    outer.setSpacing(18)
    grid = QGridLayout()
    grid.setSpacing(18)
    order = list(sections.values())
    for i, sec in enumerate(order):
        grid.addWidget(sec, i // 2, i % 2)
    outer.addLayout(grid)
    return root, sections


def main() -> int:
    snap = "--snap" in sys.argv
    app = build_app()
    root, sections = build_kitchen_sink()
    root.resize(1180, 1000)
    root.show()
    for _ in range(8):
        app.processEvents()

    if snap:
        snapshot.snap(root, "ks_all")
        for name, sec in sections.items():
            snapshot.snap(sec, f"ks_{name}")
        print(f"[kitchen_sink] wrote {len(sections) + 1} shots to ./_shots")
        return 0
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
