"""Cover-art pipeline tests. Network is faked with httpx.MockTransport so the
three-stage fallback is exercised deterministically and offline."""

from __future__ import annotations

import io

import httpx
from PIL import Image

from ost_tracker.services import coverart
from ost_tracker.services.coverart import CoverSource


def _png_bytes(color=(10, 20, 30)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (120, 120), color).save(buf, format="PNG")
    return buf.getvalue()


# --- pure helpers -----------------------------------------------------------

def test_upsize_itunes_url():
    url = "https://is1.mzstatic.com/image/thumb/abc/100x100bb.jpg"
    assert coverart.upsize_itunes_url(url) == (
        "https://is1.mzstatic.com/image/thumb/abc/600x600bb.jpg"
    )


def test_upsize_itunes_url_no_token_passthrough():
    url = "https://example.com/art.jpg"
    assert coverart.upsize_itunes_url(url) == url


def test_build_itunes_queries_adds_source():
    q = coverart.build_itunes_queries("Aerith", "Final Fantasy VII")
    assert q[0] == ("Aerith", CoverSource.ITUNES)
    assert q[1] == ("Aerith Final Fantasy VII", CoverSource.ITUNES_WITH_SOURCE)


def test_build_itunes_queries_without_source():
    q = coverart.build_itunes_queries("Aerith", None)
    assert len(q) == 1


def test_pick_itunes_artwork():
    payload = {"results": [{"artworkUrl100": "https://x/100x100bb.jpg"}]}
    assert coverart.pick_itunes_artwork(payload) == "https://x/600x600bb.jpg"
    assert coverart.pick_itunes_artwork({"results": []}) is None


# --- full pipeline with mocked network --------------------------------------

def _client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_fetch_cover_itunes_hit(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        if "itunes.apple.com" in request.url.host:
            return httpx.Response(200, json={"results": [{"artworkUrl100": "https://img/100x100bb.jpg"}]})
        if request.url.host == "img":
            return httpx.Response(200, content=_png_bytes())
        return httpx.Response(404)

    with _client(handler) as c:
        result = coverart.fetch_cover(1, "Some Song", "Some Game", client=c)
    assert result.found
    assert result.source == CoverSource.ITUNES
    assert result.path.exists()
    # Cached file is a square JPEG at the store size.
    with Image.open(result.path) as img:
        assert img.size == (coverart.COVER_STORE_SIZE, coverart.COVER_STORE_SIZE)


def test_fetch_cover_falls_back_to_source_query(fresh_db):
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if "itunes.apple.com" in request.url.host:
            calls["n"] += 1
            term = request.url.params.get("term")
            if term == "Song Game":  # only the source-augmented query hits
                return httpx.Response(200, json={"results": [{"artworkUrl100": "https://img/100x100bb.jpg"}]})
            return httpx.Response(200, json={"results": []})
        if request.url.host == "img":
            return httpx.Response(200, content=_png_bytes())
        return httpx.Response(404)

    with _client(handler) as c:
        result = coverart.fetch_cover(2, "Song", "Game", client=c)
    assert result.source == CoverSource.ITUNES_WITH_SOURCE
    assert calls["n"] == 2


def test_fetch_cover_falls_back_to_musicbrainz(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        host = request.url.host
        if "itunes.apple.com" in host:
            return httpx.Response(200, json={"results": []})
        if "musicbrainz.org" in host:
            return httpx.Response(200, json={"releases": [{"id": "mbid-123"}]})
        if "coverartarchive.org" in host:
            if request.method == "HEAD":
                return httpx.Response(200)
            return httpx.Response(200, content=_png_bytes((90, 10, 10)))
        return httpx.Response(404)

    with _client(handler) as c:
        result = coverart.fetch_cover(3, "Obscure", "Doujin", client=c)
    assert result.source == CoverSource.MUSICBRAINZ
    assert result.path.exists()


def test_fetch_cover_all_miss_returns_none(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        if "musicbrainz.org" in request.url.host:
            return httpx.Response(200, json={"releases": []})
        return httpx.Response(200, json={"results": []})

    with _client(handler) as c:
        result = coverart.fetch_cover(4, "Nope", None, client=c)
    assert not result.found
    assert result.source == CoverSource.NONE


def test_fetch_cover_survives_network_error(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    with _client(handler) as c:
        result = coverart.fetch_cover(5, "Anything", "Game", client=c)
    assert not result.found  # degrades to no cover, does not raise


def test_import_cover_from_file(fresh_db, tmp_path):
    src = tmp_path / "art.png"
    Image.new("RGB", (200, 150), (5, 5, 200)).save(src)
    result = coverart.import_cover_from_file(9, src)
    assert result.found
    with Image.open(result.path) as img:
        assert img.size == (coverart.COVER_STORE_SIZE, coverart.COVER_STORE_SIZE)


def test_import_cover_from_url(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=_png_bytes((0, 128, 0)))

    with _client(handler) as c:
        result = coverart.import_cover_from_url(10, "https://x/img.png", client=c)
    assert result.found


# --- multi-source candidate search (cover picker) ---------------------------

def test_youtube_video_id_forms():
    yid = coverart.youtube_video_id
    assert yid("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ"
    assert yid("https://youtu.be/dQw4w9WgXcQ?t=42") == "dQw4w9WgXcQ"
    assert yid("https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ"
    assert yid("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDx") == "dQw4w9WgXcQ"
    assert yid("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ"
    assert yid("https://open.spotify.com/track/abc") is None
    assert yid("not a url at all") is None
    assert yid(None) is None


def test_youtube_thumbnail():
    img, thumb = coverart.youtube_thumbnail("dQw4w9WgXcQ")
    assert img.endswith("dQw4w9WgXcQ/hqdefault.jpg")
    assert thumb.endswith("dQw4w9WgXcQ/default.jpg")


def test_search_candidates_aggregates_and_dedupes(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        host = request.url.host
        if "itunes.apple.com" in host:
            if request.url.params.get("entity") == "album":
                return httpx.Response(200, json={"results": [
                    {"artworkUrl100": "https://img/alb/100x100bb.jpg",
                     "collectionName": "OST Album", "artistName": "Composer"}]})
            return httpx.Response(200, json={"results": [
                {"artworkUrl100": "https://img/song/100x100bb.jpg",
                 "trackName": "Song", "artistName": "Composer"}]})
        if "musicbrainz.org" in host:
            return httpx.Response(200, json={"releases": [{"id": "mbid-1", "title": "Rel"}]})
        if "youtube.com/results" in url:
            return httpx.Response(200, text=(
                '"videoRenderer":{"videoId":"abcdefghijk",'
                '"title":{"runs":[{"text":"Song Game OST"}]}}'
                '"videoRenderer":{"videoId":"abcdefghijk",'
                '"title":{"runs":[{"text":"dupe"}]}}'
            ))
        return httpx.Response(404)

    with _client(handler) as c:
        cands = coverart.search_candidates(
            "Song", "Game", external_link="https://youtu.be/dQw4w9WgXcQ", client=c
        )

    sources = {c.source_name for c in cands}
    assert {"Your link", "iTunes", "iTunes album", "MusicBrainz", "YouTube"} <= sources
    # The OST's own link is surfaced first, as the most trustworthy.
    assert cands[0].source_name == "Your link"
    # The YouTube search result carries the parsed video title as its label.
    yt = [c for c in cands if c.source_name == "YouTube"]
    assert yt and yt[0].label == "Song Game OST"
    # Deduped by image URL (iTunes song queried twice, YouTube id repeated).
    urls = [c.image_url for c in cands]
    assert len(urls) == len(set(urls))


def test_bing_candidates_included_when_key_present(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        host = request.url.host
        if "api.bing.microsoft.com" in host:
            assert request.headers.get("Ocp-Apim-Subscription-Key") == "test-key"
            return httpx.Response(200, json={"value": [
                {"contentUrl": "https://bing/full.jpg",
                 "thumbnailUrl": "https://bing/thumb.jpg", "name": "Cover Art"}]})
        return httpx.Response(200, json={"results": []})

    with _client(handler) as c:
        cands = coverart.search_candidates("Song", "Game", client=c, bing_api_key="test-key")
    bing = [x for x in cands if x.source_name == "Bing"]
    assert bing and bing[0].image_url == "https://bing/full.jpg"
    assert bing[0].thumb_url == "https://bing/thumb.jpg"


def test_bing_skipped_without_key(fresh_db):
    calls = {"bing": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if "api.bing.microsoft.com" in request.url.host:
            calls["bing"] += 1
        return httpx.Response(200, json={"results": []})

    with _client(handler) as c:
        coverart.search_candidates("Song", "Game", client=c, bing_api_key=None)
    assert calls["bing"] == 0  # no key configured -> tier skipped entirely


def test_candidate_relevance_and_franchise_filter():
    ca = coverart
    # Franchise present -> kept; absent -> filtered.
    assert ca.is_franchise_relevant("Yakuza 0 — Baka Mitai", "Baka Mitai", "Yakuza")
    assert not ca.is_franchise_relevant("Random Pop Single", "Baka Mitai", "Yakuza")
    # No franchise given -> nothing is filtered.
    assert ca.is_franchise_relevant("anything at all", "Title", None)
    # A franchise-matching candidate outscores a title-only one.
    s_franchise = ca.candidate_relevance("Yakuza Baka Mitai", "Baka Mitai", "Yakuza")
    s_title_only = ca.candidate_relevance("Baka Mitai (piano cover)", "Baka Mitai", "Yakuza")
    assert s_franchise > s_title_only


def test_search_candidates_survives_all_sources_down(fresh_db):
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline")

    with _client(handler) as c:
        cands = coverart.search_candidates("Song", "Game", client=c)
    assert cands == []  # no raise, just empty
