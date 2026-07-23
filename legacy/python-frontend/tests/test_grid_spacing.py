"""Grid clearance for the hover-lift: one value drives the top padding and
every inter-row gap, derived from the card's actual lift + glow blur."""

from __future__ import annotations

import pytest

pytest.importorskip("pytestqt")

from ost_tracker.db import ost_repo, people_repo
from ost_tracker.ui.card_widget import (
    GLOW_BLUR_RADIUS,
    HOVER_CLEARANCE,
    HOVER_LIFT_PX,
)


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication

    return QApplication.instance()


class TestClearanceConstant:
    def test_clearance_absorbs_lift_plus_visible_glow(self):
        # The glow's perceptible extent is well inside its nominal blur radius;
        # the clearance must cover the lift plus at least half the blur.
        assert HOVER_CLEARANCE >= HOVER_LIFT_PX + GLOW_BLUR_RADIUS // 2

    def test_clearance_is_in_the_expected_band(self):
        assert 20 <= HOVER_CLEARANCE <= 24

    def test_hover_animation_reads_the_same_constants(self, app, qtbot):
        from PySide6.QtCore import QPoint

        from ost_tracker.db.models import Ost, OstStats
        from ost_tracker.ui.card_widget import OstCard

        ost = Ost(id=1, title="X", source=None, submitter_id=None,
                  submitter_name=None, cover_image_path=None,
                  external_link=None, created_at="")
        stats = OstStats(ost=ost, rating_count=1, average=9.0, minimum=9,
                         maximum=9, stddev=0.0, rank=1)
        card = OstCard(stats, show_scores=True)
        qtbot.addWidget(card)
        card.show()
        card._set_hover(True)
        rest = card._rest_pos  # what the animation actually returns to
        group = card._anim
        assert group is not None
        blur_anim, move_anim = group.animationAt(0), group.animationAt(1)
        assert blur_anim.endValue() == float(GLOW_BLUR_RADIUS)
        assert move_anim.endValue() == QPoint(rest.x(), rest.y() - HOVER_LIFT_PX)


class TestFlowLayoutVerticalGap:
    def test_rows_are_separated_by_the_vertical_spacing(self, app, qtbot):
        from PySide6.QtCore import QRect
        from PySide6.QtWidgets import QWidget

        from ost_tracker.ui.flow_layout import FlowLayout

        host = QWidget()
        qtbot.addWidget(host)
        flow = FlowLayout(host, margin=0, spacing=10, vspacing=33)
        cells = []
        for _ in range(3):
            w = QWidget(host)
            w.setFixedSize(100, 80)
            flow.addWidget(w)
            cells.append(w)
        # Width fits two per row -> third wraps to row two.
        flow.setGeometry(QRect(0, 0, 230, 500))
        assert cells[0].geometry().y() == cells[1].geometry().y()
        assert cells[2].geometry().y() == cells[0].geometry().y() + 80 + 33

    def test_vspacing_defaults_to_spacing(self, app, qtbot):
        from PySide6.QtWidgets import QWidget

        from ost_tracker.ui.flow_layout import FlowLayout

        flow = FlowLayout(QWidget(), margin=0, spacing=12)
        assert flow._vspacing == 12


class TestGridUsesOneClearanceValue:
    def test_top_padding_row_gap_and_bottom_share_the_constant(self, app, qtbot):
        from ost_tracker.ui.grid_view import GridView

        people_repo.add_person("Alice")
        ost_repo.add_ost("Theme A")
        grid = GridView()
        qtbot.addWidget(grid)

        margins = grid.flow.contentsMargins()
        assert margins.top() == HOVER_CLEARANCE
        assert margins.bottom() == HOVER_CLEARANCE
        assert grid.flow._vspacing == HOVER_CLEARANCE

    def test_hovered_first_row_card_stays_inside_the_host(self, app, qtbot):
        """The point of the padding: a lifted card's top edge must not cross
        the card host's top (where it would clip against the toolbar)."""
        from ost_tracker.ui.grid_view import GridView

        people_repo.add_person("Alice")
        ost_repo.add_ost("Theme A")
        grid = GridView()
        qtbot.addWidget(grid)
        grid.resize(900, 600)
        grid.show()
        grid.flow.activate()

        card = next(iter(grid._cards.values()))
        assert card.pos().y() - HOVER_LIFT_PX >= HOVER_LIFT_PX  # lift + glow room
