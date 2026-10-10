"""Small, cached song lookup for the Notes shortlist."""

from __future__ import annotations

import threading
import time

import httpx

_ENDPOINT = "https://itunes.apple.com/search"
_cache: dict[str, tuple[float, list[dict]]] = {}
_lock = threading.Lock()


def search_tracks(query: str) -> list[dict]:
    query = " ".join(query.strip().split())
    if len(query) < 3:
        return []
    key = query.casefold()
    with _lock:
        cached = _cache.get(key)
        if cached and cached[0] > time.monotonic():
            return cached[1]

    response = httpx.get(
        _ENDPOINT,
        params={"term": query, "country": "US", "media": "music", "entity": "song", "limit": 15},
        timeout=httpx.Timeout(8.0, connect=4.0),
    )
    response.raise_for_status()
    results: list[dict] = []
    seen: set[int] = set()
    for item in response.json().get("results", []):
        track_id = item.get("trackId")
        title = (item.get("trackName") or "").strip()
        if not isinstance(track_id, int) or not title or track_id in seen:
            continue
        seen.add(track_id)
        results.append({
            "id": track_id,
            "title": title,
            "artist": item.get("artistName") or "",
            "collection": item.get("collectionName") or "",
            "store_url": item.get("trackViewUrl") or None,
        })
    with _lock:
        _cache[key] = (time.monotonic() + 300, results)
        if len(_cache) > 100:
            oldest = min(_cache, key=lambda k: _cache[k][0])
            _cache.pop(oldest, None)
    return results
