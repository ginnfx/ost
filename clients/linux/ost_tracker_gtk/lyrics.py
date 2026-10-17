"""LRCLIB lyrics for the Linux client — Python mirror of the macOS
LyricsService: synced lines parsed from LRC, plain lyrics as fallback via
lyrics.ovh, instrumentation-credit sheets rejected. GTK-free so tests can
import it; production hits cache on disk under the app config dir."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import quote

import httpx

_LRCLIB_SEARCH = "https://lrclib.net/api/search"
_LYRICSOVH = "https://api.lyrics.ovh/v1/{artist}/{title}"
_HEADERS = {"User-Agent": "OSTTracker/1.0"}
_CREDIT_MARKERS = ("saxophone", "recording", "engineer", "mixing", "mastering",
                   "produced by", "guitar", "studio", "vocals", "arranged by")


@dataclass
class LyricLine:
    time: float
    text: str


@dataclass
class LyricsResult:
    synced: Optional[list[LyricLine]] = None
    plain: Optional[str] = None
    artist: Optional[str] = None


def looks_like_credits(text: str) -> bool:
    """Instrumentation sheets pass themselves off as lyrics — reject them,
    same heuristic as the Swift app."""
    lines = [line.strip() for line in text.splitlines()
             if line.strip() and line.strip() != "♪"]
    if len(lines) < 3:
        return False
    credit_lines = [
        line for line in lines
        if ":" in line or any(m in line.lower() for m in _CREDIT_MARKERS)
    ]
    return len(credit_lines) >= 3 and len(credit_lines) * 2 >= len(lines)


def parse_lrc(raw: str) -> list[LyricLine]:
    """Parse `[mm:ss.xx] text` lines; multiple leading timestamps fan out
    into repeated lines, exactly like the Swift parser."""
    out: list[LyricLine] = []
    for raw_line in raw.splitlines():
        text = raw_line.strip()
        stamps: list[float] = []
        while text.startswith("["):
            tag = re.match(r"^\[(\d+):(\d+(?:\.\d+)?)\](.*)$", text)
            if not tag:
                break
            minutes, seconds, text = tag.groups()
            stamps.append(float(minutes) * 60 + float(seconds))
        if not stamps:
            continue
        text = text.strip()
        for stamp in stamps:
            out.append(LyricLine(stamp, text or "♪"))
    return sorted(out, key=lambda line: line.time)


def clean_plain(text: Optional[str]) -> Optional[str]:
    if not text:
        return None
    value = text.strip()
    return value if len(value) >= 40 and not looks_like_credits(value) else None


def fetch(ost, *, client: Optional[httpx.Client] = None,
          cache_dir: Optional[Path] = None) -> Optional[LyricsResult]:
    """Best lyric record for one OST: usable synced lines first, then plain
    lyrics (LRCLIB first, then lyrics.ovh with the artist LRCLIB agreed on)."""
    return fetch_for(ost.title, ost.source, client=client, cache_dir=cache_dir)


def fetch_for(title: str, source: Optional[str], *,
              client: Optional[httpx.Client] = None,
              cache_dir: Optional[Path] = None) -> Optional[LyricsResult]:
    own_client = client is None
    http = client or httpx.Client(timeout=10.0)
    try:
        key = f"{title.lower().strip()}|{(source or '').lower().strip()}"
        if cached := _read_cache(cache_dir, key):
            return cached

        queries = [title] if not source else [title, f"{title} {source}"]
        rows: list[dict] = []
        for query in queries:
            rows.extend(_search_lrclib(http, query))

        synced: Optional[list[LyricLine]] = None
        plain: Optional[str] = None
        artist: Optional[str] = None
        for row in rows:
            artist = artist or row.get("artistName") or None
            raw = (row.get("syncedLyrics") or "").strip()
            if synced is None and raw:
                lines = parse_lrc(raw)
                # Credits rejection reads the lyric text only — timestamps
                # would trip the ':' rule (same as the Swift app).
                joined = "\n".join(line.text for line in lines)
                if len(lines) >= 4 and not looks_like_credits(joined):
                    synced = lines
            plain = plain or clean_plain(row.get("plainLyrics"))

        if plain is None and artist:
            plain = _lyrics_ovh(http, artist, title)

        result = LyricsResult(synced=synced, plain=plain, artist=artist)
        if result.synced or result.plain:
            _write_cache(cache_dir, key, result)
        return result
    finally:
        if own_client:
            http.close()


def _cache_file(cache_dir: Optional[Path], key: str) -> Optional[Path]:
    if cache_dir is None:
        return None
    digest = hashlib.sha256(key.encode()).hexdigest()
    return cache_dir / f"{digest}.json"


def _read_cache(cache_dir: Optional[Path], key: str) -> Optional[LyricsResult]:
    path = _cache_file(cache_dir, key)
    if path is None:
        return None
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return LyricsResult(
        synced=[LyricLine(**line) for line in (data.get("synced") or [])] or None,
        plain=data.get("plain"),
        artist=data.get("artist"),
    )


def _write_cache(cache_dir: Optional[Path], key: str, result: LyricsResult) -> None:
    path = _cache_file(cache_dir, key)
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "synced": [{"time": line.time, "text": line.text}
                   for line in (result.synced or [])],
        "plain": result.plain,
        "artist": result.artist,
    }
    try:
        path.write_text(json.dumps(payload))
    except OSError:
        pass


def _search_lrclib(http: httpx.Client, query: str) -> list[dict]:
    try:
        resp = http.get(_LRCLIB_SEARCH, params={"q": query}, headers=_HEADERS)
    except httpx.HTTPError:
        return []
    if resp.status_code != 200:
        return []
    try:
        rows = resp.json()
    except ValueError:
        return []
    return rows if isinstance(rows, list) else []


def _lyrics_ovh(http: httpx.Client, artist: str, title: str) -> Optional[str]:
    url = _LYRICSOVH.format(artist=quote(artist, safe=""), title=quote(title, safe=""))
    try:
        resp = http.get(url)
    except httpx.HTTPError:
        return None
    if resp.status_code != 200:
        return None
    try:
        payload = resp.json()
    except ValueError:
        return None
    return clean_plain(payload.get("lyrics")) if isinstance(payload, dict) else None
