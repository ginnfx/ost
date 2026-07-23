"""Small shared animation helpers.

Kept in one place so the motion vocabulary (durations, easing) stays consistent
across screens. Everything here is best-effort and self-contained: a running
animation keeps itself alive by parenting to its target widget.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QEasingCurve, QVariantAnimation
from PySide6.QtWidgets import QLineEdit

_TICK_MS = 300


def tick_up(edit: QLineEdit, value: Optional[int], duration: int = _TICK_MS) -> None:
    """Animate a score field counting up from 0 to ``value`` — the confirmation
    flourish on the entry screens. No-op for a cleared/blank value. Safe to call
    on a field that isn't focused (the entry screens have already advanced)."""
    if value is None:
        return
    try:
        target = int(value)
    except (TypeError, ValueError):
        return

    prior = getattr(edit, "_tick_anim", None)
    if prior is not None:
        prior.stop()

    anim = QVariantAnimation(edit)
    anim.setStartValue(0)
    anim.setEndValue(target)
    anim.setDuration(duration)
    anim.setEasingCurve(QEasingCurve.OutCubic)
    anim.valueChanged.connect(lambda v: edit.setText(str(int(v))))
    anim.finished.connect(lambda: edit.setText(str(target)))
    edit._tick_anim = anim  # keep a reference so it isn't garbage-collected
    anim.start()
