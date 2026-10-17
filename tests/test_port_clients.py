"""Tests for the ported native clients' shared logic. Everything imported
here lives in clients/linux/ost_tracker_gtk and is deliberately GTK-free so
CI (and the Windows/Mac devs) can run it with plain pytest."""

from __future__ import annotations

import sys
from pathlib import Path

import httpx
import pytest

ROOT = Path(__file__).resolve().parent.parent
CLIENT_PKG = ROOT / "clients" / "linux"
sys.path.insert(0, str(CLIENT_PKG))

from ost_tracker_gtk import client as gclient  # noqa: E402
from ost_tracker_gtk import lyrics, models, validation  # noqa: E402


# --- validation rules (mirror of Swift AddOstRules) -----------------------------


def test_cannot_submit_without_roster_submitter():
    assert not validation.can_submit("Song", 999, [1, 2])
    assert validation.can_submit("Song", 2, [1, 2])


def test_title_must_not_be_blank():
    assert not validation.can_submit("   ", 1, [1])


def test_conflict_blocks_submit():
    assert not validation.can_submit("Song", 1, [1], has_history_conflict=True)


def test_history_conflict_matches_title_and_source():
    history = [("Neon Skyline", "KOI-1 OST")]
    assert validation.history_conflict("neon skyline", "KOI-1 OST", history)
    # blank source on either side still counts as the same track
    assert validation.history_conflict("neon skyline", "", [("Neon Skyline", "")])


def test_history_conflict_rejects_different_sources():
    history = [("Neon Skyline", "KOI-1 OST")]
    assert validation.history_conflict("Neon Skyline", "Something Else", history) is None


# --- lyrics parsing (mirror of Swift LyricsService) -----------------------------


def test_parse_lrc_sorted_with_multi_timestamps():
    raw = "[00:12.00]second\n[00:05.00]first\n[00:05.50][00:40.00]echo"
    lines = lyrics.parse_lrc(raw)
    assert [l.text for l in lines] == ["first", "echo", "second", "echo"]
    assert lines[0].time == pytest.approx(5.0)
    assert lines[3].time == pytest.approx(40.0)


def test_plain_lyrics_rejects_credit_sheets_and_short_text():
    credits = "Engineer: a\nProducer: b\nGuitar: c\nMixing: d"
    assert lyrics.clean_plain(credits) is None
    assert lyrics.clean_plain("too short") is None
    assert lyrics.clean_plain("Real song lyric line one\n" * 5) is not None


def test_fetch_prefers_synced_and_rejects_credits(monkeypatch):
    tracks = [
        {"trackName": "Song", "syncedLyrics": "[00:01.00]hey\n[00:02.00]ho\n[00:03.00]let's go\n[00:04.00]now",
         "plainLyrics": "", "artistName": "Artist"},
    ]
    class FakeHttp:
        def get(self, url, **kwargs):
            return httpx.Response(200, json=tracks, request=httpx.Request("GET", url))
    result = lyrics.fetch_for("Song", "Album", client=FakeHttp())
    assert result is not None and result.synced and result.synced[0].text == "hey"
    assert result.plain is None


def test_fetch_falls_back_to_plain_then_ovh(monkeypatch):
    # LRCLIB returns nothing synced but does name an artist; then lyrics.ovh.
    class FakeHttp:
        def __init__(self):
            self._ovh_called = False

        def get(self, url, **kwargs):
            if "lrclib" in url:
                return httpx.Response(200, json=[{"trackName": "Song", "syncedLyrics": "",
                                                  "plainLyrics": None, "artistName": "Artist"}],
                                      request=httpx.Request("GET", url))
            return httpx.Response(200, json={"lyrics": "A full plain lyric body that definitely passes the length gate. " * 3},
                                  request=httpx.Request("GET", url))
    result = lyrics.fetch_for("Song", None, client=FakeHttp())
    assert result is not None and result.plain and result.synced is None


# --- HTTP contract client (params + wire shapes) --------------------------------


class FakeTransport(httpx.BaseTransport):
    """Asserts the requests a page-level action must issue, then answers."""

    def __init__(self, handler):
        self.handler = handler

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        return self.handler(request)


def make_client(handler) -> gclient.Client:
    return gclient.Client(1234, "tok", transport=FakeTransport(handler))


def test_add_ost_posts_expected_body():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["method"] = request.method
        seen["path"] = request.url.path
        seen["token"] = request.headers.get("X-OST-Token")
        return httpx.Response(201, json={
            "id": 7, "title": "New OST", "source": None, "submitter_id": 3,
            "submitter_name": None, "cover_image_path": None,
            "cover_accent_hex": None, "external_link": None, "created_at": ""})

    client = make_client(handler)
    ost = client.add_ost("New OST", 3)
    assert seen["method"] == "POST" and seen["path"] == "/osts"
    assert seen["token"] == "tok"
    assert isinstance(ost, models.Ost) and ost.id == 7


def test_add_ost_sends_wire_fields():
    seen_fields = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen_fields["body"] = request.read()
        return httpx.Response(201, json={
            "id": 1, "title": "T", "source": "S", "submitter_id": 2,
            "submitter_name": None, "cover_image_path": None, "cover_accent_hex": None,
            "external_link": None, "created_at": ""})

    client = make_client(handler)
    client.add_ost("T", 2, source="S", external_link="http://x")
    import json as _json
    sent = _json.loads(seen_fields["body"])
    assert sent == {"title": "T", "submitter_id": 2, "source": "S", "external_link": "http://x"}


def test_delete_ost_uses_delete_without_body():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "DELETE" and request.url.path == "/osts/9"
        return httpx.Response(204)

    make_client(handler).delete_ost(9)


def test_player_controls_and_error_detail():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path))
        if request.url.path == "/player/pause":
            return httpx.Response(200, json={"status": "paused"})
        return httpx.Response(404, json={"detail": "nope"})

    client = make_client(handler)
    client.pause()
    assert calls[-1] == ("POST", "/player/pause")
    try:
        client.delete_ost(4)
        raise AssertionError("expected ApiError")
    except gclient.ApiError as exc:
        assert exc.status == 404 and exc.detail == "nope"
