#!/usr/bin/env python3
"""Capture the harder-to-reach states as evidence: the Leaderboard's Completed
segment, a detail view, a hovered card (glow frame), and the Notes/History tool
windows. Writes to ./_shots/ev_*.png."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ost_tracker.ui import snapshot  # noqa: E402
from ost_tracker.ui.app import build_app  # noqa: E402


def main() -> int:
    app = build_app()
    from ost_tracker.db import ost_repo
    from ost_tracker.db.connection import get_db

    get_db()
    from ost_tracker.ui.history_view import HistoryScreen
    from ost_tracker.ui.main_window import MainWindow
    from ost_tracker.ui.notes_view import NotesScreen

    win = MainWindow()
    win.resize(1180, 800)
    win.show()
    for _ in range(8):
        app.processEvents()

    win.navigate("home")
    home = win._screens["home"]

    # Completed segment (the heatmap folded in from the old popover).
    home.seg.setCurrentIndex(1)
    home._on_segment(1)
    for _ in range(6):
        app.processEvents()
    snapshot.snap(win, "ev_leaderboard_completed")

    # Back to ranking; hover the top card to fire the glow + lift.
    home.seg.setCurrentIndex(0)
    home._on_segment(0)
    for _ in range(6):
        app.processEvents()
    if home.grid._cards:
        first = next(iter(home.grid._cards.values()))
        first._set_hover(True)
        for _ in range(8):
            app.processEvents()
        snapshot.snap(win, "ev_leaderboard_hover")
        first._set_hover(False)

    # Detail view of the top OST.
    stats = ost_repo.list_osts_with_stats()
    if stats:
        home.show_detail(stats[0].ost.id)
        for _ in range(6):
            app.processEvents()
        snapshot.snap(win, "ev_detail")

    # Notes + History tool windows (rendered directly, no modal loop).
    notes = NotesScreen()
    notes.resize(760, 560)
    notes.show()
    for _ in range(6):
        app.processEvents()
    snapshot.snap(notes, "ev_notes")

    history = HistoryScreen()
    history.resize(760, 560)
    history.show()
    for _ in range(6):
        app.processEvents()
    snapshot.snap(history, "ev_history")

    print("[evidence] wrote ev_* shots to ./_shots")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
