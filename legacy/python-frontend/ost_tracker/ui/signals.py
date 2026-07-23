"""App-wide signal bus.

Every screen reads from the same SQLite database, so any screen that writes
emits the relevant signal here and every other screen re-queries. This is how
the main grid "always reflects current data" without a manual refresh button:
adding an OST or entering a rating anywhere emits, and the grid rebuilds.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QObject, Signal


class SignalBus(QObject):
    osts_changed = Signal()      # an OST was added/edited/deleted, or cover changed
    ratings_changed = Signal()   # any rating upserted/deleted
    people_changed = Signal()    # people added/renamed/removed
    notes_changed = Signal()     # scratchpad changed
    history_changed = Signal()   # prior-OST exclusion list changed
    reveal_changed = Signal()    # locked-reveal state flipped

    # Request navigation to a screen or the detail view. Decouples widgets that
    # want to navigate from the main window that owns the stack.
    open_detail_requested = Signal(int)          # ost_id
    # prefill title, note text, submitter id (or None) — e.g. the Leaderboard
    # passes its active submitter filter so Add OST opens pre-assigned.
    open_add_ost_requested = Signal(str, str, object)
    navigate_requested = Signal(str)             # screen key


_bus: Optional[SignalBus] = None


def bus() -> SignalBus:
    global _bus
    if _bus is None:
        _bus = SignalBus()
    return _bus
