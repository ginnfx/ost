"""Deterministic widget screenshots for visual QA.

The UI spec demands *evidence* — a screen is only "done" when a screenshot
proves it. :func:`snap` renders any widget into an explicit high-DPI pixmap and
writes it to ``_shots/<name>.png``. We render into a pixmap we size ourselves
(rather than calling ``QWidget.grab()``) so the output is identical regardless
of the host screen's device-pixel-ratio — ``grab()`` inherits the screen DPR and
would vary machine to machine.

The small state helpers (:func:`down`, :func:`checked`, ...) drive the pseudo
states that Qt exposes programmatically so the kitchen-sink can capture them.
``:hover`` and hover-only ``:selected`` cannot be forced through public Qt API
and are captured manually or via a dynamic-property mirror rule in the QSS.
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QPixmap
from PySide6.QtWidgets import QWidget

# Default output directory, resolved at call time relative to the CWD so a run
# from the repo root drops shots in ./_shots.
DEFAULT_DIR_NAME = "_shots"
RETINA_SCALE = 2


def shots_dir(out_dir: Path | str | None = None) -> Path:
    d = Path(out_dir) if out_dir is not None else Path.cwd() / DEFAULT_DIR_NAME
    d.mkdir(parents=True, exist_ok=True)
    return d


def snap(widget: QWidget, name: str, *, dpr: int = RETINA_SCALE, out_dir: Path | str | None = None) -> Path:
    """Render *widget* to ``_shots/<name>.png`` at *dpr*x and return the path.

    The widget is sized to its layout and repainted before capture so a
    freshly-built, never-shown widget still renders its full content.
    """
    if widget.size().isEmpty():
        widget.adjustSize()
    if widget.size().isEmpty():
        widget.resize(widget.sizeHint())
    widget.repaint()

    pm = QPixmap(widget.size() * dpr)
    pm.setDevicePixelRatio(dpr)
    pm.fill(Qt.transparent)
    widget.render(pm)

    path = shots_dir(out_dir) / f"{name}.png"
    if not pm.save(str(path)):
        raise RuntimeError(f"snap: failed to write {path}")
    return path


def snap_tree(root: QWidget, out_dir: Path | str | None = None) -> list[Path]:
    """Snap *root* plus every named descendant. Handy for a one-shot dump."""
    paths = [snap(root, root.objectName() or "root", out_dir=out_dir)]
    for child in root.findChildren(QWidget):
        oname = child.objectName()
        if oname:
            paths.append(snap(child, oname, out_dir=out_dir))
    return paths


# --- programmable pseudo-state setters (return the widget for chaining) -------

def down(w: QWidget) -> QWidget:
    """QPushButton :pressed."""
    w.setDown(True)  # type: ignore[attr-defined]
    return w


def checked(w: QWidget) -> QWidget:
    """:checked (checkboxes, checkable buttons, segmented controls)."""
    w.setChecked(True)  # type: ignore[attr-defined]
    return w


def disabled(w: QWidget) -> QWidget:
    """:disabled."""
    w.setEnabled(False)
    return w


def focused(w: QWidget) -> QWidget:
    """:focus (needs the widget realized to actually paint the focus state)."""
    w.setFocus(Qt.OtherFocusReason)
    return w
