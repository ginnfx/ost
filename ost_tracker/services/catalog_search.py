"""Search several music catalogs for track ideas in Notes."""

from __future__ import annotations

import concurrent.futures
import threading
import time

import httpx

_APPLE_URL = "https://itunes.apple.com/search"
_DEEZER_URL = "https://api.deezer.com/search"
_MUSICBRAINZ_URL = "https://musicbrainz.org/ws/2/recording/"
_MUSICBRAINZ_AGENT = "OSTTracker/0.1.0 (https://github.com/ginnfx/ost)"
_TIMEOUT = httpx.Timeout(8.0, connect=4.0)
_cache: dict[str, tuple[float, list[dict]]] = {}
_lock = threading.Lock()
_musicbrainz_lock = threading.Lock()
_last_musicbrainz_request = 0.0


def _apple(query: str) -> list[dict]:
    response = httpx.get(
        _APPLE_URL,
        params={"term": query, "country": "US", "media": "music", "entity": "song", "limit": 10},
        timeout=_TIMEOUT,
    )
    response.raise_for_status()
    results = []
    for item in response.json().get("results", []):
        track_id = item.get("trackId")
        title = (item.get("trackName") or "").strip()
        if not isinstance(track_id, int) or not title:
            continue
        results.append({
            "id": f"apple:{track_id}",
            "title": title,
            "artist": item.get("artistName") or "",
            "collection": item.get("collectionName") or "",
            "store_url": item.get("trackViewUrl") or None,
            "provider": "Apple Music",
        })
    return results


def _deezer(query: str) -> list[dict]:
    response = httpx.get(_DEEZER_URL, params={"q": query, "limit": 10}, timeout=_TIMEOUT)
    response.raise_for_status()
    payload = response.json()
    if "error" in payload:
        raise ValueError("Deezer search failed")
    results = []
    for item in payload.get("data", []):
        track_id = item.get("id")
        title = (item.get("title") or "").strip()
        if not track_id or not title:
            continue
        results.append({
            "id": f"deezer:{track_id}",
            "title": title,
            "artist": (item.get("artist") or {}).get("name") or "",
            "collection": (item.get("album") or {}).get("title") or "",
            "store_url": item.get("link") or None,
            "provider": "Deezer",
        })
    return results


def _musicbrainz(query: str) -> list[dict]:
    # MusicBrainz asks each client to stay below one request per second.
    global _last_musicbrainz_request
    with _musicbrainz_lock:
        remaining = 1.0 - (time.monotonic() - _last_musicbrainz_request)
        if remaining > 0:
            time.sleep(remaining)
        _last_musicbrainz_request = time.monotonic()
    response = httpx.get(
        _MUSICBRAINZ_URL,
        params={"query": query, "fmt": "json", "limit": 10},
        headers={"User-Agent": _MUSICBRAINZ_AGENT},
        timeout=_TIMEOUT,
    )
    response.raise_for_status()
    results = []
    for item in response.json().get("recordings", []):
        recording_id = item.get("id")
        title = (item.get("title") or "").strip()
        if not recording_id or not title:
            continue
        credits = item.get("artist-credit") or []
        artist = "".join(
            credit if isinstance(credit, str) else (credit.get("name") or "")
            for credit in credits
        ).strip()
        releases = item.get("releases") or []
        collection = next((release.get("title") for release in releases if release.get("title")), "")
        results.append({
            "id": f"musicbrainz:{recording_id}",
            "title": title,
            "artist": artist,
            "collection": collection,
            "store_url": f"https://musicbrainz.org/recording/{recording_id}",
            "provider": "MusicBrainz",
        })
    return results


def search_tracks(query: str) -> list[dict]:
    query = " ".join(query.strip().split())
    if len(query) < 3:
        return []
    key = query.casefold()
    with _lock:
        cached = _cache.get(key)
        if cached and cached[0] > time.monotonic():
            return cached[1]

    providers = (_apple, _deezer, _musicbrainz)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(providers)) as pool:
        futures = [pool.submit(provider, query) for provider in providers]
        results = []
        succeeded = False
        failed = False
        for future in futures:
            try:
                results.extend(future.result())
                succeeded = True
            except (httpx.HTTPError, ValueError, TypeError, KeyError, AttributeError):
                failed = True
                continue
    if not succeeded:
        raise httpx.ConnectError("All music catalogs are unavailable")

    if results or not failed:
        with _lock:
            _cache[key] = (time.monotonic() + 300, results)
            if len(_cache) > 100:
                oldest = min(_cache, key=lambda k: _cache[k][0])
                _cache.pop(oldest, None)
    return results
