"""Completion heatmap counts and the Stats tab's reveal-gating and tables."""

from __future__ import annotations

import pytest

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.services import reveal

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication
    return QApplication.instance()


def test_completion_summary_and_heatmap(app, qtbot):
    a = people_repo.add_person("A")
    b = people_repo.add_person("B")
    # No submitter, so no auto self-ratings inflate the count: exactly 1 of 4.
    o1 = ost_repo.add_ost("One", "G", None)
    ost_repo.add_ost("Two", "G", None)
    rating_repo.upsert_rating(o1, a.id, 5)  # 1 of 4 cells

    from ost_tracker.ui.completion_view import CompletionOverview

    view = CompletionOverview()
    qtbot.addWidget(view)
    assert "1 / 4 cells filled" in view.summary.text()
    assert "3 ratings still missing" in view.summary.text()
    assert (o1, a.id) in view.heatmap._filled
    assert (o1, b.id) not in view.heatmap._filled


def test_stats_locked_then_revealed(app, qtbot):
    a = people_repo.add_person("A")
    b = people_repo.add_person("B")
    o1 = ost_repo.add_ost("High", "G", a.id)
    o2 = ost_repo.add_ost("Low", "G", b.id)
    rating_repo.upsert_rating(o1, a.id, 10)
    rating_repo.upsert_rating(o2, a.id, 2)
    assert not reveal.scores_visible()  # incomplete

    from ost_tracker.ui.archive.stats_view import StatsScreen

    view = StatsScreen()
    qtbot.addWidget(view)
    assert not view.ost_table.isVisibleTo(view)  # gated
    assert view.locked_notice.isVisibleTo(view)
    # Rater leniency is always populated.
    assert view.rater_table.rowCount() == 2

    reveal.set_manually_unlocked(True)
    view.refresh()
    assert view.ost_table.isVisibleTo(view)
    assert view.ost_table.rowCount() == 2
    # Row 0 is rank 1 = the higher average ("High").
    assert view.ost_table.item(0, 1).text() == "High"


def test_rater_leniency_ordering(app, qtbot):
    lenient = people_repo.add_person("Lenient")
    harsh = people_repo.add_person("Harsh")
    o = ost_repo.add_ost("Song", "G", lenient.id)
    rating_repo.upsert_rating(o, lenient.id, 10)
    rating_repo.upsert_rating(o, harsh.id, 1)

    from ost_tracker.ui.archive.stats_view import StatsScreen

    view = StatsScreen()
    qtbot.addWidget(view)
    assert view.rater_table.item(0, 0).text() == "Lenient"
