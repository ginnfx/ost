"""Per-card accent behaviour and rank-badge legibility across all positions."""

from __future__ import annotations

import pytest

pytest.importorskip("pytestqt")

from PySide6.QtGui import QColor

from ost_tracker.db.models import Ost, OstStats
from ost_tracker.ui import theme


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication

    return QApplication.instance()


def _make_stats(rank: int = 1, accent_hex: str | None = None) -> OstStats:
    ost = Ost(id=1, title="X", source=None, submitter_id=None, submitter_name=None,
              cover_image_path=None, external_link=None, created_at="",
              cover_accent_hex=accent_hex)
    return OstStats(ost=ost, rating_count=2, average=9.0, minimum=8,
                    maximum=10, stddev=1.0, rank=rank)


def _relative_luminance(hex_color: str) -> float:
    def channel(c: int) -> float:
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    color = QColor(hex_color)
    r, g, b = channel(color.red()), channel(color.green()), channel(color.blue())
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(fg: str, bg: str) -> float:
    l1, l2 = _relative_luminance(fg), _relative_luminance(bg)
    lighter, darker = max(l1, l2), min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)


class TestRankBadgeLegibility:
    """Item 1: the badge must hold up at EVERY position, not just the medals."""

    def test_neutral_badge_text_contrast_meets_wcag_aa(self):
        # Ranks 4+ draw TEXT on SURFACE_RAISED.
        assert contrast_ratio(theme.TEXT, theme.SURFACE_RAISED) >= 4.5

    @pytest.mark.parametrize("medal", [theme.GOLD, theme.SILVER, theme.BRONZE])
    def test_medal_badge_ink_contrast_meets_wcag_aa(self, medal):
        assert contrast_ratio(theme.INK, medal) >= 4.5

    @pytest.mark.parametrize("rank", [4, 10, 27, 50])
    def test_two_digit_ranks_render_light_text_pixels(self, app, qtbot, rank):
        """Render the badge offscreen and confirm the number actually painted
        (light pixels present over the dark diamond), so a 2-digit rank isn't
        clipped or invisible down the list."""
        from ost_tracker.ui.card_widget import _RankBadge

        badge = _RankBadge(rank, theme.ACCENT, None)
        qtbot.addWidget(badge)
        img = badge.grab().toImage()
        light = sum(
            1
            for x in range(img.width())
            for y in range(img.height())
            if QColor(img.pixel(x, y)).value() > 200
        )
        assert light > 10  # digits drew as light pixels


class TestPerCardAccent:
    def test_card_uses_extracted_accent_when_present(self, app, qtbot):
        from ost_tracker.ui.card_widget import OstCard

        card = OstCard(_make_stats(accent_hex="#cc3355"), show_scores=True)
        qtbot.addWidget(card)
        assert card._accent == "#cc3355"

    def test_card_falls_back_to_token_without_accent(self, app, qtbot):
        from ost_tracker.ui.card_widget import OstCard

        card = OstCard(_make_stats(accent_hex=None), show_scores=True)
        qtbot.addWidget(card)
        assert card._accent == theme.ACCENT

    def test_hover_glow_color_matches_card_accent(self, app, qtbot):
        """Item 5a: border and glow must come from the same accent value."""
        from PySide6.QtWidgets import QGraphicsDropShadowEffect
        from ost_tracker.ui.card_widget import OstCard

        card = OstCard(_make_stats(accent_hex="#cc3355"), show_scores=True)
        qtbot.addWidget(card)
        card._set_hover(True)
        effect = card.graphicsEffect()
        assert isinstance(effect, QGraphicsDropShadowEffect)
        glow = effect.color()
        assert (glow.red(), glow.green(), glow.blue()) == (0xCC, 0x33, 0x55)

    def test_rank_badge_receives_card_accent(self, app, qtbot):
        from ost_tracker.ui.card_widget import OstCard

        card = OstCard(_make_stats(rank=7, accent_hex="#cc3355"), show_scores=True)
        qtbot.addWidget(card)
        assert card._rank_badge is not None
        assert card._rank_badge._accent == "#cc3355"
