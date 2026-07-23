"""A single cover-art card for the leaderboard grid — the signature widget.

This is where the character-select motif lives: the card body is a chamfered
panel (top-left and bottom-right corners cut diagonally via a QPainterPath, not
border-radius) and the rank sits in a rotated-square "diamond" badge pinned to
the top-left corner (gold/silver/bronze for the top three, neutral otherwise).
Cover art is the dominant anchor; a mono score badge sits top-right.

Hover lifts the card ~5px and wraps it in a glow tinted by the card's own
accent — a colour extracted from its cover art (``osts.cover_accent_hex``),
falling back to the fixed accent token. Crucially the glow
(a QGraphicsDropShadowEffect) is attached only to the *hovered* card and removed
on leave — never to every card at once, which is what caused live-rendering
glitches. One transient effect on the single hovered card is safe and standard.
The chamfer/diamond treatment is deliberately reserved to these cards so it keeps
reading as a signature rather than generic decoration.
"""

from __future__ import annotations

from PySide6.QtCore import (
    QEasingCurve,
    QParallelAnimationGroup,
    QPoint,
    QPointF,
    QPropertyAnimation,
    Qt,
    Signal,
)
from PySide6.QtGui import (
    QColor,
    QMouseEvent,
    QPainter,
    QPainterPath,
    QPen,
    QPolygonF,
)
from PySide6.QtWidgets import (
    QFrame,
    QGraphicsDropShadowEffect,
    QLabel,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db.models import OstStats
from ost_tracker.ui import theme
from ost_tracker.ui.image_utils import cover_pixmap

CARD_COVER_SIZE = 176
CARD_WIDTH = CARD_COVER_SIZE + 20
_CHAMFER = 16          # diagonal corner cut, px
_BADGE_R = 15          # diamond half-diagonal, px

# Hover motion. The grid's vertical clearance derives from these, so the lift
# and glow can never outgrow the space the layout reserves for them.
HOVER_LIFT_PX = 5           # how far a hovered card rises
GLOW_BLUR_RADIUS = 28       # drop-shadow blur at full hover
# A gaussian shadow is imperceptible well inside its nominal radius; lift plus
# ~60% of the blur covers everything the eye sees without bloating the grid.
HOVER_CLEARANCE = HOVER_LIFT_PX + round(GLOW_BLUR_RADIUS * 0.6)


class _RankBadge(QWidget):
    """The rotated-square rank diamond, drawn on top of the cover so the chamfer
    corner reads as a badge notch. Transparent to mouse so clicks hit the card.

    Top three keep their medal fill (gold/silver/bronze with dark ink); every
    other rank gets the same neutral dark fill with light text, outlined in the
    card's accent so the badge stays tied to its cover without losing contrast."""

    def __init__(self, rank: int, accent: str, parent: QWidget) -> None:
        super().__init__(parent)
        self._rank = rank
        self._accent = accent
        self.setFixedSize(_BADGE_R * 2 + 8, _BADGE_R * 2 + 8)
        self.setAttribute(Qt.WA_TransparentForMouseEvents, True)

    def paintEvent(self, event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        cx = cy = self.width() / 2
        r = _BADGE_R
        diamond = QPolygonF([
            QPointF(cx, cy - r), QPointF(cx + r, cy),
            QPointF(cx, cy + r), QPointF(cx - r, cy),
        ])
        medal = theme.medal_color(self._rank)
        p.setBrush(QColor(medal or theme.SURFACE_RAISED))
        p.setPen(QPen(QColor(theme.BG if medal else self._accent), 1.5))
        p.drawPolygon(diamond)
        p.setPen(QColor(theme.INK if medal else theme.TEXT))
        p.setFont(theme.mono_font(9))
        p.drawText(self.rect(), Qt.AlignCenter, str(self._rank))
        p.end()


class OstCard(QFrame):
    clicked = Signal(int)  # ost_id

    def __init__(self, stats: OstStats, show_scores: bool, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost_id = stats.ost.id
        self._show_scores = show_scores
        self._rank = stats.rank if show_scores else None
        self.setObjectName("ostCard")
        self.setFrameShape(QFrame.NoFrame)
        self.setFixedWidth(CARD_WIDTH)
        self.setCursor(Qt.PointingHandCursor)
        self.setAttribute(Qt.WA_Hover, True)
        self._hover = False
        self._accent = theme.ACCENT
        self._anim: QParallelAnimationGroup | None = None
        self._rest_pos: QPoint | None = None
        self._rank_badge: _RankBadge | None = None
        self._score_badge: QLabel | None = None

        layout = QVBoxLayout(self)
        layout.setContentsMargins(10, 10, 10, 12)
        layout.setSpacing(8)

        self._cover = QLabel(self)
        self._cover.setFixedSize(CARD_COVER_SIZE, CARD_COVER_SIZE)
        layout.addWidget(self._cover)

        self._title = QLabel(self)
        self._title.setWordWrap(True)
        self._title.setMaximumHeight(42)
        self._title.setFont(theme.display_font(11))
        self._title.setStyleSheet(f"color: {theme.TEXT};")
        layout.addWidget(self._title)

        self._submitter = QLabel(self)
        self._submitter.setStyleSheet(f"color: {theme.TEXT_DIM}; font-size: 11px;")
        layout.addWidget(self._submitter)

        self.set_stats(stats, show_scores)

    def set_stats(self, stats: OstStats, show_scores: bool) -> None:
        """(Re)populate the card's mutable content in place. Reused on refresh so
        the widget keeps its identity and can slide to a new grid position rather
        than being destroyed and recreated."""
        self._show_scores = show_scores
        self._rank = stats.rank if show_scores else None
        # Per-card accent: derived from this cover's art, falling back to the
        # fixed token. Border, glow, and badge outline all read this one value.
        self._accent = stats.ost.cover_accent_hex or theme.ACCENT
        self._cover.setPixmap(
            cover_pixmap(stats.ost.cover_image_path, stats.ost.title, CARD_COVER_SIZE, radius=8)
        )
        self._title.setText(stats.ost.title)
        self._submitter.setText(stats.ost.submitter_name or "—")

        if self._score_badge is not None:
            self._score_badge.deleteLater()
            self._score_badge = None
        if self._rank_badge is not None:
            self._rank_badge.deleteLater()
            self._rank_badge = None

        if show_scores and stats.average is not None:
            self._make_score_badge(self._cover, stats.average)
        # Rank diamond added last so it stacks above the cover, pinned to corner.
        if show_scores and self._rank is not None:
            self._rank_badge = _RankBadge(self._rank, self._accent, self)
            self._rank_badge.move(2, 2)
            self._rank_badge.raise_()
            self._rank_badge.show()
        self.update()

    def _make_score_badge(self, parent: QLabel, average: float) -> None:
        # Score is text only — gold JetBrains Mono, no colored pill/box. A soft
        # dark drop shadow (not a flat fill) keeps it legible over busy art.
        badge = QLabel(f"{average:.1f}", parent)
        badge.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        badge.setFont(theme.mono_font(14))
        badge.setStyleSheet(f"color: {theme.GOLD}; background: transparent;")
        shadow = QGraphicsDropShadowEffect(badge)
        shadow.setColor(QColor(0, 0, 0, 230))
        shadow.setBlurRadius(7)
        shadow.setOffset(0, 1)
        badge.setGraphicsEffect(shadow)
        badge.adjustSize()
        badge.move(CARD_COVER_SIZE - badge.width() - 8, 6)
        badge.show()
        self._score_badge = badge

    # --- painting: chamfered card body -------------------------------------

    def paintEvent(self, event) -> None:  # noqa: N802
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        w, h, c = self.width(), self.height(), _CHAMFER

        path = QPainterPath()
        path.moveTo(c, 0)
        path.lineTo(w, 0)          # top edge → square top-right
        path.lineTo(w, h - c)      # right edge
        path.lineTo(w - c, h)      # bottom-right chamfer
        path.lineTo(0, h)          # bottom edge → square bottom-left
        path.lineTo(0, c)          # left edge
        path.closeSubpath()        # top-left chamfer

        p.fillPath(path, QColor(theme.SURFACE_HOVER if self._hover else theme.SURFACE))
        # Hover border and hover glow share self._accent, so they always match.
        pen = QPen(QColor(self._accent if self._hover else theme.BORDER))
        pen.setWidthF(1.5 if self._hover else 1.0)
        p.setPen(pen)
        p.drawPath(path)
        p.end()

    # --- hover: accent glow + lift -------------------------------------------

    def enterEvent(self, event) -> None:  # noqa: N802
        self._set_hover(True)
        super().enterEvent(event)

    def leaveEvent(self, event) -> None:  # noqa: N802
        self._set_hover(False)
        super().leaveEvent(event)

    def moveEvent(self, event) -> None:  # noqa: N802
        # Track the layout's resting position while idle, so the leave animation
        # returns to the right spot even after the grid reflows.
        if not self._hover and self._anim is None:
            self._rest_pos = self.pos()
        super().moveEvent(event)

    def _apply_style(self, hover: bool) -> None:
        # Retained entry point (used by tests): drive the hover state directly.
        self._set_hover(hover)

    def _set_hover(self, active: bool) -> None:
        if active == self._hover:
            return
        self._hover = active
        if self._rest_pos is None:
            self._rest_pos = self.pos()
        self.update()
        self._animate_hover(active)

    def _animate_hover(self, active: bool) -> None:
        effect = self.graphicsEffect()
        if active and effect is None:
            effect = QGraphicsDropShadowEffect(self)
            glow = QColor(self._accent)
            glow.setAlpha(210)
            effect.setColor(glow)
            effect.setBlurRadius(0)
            effect.setOffset(0, 0)
            self.setGraphicsEffect(effect)
        if effect is None:
            return

        if self._anim is not None:
            self._anim.stop()
        rest = self._rest_pos if self._rest_pos is not None else self.pos()
        target = QPoint(rest.x(), rest.y() - HOVER_LIFT_PX) if active else rest

        blur = QPropertyAnimation(effect, b"blurRadius", self)
        blur.setDuration(180)
        blur.setEasingCurve(QEasingCurve.OutCubic)
        blur.setStartValue(effect.blurRadius())
        blur.setEndValue(float(GLOW_BLUR_RADIUS) if active else 0.0)

        move = QPropertyAnimation(self, b"pos", self)
        move.setDuration(180)
        move.setEasingCurve(QEasingCurve.OutCubic)
        move.setStartValue(self.pos())
        move.setEndValue(target)

        group = QParallelAnimationGroup(self)
        group.addAnimation(blur)
        group.addAnimation(move)
        group.finished.connect(self._on_anim_done)
        if not active:
            group.finished.connect(lambda: self.setGraphicsEffect(None))
        group.start()
        self._anim = group

    def _on_anim_done(self) -> None:
        self._anim = None

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        if event.button() == Qt.LeftButton and self.rect().contains(event.position().toPoint()):
            self.clicked.emit(self._ost_id)
        super().mouseReleaseEvent(event)
