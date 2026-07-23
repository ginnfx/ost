"""Playback: stream resolution, browser fallback, and the transport bar."""

from __future__ import annotations

import pytest

pytest.importorskip("pytestqt")

from ost_tracker.services import playback as playback_service
from ost_tracker.services.playback import format_time, resolve_stream_url


@pytest.fixture()
def app(fresh_db, qtbot):
    from PySide6.QtWidgets import QApplication

    return QApplication.instance()


# --- pure service ------------------------------------------------------------

class TestFormatTime:
    def test_zero(self):
        assert format_time(0) == "0:00"

    def test_seconds_pad(self):
        assert format_time(65_000) == "1:05"

    def test_long_track(self):
        assert format_time(605_000) == "10:05"

    def test_negative_reads_zero(self):
        assert format_time(-500) == "0:00"


class TestResolveStreamUrl:
    def test_empty_link_returns_none(self):
        assert resolve_stream_url(None) is None
        assert resolve_stream_url("   ") is None

    def test_module_result_wins(self, monkeypatch):
        monkeypatch.setattr(
            playback_service, "_resolve_via_module", lambda link: "https://stream/x"
        )
        assert resolve_stream_url("https://youtu.be/abc") == "https://stream/x"

    def test_falls_through_to_cli(self, monkeypatch):
        monkeypatch.setattr(playback_service, "_resolve_via_module", lambda link: None)
        monkeypatch.setattr(
            playback_service, "_resolve_via_cli", lambda link: "https://stream/cli"
        )
        assert resolve_stream_url("https://youtu.be/abc") == "https://stream/cli"

    def test_resolver_exceptions_mean_none(self, monkeypatch):
        def boom(link):
            raise RuntimeError("yt-dlp out of date")

        monkeypatch.setattr(playback_service, "_resolve_via_module", boom)
        monkeypatch.setattr(playback_service, "_resolve_via_cli", boom)
        assert resolve_stream_url("https://youtu.be/abc") is None

    def test_cli_missing_binary_returns_none(self, monkeypatch):
        monkeypatch.setattr(playback_service.shutil, "which", lambda name: None)
        assert playback_service._resolve_via_cli("https://youtu.be/abc") is None

    def test_cli_success_returns_first_stdout_line(self, monkeypatch):
        monkeypatch.setattr(playback_service.shutil, "which", lambda name: "/bin/yt-dlp")

        class FakeResult:
            returncode = 0
            stdout = "https://stream/one\nhttps://stream/two\n"

        monkeypatch.setattr(
            playback_service.subprocess, "run", lambda *a, **k: FakeResult()
        )
        assert playback_service._resolve_via_cli("x") == "https://stream/one"

    def test_cli_nonzero_exit_returns_none(self, monkeypatch):
        monkeypatch.setattr(playback_service.shutil, "which", lambda name: "/bin/yt-dlp")

        class FakeResult:
            returncode = 1
            stdout = ""

        monkeypatch.setattr(
            playback_service.subprocess, "run", lambda *a, **k: FakeResult()
        )
        assert playback_service._resolve_via_cli("x") is None

    def test_module_resolver_reads_url_from_info(self, monkeypatch):
        import sys
        import types

        class FakeYDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def extract_info(self, link, download=False):
                return {"url": "https://stream/module"}

        fake = types.ModuleType("yt_dlp")
        fake.YoutubeDL = FakeYDL
        monkeypatch.setitem(sys.modules, "yt_dlp", fake)
        assert playback_service._resolve_via_module("x") == "https://stream/module"

    def test_module_resolver_takes_first_playlist_entry(self, monkeypatch):
        import sys
        import types

        class FakeYDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def extract_info(self, link, download=False):
                return {"entries": [None, {"url": "https://stream/entry"}]}

        fake = types.ModuleType("yt_dlp")
        fake.YoutubeDL = FakeYDL
        monkeypatch.setitem(sys.modules, "yt_dlp", fake)
        assert playback_service._resolve_via_module("x") == "https://stream/entry"


# --- resolution pipeline -------------------------------------------------------

class TestResolvePipeline:
    def test_youtube_external_link_extracts_directly(self, monkeypatch):
        from ost_tracker.services import link_resolver

        searched = []
        monkeypatch.setattr(
            link_resolver, "resolve_stream_url", lambda link: f"stream::{link}"
        )
        monkeypatch.setattr(
            link_resolver, "_parallel_search", lambda *a: searched.append(a)
        )
        res = link_resolver.resolve_playback("Song", "Game", "https://youtu.be/abc")
        assert res.stream_url == "stream::https://youtu.be/abc"
        assert res.watch_url == "https://youtu.be/abc"
        assert searched == []  # no search needed — direct extraction won

    def test_cached_watch_url_wins_over_everything(self, monkeypatch):
        from ost_tracker.services import link_resolver

        monkeypatch.setattr(
            link_resolver, "resolve_stream_url", lambda link: f"stream::{link}"
        )
        res = link_resolver.resolve_playback(
            "Song", "Game", "https://youtu.be/abc",
            cached_watch_url="https://www.youtube.com/watch?v=cached",
        )
        assert res.watch_url == "https://www.youtube.com/watch?v=cached"

    def test_missing_link_falls_through_to_search(self, monkeypatch):
        from ost_tracker.services import link_resolver

        monkeypatch.setattr(
            link_resolver, "_parallel_search",
            lambda title, source: "https://www.youtube.com/watch?v=found",
        )
        monkeypatch.setattr(
            link_resolver, "resolve_stream_url", lambda link: f"stream::{link}"
        )
        res = link_resolver.resolve_playback("Song", "Game", None)
        assert res.stream_url == "stream::https://www.youtube.com/watch?v=found"
        assert res.watch_url == "https://www.youtube.com/watch?v=found"

    def test_non_youtube_link_is_not_extracted_directly(self, monkeypatch):
        from ost_tracker.services import link_resolver

        extracted = []

        def fake_extract(link):
            extracted.append(link)
            return None

        monkeypatch.setattr(link_resolver, "resolve_stream_url", fake_extract)
        monkeypatch.setattr(link_resolver, "_parallel_search", lambda *a: None)
        res = link_resolver.resolve_playback(
            "Song", "Game", "https://open.spotify.com/track/x"
        )
        assert extracted == []  # Spotify page never goes through yt-dlp
        # ...but it remains the best candidate for the browser fallback.
        assert res.stream_url is None
        assert res.fallback_link == "https://open.spotify.com/track/x"

    def test_search_winner_that_fails_extraction_becomes_fallback(self, monkeypatch):
        from ost_tracker.services import link_resolver

        monkeypatch.setattr(
            link_resolver, "_parallel_search",
            lambda title, source: "https://www.youtube.com/watch?v=dead",
        )
        monkeypatch.setattr(link_resolver, "resolve_stream_url", lambda link: None)
        res = link_resolver.resolve_playback("Song", "Game", None)
        assert res.stream_url is None
        assert res.fallback_link == "https://www.youtube.com/watch?v=dead"

    def test_parallel_search_first_usable_url_wins(self, monkeypatch):
        """The fan-out really runs concurrently and the first usable YouTube
        URL wins — slower searches are abandoned."""
        import threading
        import time as time_mod

        from ost_tracker.services import link_resolver

        release_slow = threading.Event()

        def fast_search(query):
            return "https://www.youtube.com/watch?v=fast"

        def slow_search(title, source):
            release_slow.wait(5)  # would block far past the assertion
            return "https://www.youtube.com/watch?v=slow"

        monkeypatch.setattr(link_resolver, "_youtube_search", fast_search)
        monkeypatch.setattr(link_resolver, "_spotify_refined_search", slow_search)
        monkeypatch.setattr(link_resolver, "_bing_search", slow_search)

        started = time_mod.monotonic()
        winner = link_resolver._parallel_search("Song", "Game")
        elapsed = time_mod.monotonic() - started
        release_slow.set()  # let the abandoned threads die

        assert winner == "https://www.youtube.com/watch?v=fast"
        assert elapsed < 4  # did not wait for the slow threads

    def test_is_youtube_url(self):
        from ost_tracker.services.link_resolver import is_youtube_url

        assert is_youtube_url("https://youtu.be/abc")
        assert is_youtube_url("https://www.youtube.com/watch?v=abc")
        assert is_youtube_url("https://music.youtube.com/watch?v=abc")
        assert not is_youtube_url("https://open.spotify.com/track/x")
        assert not is_youtube_url(None)
        assert not is_youtube_url("   ")

    def test_search_skips_spotify_and_bing_without_keys(self, monkeypatch):
        """Degraded mode: with no credentials configured the pipeline is
        YouTube-only but still functional."""
        from ost_tracker.services import link_resolver

        monkeypatch.setattr(link_resolver.config, "get_spotify_credentials", lambda: None)
        monkeypatch.setattr(link_resolver.config, "get_bing_api_key", lambda: None)
        assert link_resolver._spotify_refined_search("Song", "Game") is None
        assert link_resolver._bing_search("Song", "Game") is None


class TestWatchUrlCache:
    def test_repo_roundtrip_and_clear(self, fresh_db):
        from ost_tracker.db import ost_repo

        oid = ost_repo.add_ost("Song", "Game", None)
        assert ost_repo.get_playback_watch_url(oid) is None
        ost_repo.set_playback_watch_url(oid, "https://www.youtube.com/watch?v=x")
        assert ost_repo.get_playback_watch_url(oid) == "https://www.youtube.com/watch?v=x"
        ost_repo.set_playback_watch_url(oid, None)  # the manual re-search action
        assert ost_repo.get_playback_watch_url(oid) is None


# --- controller fallback ------------------------------------------------------

class TestControllerFallback:
    def test_failed_resolve_opens_browser_and_stops(self, app, qtbot):
        from ost_tracker.services.link_resolver import Resolution
        from ost_tracker.ui.playback import STATE_STOPPED, PlaybackController

        controller = PlaybackController()
        opened = []
        controller._open_externally = opened.append
        states = []
        controller.state_changed.connect(lambda oid, s: states.append((oid, s)))

        controller._resolving_ost = 7
        controller._on_resolved(7, Resolution(None, None, "https://youtu.be/abc"))

        assert opened == ["https://youtu.be/abc"]
        assert (7, STATE_STOPPED) in states
        assert controller._player is None  # never touched the audio backend

    def test_failed_resolve_with_nothing_to_open_just_stops(self, app, qtbot):
        from ost_tracker.services.link_resolver import Resolution
        from ost_tracker.ui.playback import STATE_STOPPED, PlaybackController

        controller = PlaybackController()
        opened = []
        controller._open_externally = opened.append
        states = []
        controller.state_changed.connect(lambda oid, s: states.append((oid, s)))

        controller._resolving_ost = 7
        controller._on_resolved(7, Resolution(None, None, None))
        assert opened == []
        assert (7, STATE_STOPPED) in states

    def test_stale_resolve_is_dropped(self, app, qtbot):
        from ost_tracker.services.link_resolver import Resolution
        from ost_tracker.ui.playback import PlaybackController

        controller = PlaybackController()
        opened = []
        controller._open_externally = opened.append
        controller._resolving_ost = 8  # user has moved on to another track
        controller._on_resolved(7, Resolution(None, None, "https://youtu.be/abc"))
        assert opened == []

    def test_toggle_without_link_or_title_is_a_noop(self, app, qtbot):
        from ost_tracker.ui.playback import PlaybackController

        controller = PlaybackController()
        controller.toggle(1, None)
        controller.toggle(1, "")
        assert controller._resolving_ost is None
        assert controller._player is None

    def test_research_clears_the_persistent_cache(self, app, qtbot, monkeypatch):
        from ost_tracker.db import ost_repo
        from ost_tracker.ui.playback import PlaybackController

        oid = ost_repo.add_ost("Song", "Game", None)
        ost_repo.set_playback_watch_url(oid, "https://www.youtube.com/watch?v=stale")

        controller = PlaybackController()
        started = []
        monkeypatch.setattr(
            controller, "_start", lambda *a, **k: started.append(a)
        )
        controller.research(oid, None, "Song", "Game")
        assert ost_repo.get_playback_watch_url(oid) is None
        assert started  # a fresh resolve was kicked off


# --- transport bar -------------------------------------------------------------

class TestTransportBar:
    def test_visible_even_without_external_link(self, app, qtbot):
        """The pipeline can search a stream up from the title alone, so the
        transport no longer hides on link-less OSTs."""
        from ost_tracker.ui.playback import TransportBar

        bar = TransportBar()
        qtbot.addWidget(bar)
        bar.show()
        bar.set_ost(1, None, title="Song")
        assert bar.isVisible()

    def test_visible_with_external_link(self, app, qtbot):
        from ost_tracker.ui.playback import TransportBar

        bar = TransportBar()
        qtbot.addWidget(bar)
        bar.show()
        bar.set_ost(1, "https://youtu.be/abc")
        assert bar.isVisible()

    def test_set_ost_accepts_the_record_itself(self, app, qtbot, fresh_db):
        from ost_tracker.db import ost_repo
        from ost_tracker.ui.playback import TransportBar

        oid = ost_repo.add_ost("Song", "Game", None, "https://youtu.be/abc")
        bar = TransportBar()
        qtbot.addWidget(bar)
        bar.set_ost(ost_repo.get_ost(oid))
        assert bar._ost_id == oid
        assert bar._link == "https://youtu.be/abc"
        assert bar._title == "Song"
        assert bar._source == "Game"

    def test_ignores_other_osts_updates(self, app, qtbot):
        from ost_tracker.ui.playback import TransportBar

        bar = TransportBar()
        qtbot.addWidget(bar)
        bar.set_ost(1, "https://youtu.be/abc")
        bar._on_position(2, 5_000, 60_000)  # someone else's track
        assert bar.time_label.text() == "0:00 / 0:00"
        bar._on_position(1, 5_000, 60_000)
        assert bar.time_label.text() == "0:05 / 1:00"

    def test_same_track_reset_keeps_state(self, app, qtbot):
        from ost_tracker.ui.playback import STATE_PLAYING, TransportBar

        bar = TransportBar()
        qtbot.addWidget(bar)
        bar.set_ost(1, "https://youtu.be/abc")
        bar._on_state(1, STATE_PLAYING)
        bar._on_position(1, 5_000, 60_000)
        bar.set_ost(1, "https://youtu.be/abc")  # host rebuilt; same track
        assert bar.time_label.text() == "0:05 / 1:00"  # not clobbered
