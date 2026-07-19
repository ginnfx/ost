"""Multi-source playback resolution: OST metadata → a playable stream.

Not three parallel audio streams — a *resolution* pipeline (Spotify's API can't
legally hand us a raw stream, so it contributes metadata only):

1. If a cached watch URL or a YouTube ``external_link`` exists, try yt-dlp
   extraction on it directly.
2. Otherwise (or when that extraction fails), fan out a **parallel search**
   for a candidate YouTube page — this is the only concurrent step:
   * YouTube search (``ytsearch`` via yt-dlp, no API key needed),
   * Spotify metadata search (Client Credentials; refines a second YouTube
     search with the canonical artist/title) — skipped without credentials,
   * Bing Web Search for a YouTube link — skipped without an API key.
   The first thread to return a usable YouTube URL wins; the rest are
   cancelled best-effort (abandoned mid-HTTP-call at worst).
3. Extract a stream from the winner via yt-dlp and hand it to QMediaPlayer.
4. If every extraction fails, the caller opens the best candidate link in the
   system browser (graceful degradation, never an error state).

Everything here is synchronous, blocking, and Qt-free: the UI layer runs it on
a worker thread (QThreadPool) and marshals the result back via a queued signal.
Timing/threading is logged on the ``ost_tracker.playback`` logger so the
parallelism is observable, not assumed.
"""

from __future__ import annotations

import concurrent.futures
import logging
import time
from dataclasses import dataclass
from typing import Callable, Optional
from urllib.parse import urlparse

from ost_tracker import config
from ost_tracker.services.playback import resolve_stream_url

logger = logging.getLogger("ost_tracker.playback")

_SEARCH_HTTP_TIMEOUT_S = 10
_YTSEARCH_TIMEOUT_S = 15

_YOUTUBE_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
}


@dataclass(frozen=True)
class Resolution:
    """The pipeline's outcome. ``stream_url`` playable by QMediaPlayer;
    ``watch_url`` the page it came from (cacheable per-OST); ``fallback_link``
    the best thing to open in a browser when ``stream_url`` is None."""

    stream_url: Optional[str]
    watch_url: Optional[str]
    fallback_link: Optional[str]


def is_youtube_url(link: Optional[str]) -> bool:
    if not link or not link.strip():
        return False
    try:
        host = (urlparse(link.strip()).hostname or "").lower()
    except ValueError:
        return False
    return host in _YOUTUBE_HOSTS


def _search_query(title: str, source: Optional[str]) -> str:
    return " ".join(bit for bit in (title, source, "OST") if bit)


# --- search threads -----------------------------------------------------------


def _youtube_search(query: str) -> Optional[str]:
    """A candidate watch URL via yt-dlp's built-in search — no API key."""
    try:
        import yt_dlp
    except ImportError:
        return None
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "extract_flat": True,  # search only — don't resolve formats yet
        "socket_timeout": _YTSEARCH_TIMEOUT_S,
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"ytsearch1:{query}", download=False)
    entries = (info or {}).get("entries") or []
    first = next((e for e in entries if e), None)
    if not first:
        return None
    url = first.get("url") or first.get("webpage_url") or first.get("id")
    if url and not str(url).startswith("http"):
        url = f"https://www.youtube.com/watch?v={url}"
    return url or None


def _spotify_refined_search(title: str, source: Optional[str]) -> Optional[str]:
    """Metadata only: find the canonical artist/track on Spotify, then run a
    *refined* YouTube search with it. Never attempts to stream from Spotify."""
    creds = config.get_spotify_credentials()
    if creds is None:
        return None
    import httpx

    client_id, client_secret = creds
    token_resp = httpx.post(
        "https://accounts.spotify.com/api/token",
        data={"grant_type": "client_credentials"},
        auth=(client_id, client_secret),
        timeout=_SEARCH_HTTP_TIMEOUT_S,
    )
    token_resp.raise_for_status()
    token = token_resp.json().get("access_token")
    if not token:
        return None

    search_resp = httpx.get(
        "https://api.spotify.com/v1/search",
        params={"q": _search_query(title, source), "type": "track", "limit": 1},
        headers={"Authorization": f"Bearer {token}"},
        timeout=_SEARCH_HTTP_TIMEOUT_S,
    )
    search_resp.raise_for_status()
    items = search_resp.json().get("tracks", {}).get("items", [])
    if not items:
        return None
    track = items[0]
    artist = (track.get("artists") or [{}])[0].get("name", "")
    name = track.get("name", "")
    refined = " ".join(bit for bit in (artist, name) if bit)
    if not refined:
        return None
    return _youtube_search(refined)


def _bing_search(title: str, source: Optional[str]) -> Optional[str]:
    """Broad-web fallback: locate a YouTube link via Bing Web Search."""
    key = config.get_bing_api_key()
    if not key:
        return None
    import httpx

    resp = httpx.get(
        "https://api.bing.microsoft.com/v7.0/search",
        params={"q": _search_query(title, source) + " youtube", "count": 10},
        headers={"Ocp-Apim-Subscription-Key": key},
        timeout=_SEARCH_HTTP_TIMEOUT_S,
    )
    resp.raise_for_status()
    pages = resp.json().get("webPages", {}).get("value", [])
    for page in pages:
        url = page.get("url", "")
        if is_youtube_url(url):
            return url
    return None


def _timed(name: str, fn: Callable[[], Optional[str]]) -> Optional[str]:
    started = time.monotonic()
    logger.info("search[%s] started", name)
    try:
        result = fn()
    except Exception as exc:  # any search miss degrades, never raises
        logger.info("search[%s] failed after %.2fs: %s", name, time.monotonic() - started, exc)
        return None
    logger.info(
        "search[%s] finished in %.2fs -> %s", name, time.monotonic() - started, result or "no result"
    )
    return result


# --- the pipeline ---------------------------------------------------------------


def _parallel_search(title: str, source: Optional[str]) -> Optional[str]:
    """Fan the search threads out; first usable YouTube URL wins."""
    query = _search_query(title, source)
    searches: list[tuple[str, Callable[[], Optional[str]]]] = [
        ("youtube", lambda: _youtube_search(query)),
        ("spotify", lambda: _spotify_refined_search(title, source)),
        ("bing", lambda: _bing_search(title, source)),
    ]
    if config.get_spotify_credentials() is None:
        logger.info("search[spotify] skipped — no credentials in config.json (degraded)")
    if not config.get_bing_api_key():
        logger.info("search[bing] skipped — no API key in config.json (degraded)")

    pool = concurrent.futures.ThreadPoolExecutor(
        max_workers=len(searches), thread_name_prefix="ost-linksearch"
    )
    try:
        futures = {pool.submit(_timed, name, fn): name for name, fn in searches}
        for future in concurrent.futures.as_completed(futures):
            url = future.result()  # _timed never raises
            if url and is_youtube_url(url):
                logger.info("search winner: %s -> %s", futures[future], url)
                for other in futures:
                    other.cancel()  # best-effort: pending threads never start
                return url
        return None
    finally:
        pool.shutdown(wait=False, cancel_futures=True)


def resolve_playback(
    title: str,
    source: Optional[str],
    external_link: Optional[str],
    cached_watch_url: Optional[str] = None,
) -> Resolution:
    """Run the full pipeline. Blocking (seconds) — call from a worker thread."""
    started = time.monotonic()

    # Stage 1: direct extraction from what we already trust.
    direct_candidates = [cached_watch_url]
    if external_link and is_youtube_url(external_link):
        direct_candidates.append(external_link)
    for candidate in direct_candidates:
        if not candidate:
            continue
        stream = resolve_stream_url(candidate)
        if stream:
            logger.info("resolved directly from %s in %.2fs", candidate, time.monotonic() - started)
            return Resolution(stream_url=stream, watch_url=candidate, fallback_link=candidate)
        logger.info("direct extraction failed for %s", candidate)

    # Stage 2: parallel search for a candidate page, then extract from it.
    winner = _parallel_search(title, source) if title else None
    if winner:
        stream = resolve_stream_url(winner)
        if stream:
            logger.info("resolved via search in %.2fs total", time.monotonic() - started)
            return Resolution(stream_url=stream, watch_url=winner, fallback_link=winner)
        logger.info("extraction failed for search winner %s", winner)

    # Stage 3: nothing playable — browser fallback with the best link we have.
    fallback = winner or external_link or cached_watch_url
    logger.info(
        "pipeline exhausted in %.2fs — falling back to browser (%s)",
        time.monotonic() - started,
        fallback or "nothing to open",
    )
    return Resolution(stream_url=None, watch_url=None, fallback_link=fallback)
