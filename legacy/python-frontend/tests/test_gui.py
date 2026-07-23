"""GUI tests (offscreen). Exercise the Add OST flow with a mocked cover fetch,
grid auto-refresh, and locked-reveal card behaviour."""

from __future__ import annotations

from pathlib import Path

import pytest

from ost_tracker.db import ost_repo, people_repo, rating_repo
from ost_tracker.services import coverart, reveal
from ost_tracker.services.coverart import CoverResult, CoverSource

pytest.importorskip("pytestqt")


@pytest.fixture()
def app(fresh_db, qtbot):
    # qtbot provides the QApplication; fresh_db isolates the database.
    from ost_tracker.ui.theme import apply_theme
    from PySide6.QtWidgets import QApplication

    apply_theme(QApplication.instance())
    return QApplication.instance()


def test_add_ost_dialog_creates_and_fetches(app, qtbot, tmp_path, monkeypatch):
    people_repo.add_person("Alice")

    # Stub the network fetch: pretend iTunes returned a cover file.
    fake_cover = tmp_path / "c.jpg"
    fake_cover.write_bytes(b"not-really-an-image-but-a-path")

    def fake_fetch(ost_id, title, source, client=None):
        return CoverResult(path=Path(fake_cover), source=CoverSource.ITUNES)

    monkeypatch.setattr(coverart, "fetch_cover", fake_fetch)

    from ost_tracker.ui.add_ost_dialog import AddOstDialog
    from ost_tracker.ui.cover_worker import cover_service

    dialog = AddOstDialog(prefill_title="Snake Eater")
    dialog.source_edit.setText("MGS3")

    with qtbot.waitSignal(cover_service().fetch_finished, timeout=3000):
        dialog._save()

    assert dialog.created_ost_id is not None
    ost = ost_repo.get_ost(dialog.created_ost_id)
    assert ost.title == "Snake Eater"
    assert ost.source == "MGS3"
    # Background worker persisted the cover path.
    assert ost.cover_image_path == str(fake_cover)


def test_add_ost_requires_title(app, qtbot, monkeypatch):
    from ost_tracker.ui.add_ost_dialog import AddOstDialog
    from PySide6.QtWidgets import QMessageBox

    # Don't actually pop a modal warning during the test.
    monkeypatch.setattr(QMessageBox, "warning", lambda *a, **k: None)
    dialog = AddOstDialog(prefill_title="   ")
    dialog._save()
    assert dialog.created_ost_id is None
    assert ost_repo.count_osts() == 0


def test_grid_refreshes_on_data_change(app, qtbot):
    people_repo.add_person("Alice")
    from ost_tracker.ui.grid_view import GridView

    grid = GridView()
    qtbot.addWidget(grid)
    assert grid.flow.count() == 0

    ost_repo.add_ost("New Song", "Game", None)
    from ost_tracker.ui.signals import bus
    bus().osts_changed.emit()
    assert grid.flow.count() == 1


def test_grid_hides_badges_when_locked(app, qtbot):
    alice = people_repo.add_person("Alice")
    oid = ost_repo.add_ost("Song", "Game", alice.id)
    rating_repo.upsert_rating(oid, alice.id, 8)
    # Only 1 of 1 person rated 1 OST -> complete -> visible. Add a 2nd person to
    # make it incomplete and thus locked.
    people_repo.add_person("Bob")
    assert not reveal.scores_visible()

    from ost_tracker.ui.grid_view import GridView

    grid = GridView()
    qtbot.addWidget(grid)
    grid.refresh()
    # Locked: a card exists but shows no score badge; verify by checking the
    # sort was coerced off "Average score".
    assert grid.sort_combo.currentText() != "Average score"
    assert grid.flow.count() == 1


def test_detail_loads_and_shows_scores(app, qtbot):
    alice = people_repo.add_person("Alice")
    bob = people_repo.add_person("Bob")
    oid = ost_repo.add_ost("Song", "Game", alice.id, "https://youtu.be/x")
    rating_repo.upsert_rating(oid, alice.id, 9)
    rating_repo.upsert_rating(oid, bob.id, 7)

    from ost_tracker.ui.detail_view import DetailView

    view = DetailView()
    qtbot.addWidget(view)
    assert view.load(oid) is True
    assert view.title_label.text() == "Song"
    assert not view.link_button.isHidden()  # link present -> button shown
    assert view.load(99999) is False  # missing OST


def test_detail_delete_removes_ost_and_goes_back(app, qtbot, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.detail_view import DetailView

    oid = ost_repo.add_ost("Doomed", "Game", None)
    monkeypatch.setattr(QMessageBox, "question", lambda *a, **k: QMessageBox.Yes)

    view = DetailView()
    qtbot.addWidget(view)
    view.load(oid)
    with qtbot.waitSignal(view.back_requested, timeout=2000):
        view._delete()
    assert ost_repo.get_ost(oid) is None


def test_cover_picker_applies_selection(app, qtbot, monkeypatch, tmp_path):
    from pathlib import Path

    from ost_tracker.services import coverart
    from ost_tracker.services.coverart import CoverResult, CoverSource
    from ost_tracker.ui.cover_picker import CoverPickerDialog
    from ost_tracker.ui.signals import bus

    # Keep the background search from hitting the network.
    monkeypatch.setattr(coverart, "search_candidates", lambda *a, **k: [])

    oid = ost_repo.add_ost("Song", "Game", None)
    cached = tmp_path / "cover.jpg"
    cached.write_bytes(b"x")
    monkeypatch.setattr(
        coverart, "import_cover_from_url",
        lambda ost_id, url, client=None: CoverResult(path=Path(cached), source=CoverSource.NONE),
    )

    dialog = CoverPickerDialog(ost_repo.get_ost(oid))
    qtbot.addWidget(dialog)

    changed = []
    bus().osts_changed.connect(lambda: changed.append(True))
    dialog._apply_url("https://example.com/cover.png")

    assert ost_repo.get_ost(oid).cover_image_path == str(cached)
    assert changed  # grid was notified


def test_cover_picker_franchise_filter_and_toggle(app, qtbot, monkeypatch):
    import io

    from PIL import Image

    from ost_tracker.services import coverart
    from ost_tracker.services.coverart import CoverCandidate
    from ost_tracker.ui import cover_picker
    from ost_tracker.ui.cover_picker import CoverPickerDialog

    mix = [
        CoverCandidate("i1", "t1", "Yakuza 0 Original Soundtrack", "iTunes"),
        CoverCandidate("i2", "t2", "Some Unrelated Pop Album", "iTunes"),
        CoverCandidate("i3", "t3", "This OST's YouTube link", "Your link"),
    ]
    monkeypatch.setattr(coverart, "search_candidates", lambda *a, **k: mix)

    # Give every candidate a loadable thumbnail so none are dropped as "dead".
    buf = io.BytesIO()
    Image.new("RGB", (40, 40), (60, 60, 60)).save(buf, "PNG")
    monkeypatch.setattr(cover_picker._SearchTask, "_download",
                        staticmethod(lambda client, url: buf.getvalue()))

    oid = ost_repo.add_ost("Baka Mitai", "Yakuza", None)
    dialog = CoverPickerDialog(ost_repo.get_ost(oid))
    qtbot.addWidget(dialog)
    qtbot.waitUntil(lambda: dialog._grid.count() > 0, timeout=5000)

    # Franchise filter: only the Yakuza item + the OST's own link survive.
    assert dialog._grid.count() == 2
    dialog._show_all.setChecked(True)  # re-render with everything
    assert dialog._grid.count() == 3


def test_cover_picker_youtube_url_uses_thumbnail(app, qtbot, monkeypatch):
    from pathlib import Path

    from ost_tracker.services import coverart
    from ost_tracker.services.coverart import CoverResult, CoverSource
    from ost_tracker.ui.cover_picker import CoverPickerDialog

    monkeypatch.setattr(coverart, "search_candidates", lambda *a, **k: [])
    oid = ost_repo.add_ost("Song", "Game", None)

    used = {}

    def fake_import(ost_id, url, client=None):
        used["url"] = url
        return CoverResult(path=Path("/tmp/x.jpg"), source=CoverSource.NONE)

    monkeypatch.setattr(coverart, "import_cover_from_url", fake_import)

    dialog = CoverPickerDialog(ost_repo.get_ost(oid))
    qtbot.addWidget(dialog)
    dialog._apply_url("https://youtu.be/dQw4w9WgXcQ")
    # A YouTube link is converted to its thumbnail image URL before fetching.
    assert used["url"] == "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg"


def test_card_builds_and_hover_restyles(app, qtbot):
    from ost_tracker.db.models import Ost, OstStats
    from ost_tracker.ui.card_widget import OstCard

    ost = Ost(id=1, title="X", source=None, submitter_id=None, submitter_name=None,
              cover_image_path=None, external_link=None, created_at="")
    stats = OstStats(ost=ost, rating_count=2, average=9.0, minimum=8,
                     maximum=10, stddev=1.0, rank=1)
    card = OstCard(stats, show_scores=True)
    qtbot.addWidget(card)
    # No persistent QGraphicsEffect at rest (only the hovered card ever gets one).
    assert card.graphicsEffect() is None
    assert card._hover is False
    card._set_hover(True)
    assert card._hover is True
    assert card.graphicsEffect() is not None  # emerald-green glow while hovered
    card._set_hover(False)
    assert card._hover is False


def test_add_ost_redirects_to_people_when_none(app, qtbot, monkeypatch):
    from PySide6.QtWidgets import QMessageBox
    from ost_tracker.ui.main_window import MainWindow

    monkeypatch.setattr(QMessageBox, "information", lambda *a, **k: None)
    win = MainWindow()
    qtbot.addWidget(win)
    win.open_add_ost()  # no people exist yet
    assert win._keys[win.nav.currentRow()] == "people"


def test_grid_has_persistent_add_button(app, qtbot):
    people_repo.add_person("Alice")
    from ost_tracker.ui.grid_view import GridView
    from ost_tracker.ui.signals import bus

    grid = GridView()
    qtbot.addWidget(grid)
    assert grid.add_button.isEnabled()
    captured = []
    bus().open_add_ost_requested.connect(lambda t, n, sid: captured.append((t, n, sid)))
    grid.add_button.click()
    assert captured == [("", "", None)]


def test_grid_empty_state_routes_to_people_when_no_people(app, qtbot):
    from ost_tracker.ui.grid_view import GridView
    from ost_tracker.ui.signals import bus

    grid = GridView()
    qtbot.addWidget(grid)
    grid.refresh()
    routed = []
    bus().navigate_requested.connect(lambda k: routed.append(k))
    grid.empty_state._button.click()
    assert routed == ["people"]


def test_grid_empty_state_routes_to_add_ost_when_people_exist(app, qtbot):
    people_repo.add_person("Alice")
    from ost_tracker.ui.grid_view import GridView
    from ost_tracker.ui.signals import bus

    grid = GridView()
    qtbot.addWidget(grid)
    grid.refresh()
    routed = []
    bus().open_add_ost_requested.connect(lambda t, n: routed.append((t, n)))
    grid.empty_state._button.click()
    assert routed == [("", "")]


def test_search_collapses_single_result_to_top_left(app, qtbot):
    from ost_tracker.services import reveal
    from ost_tracker.ui.grid_view import GridView

    ppl = [people_repo.add_person(n) for n in ("A", "B")]
    titles = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"]
    for i, t in enumerate(titles):
        oid = ost_repo.add_ost(t, "G", None)
        for p in ppl:
            rating_repo.upsert_rating(oid, p.id, (i + p.id) % 11)
    reveal.set_manually_unlocked(True)

    grid = GridView()
    qtbot.addWidget(grid)
    grid.resize(1000, 700)
    grid.show()
    qtbot.wait(80)

    # Find a card that is NOT already in the top-left column (x > 0).
    cards = [grid.flow.itemAt(i).widget() for i in range(grid.flow.count())]
    off_origin = [c for c in cards if c.x() > 0]
    assert off_origin, "expected a multi-column layout to exercise the bug"
    target = off_origin[0]

    # Search down to just that one OST; it must collapse to the layout origin
    # (the top-left inside the hover-clearance margins), not stay parked in
    # its original column.
    grid.search_edit.setText(target._title.text())
    qtbot.wait(80)
    assert grid.flow.count() == 1
    remaining = grid.flow.itemAt(0).widget()
    margins = grid.flow.contentsMargins()
    assert (remaining.x(), remaining.y()) == (margins.left(), margins.top())


def test_grid_reveal_transition_animates_without_error(app, qtbot):
    from ost_tracker.services import reveal
    from ost_tracker.ui.grid_view import GridView

    a = people_repo.add_person("A")
    b = people_repo.add_person("B")
    o1 = ost_repo.add_ost("One", "G", None)
    o2 = ost_repo.add_ost("Two", "G", None)
    rating_repo.upsert_rating(o1, a.id, 3)
    rating_repo.upsert_rating(o2, a.id, 9)

    grid = GridView()
    qtbot.addWidget(grid)
    assert grid._was_visible is False  # b hasn't rated -> locked

    # Completing every cell flips to revealed; refresh schedules the reveal
    # sequence (staggered fade/rise). It must run without raising.
    rating_repo.upsert_rating(o1, b.id, 4)
    rating_repo.upsert_rating(o2, b.id, 10)
    assert reveal.scores_visible()
    grid.refresh()
    qtbot.wait(60)  # let the singleShot(0) + first stagger fire
    assert grid._was_visible is True
    assert grid.flow.count() == 2

    # A later re-sort (rank change) animates slides, also without raising.
    rating_repo.upsert_rating(o1, a.id, 10)
    rating_repo.upsert_rating(o1, b.id, 10)
    grid.refresh()
    qtbot.wait(60)
    assert grid.flow.count() == 2


def test_detail_cover_from_file(app, qtbot, tmp_path):
    from PIL import Image
    from ost_tracker.ui.detail_view import DetailView

    oid = ost_repo.add_ost("Song", "Game", None)
    src = tmp_path / "art.png"
    Image.new("RGB", (100, 100), (12, 34, 56)).save(src)

    view = DetailView()
    qtbot.addWidget(view)
    view.load(oid)
    # Drive the import directly (bypassing the native file dialog).
    from ost_tracker.services import coverart
    result = coverart.import_cover_from_file(oid, src)
    ost_repo.set_cover(oid, str(result.path))
    assert ost_repo.get_ost(oid).cover_image_path is not None
