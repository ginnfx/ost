"""QPixmap helpers for cover art.

Rendering is where the "never leave a card without an image" guarantee is
enforced: if a cover file is missing or fails to load, we synthesise a
deterministic placeholder tile from the OST title. No card is ever blank, even
before/if the fetch pipeline finds nothing.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Optional

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFont,
    QLinearGradient,
    QPainter,
    QPainterPath,
    QPixmap,
)

from ost_tracker.ui.tokens import PLACEHOLDER_GRADIENTS, TEXT_DIM


def _initials(title: str) -> str:
    words = [w for w in title.split() if w]
    if not words:
        return "?"
    if len(words) == 1:
        return words[0][:2].upper()
    return (words[0][0] + words[1][0]).upper()


def make_placeholder(title: str, size: int) -> QPixmap:
    """A gradient tile with the OST's initials — deterministic per title so the
    same OST always gets the same placeholder colour."""
    digest = int(hashlib.md5(title.encode("utf-8")).hexdigest(), 16)
    top, bottom = PLACEHOLDER_GRADIENTS[digest % len(PLACEHOLDER_GRADIENTS)]

    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    painter = QPainter(pm)
    painter.setRenderHint(QPainter.Antialiasing)

    grad = QLinearGradient(0, 0, 0, size)
    grad.setColorAt(0, QColor(top))
    grad.setColorAt(1, QColor(bottom))
    painter.fillRect(0, 0, size, size, QBrush(grad))

    painter.setPen(QColor(TEXT_DIM))
    font = QFont()
    font.setPointSizeF(size * 0.28)
    font.setBold(True)
    painter.setFont(font)
    painter.drawText(pm.rect(), Qt.AlignCenter, _initials(title))
    painter.end()
    return pm


def _rounded(pm: QPixmap, size: int, radius: int) -> QPixmap:
    """Scale to a square and clip to rounded corners."""
    scaled = pm.scaled(
        size, size, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation
    )
    # Centre-crop to square.
    x = max(0, (scaled.width() - size) // 2)
    y = max(0, (scaled.height() - size) // 2)
    scaled = scaled.copy(x, y, size, size)

    out = QPixmap(size, size)
    out.fill(Qt.transparent)
    painter = QPainter(out)
    painter.setRenderHint(QPainter.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(0, 0, size, size), radius, radius)
    painter.setClipPath(path)
    painter.drawPixmap(0, 0, scaled)
    painter.end()
    return out


def cover_pixmap(
    cover_path: Optional[str], title: str, size: int, radius: int = 10
) -> QPixmap:
    """Load a cover into a rounded square pixmap, or a placeholder on any miss."""
    if cover_path:
        p = Path(cover_path)
        if p.exists():
            pm = QPixmap(str(p))
            if not pm.isNull():
                return _rounded(pm, size, radius)
    return _rounded(make_placeholder(title, size), size, radius)
