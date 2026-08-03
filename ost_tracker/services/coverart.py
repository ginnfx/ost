"""Cover-art fetch pipeline.

Ordered fallback (each stage tried only if the previous missed):

1. iTunes Search API — ``entity=song``, take ``artworkUrl100`` and upsize the
   URL from ``100x100`` to ``600x600``.
2. iTunes again with the source (game/anime/media) appended to the title, which
   rescues a lot of soundtrack tracks that the bare title misses.
3. MusicBrainz release search + the Cover Art Archive front image.

Whatever a stage returns is downloaded and re-encoded to a square local JPEG via
Pillow; the pipeline stores and returns a **local path**, never a remote URL, so
the app renders fully offline after the initial fetch. Every network call is
wrapped so a miss or an outage degrades to "no cover" rather than raising — the
UI guarantees a placeholder, so a ``None`` here is always survivable.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlparse

import httpx

from ost_tracker.config import COVER_STORE_SIZE, covers_dir, get_bing_api_key
from ost_tracker.services import images

_ITUNES_ENDPOINT = "https://itunes.apple.com/search"
_MUSICBRAINZ_ENDPOINT = "https://musicbrainz.org/ws/2/release/"
_CAA_TEMPLATE = "https://coverartarchive.org/release/{mbid}/front-500"
_CAA_THUMB_TEMPLATE = "https://coverartarchive.org/release/{mbid}/front-250"
_YOUTUBE_SEARCH = "https://www.youtube.com/results"
_BING_ENDPOINT = "https://api.bing.microsoft.com/v7.0/images/search"

# MusicBrainz requires a descriptive User-Agent or it rate-limits/blocks.
_USER_AGENT = "OSTTracker/1.0 (local desktop app; personal use)"
_BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0 Safari/537.36"
)
_TIMEOUT = httpx.Timeout(12.0, connect=6.0)


class CoverSource(str, Enum):
    ITUNES = "itunes"
    ITUNES_WITH_SOURCE = "itunes+source"
    MUSICBRAINZ = "musicbrainz"
    NONE = "none"


@dataclass(frozen=True)
class CoverResult:
    path: Optional[Path]
    source: CoverSource
    accent_hex: Optional[str] = None

    @property
    def found(self) -> bool:
        return self.path is not None


@dataclass(frozen=True)
class CoverCandidate:
    """One option in the cover picker: a full-size image to cache plus a small
    thumbnail to show in the grid, labelled by where it came from."""

    image_url: str
    thumb_url: str
    label: str
    source_name: str


# --- URL helpers (pure, unit-tested) ---------------------------------------

def upsize_itunes_url(url: str, size: int = COVER_STORE_SIZE) -> str:
    """Rewrite an iTunes ``artworkUrl100`` to a larger square.

    The URLs end in ``.../100x100bb.jpg``; iTunes serves arbitrary sizes if we
    substitute the dimensions. Falls back to the original URL if the expected
    ``100x100`` token isn't present.
    """
    token = f"{size}x{size}"
    if "100x100" in url:
        return url.replace("100x100", token)
    return url


def build_itunes_queries(title: str, source: Optional[str]) -> list[tuple[str, CoverSource]]:
    """Ordered (query, tag) attempts for the two iTunes stages."""
    title = (title or "").strip()
    queries: list[tuple[str, CoverSource]] = [(title, CoverSource.ITUNES)]
    if source and source.strip():
        queries.append((f"{title} {source.strip()}", CoverSource.ITUNES_WITH_SOURCE))
    return queries


def pick_itunes_artwork(payload: dict) -> Optional[str]:
    """Extract the best artwork URL from an iTunes Search response, upsized."""
    results = payload.get("results") or []
    for item in results:
        art = item.get("artworkUrl100") or item.get("artworkUrl60")
        if art:
            return upsize_itunes_url(art)
    return None


# --- network stages ---------------------------------------------------------

def _itunes_lookup(client: httpx.Client, term: str) -> Optional[str]:
    if not term.strip():
        return None
    try:
        resp = client.get(
            _ITUNES_ENDPOINT,
            params={"term": term, "entity": "song", "limit": 5},
        )
        resp.raise_for_status()
        return pick_itunes_artwork(resp.json())
    except (httpx.HTTPError, ValueError):
        return None


def _musicbrainz_lookup(client: httpx.Client, term: str) -> Optional[str]:
    if not term.strip():
        return None
    try:
        resp = client.get(
            _MUSICBRAINZ_ENDPOINT,
            params={"query": term, "fmt": "json", "limit": 5},
            headers={"User-Agent": _USER_AGENT},
        )
        resp.raise_for_status()
        releases = resp.json().get("releases") or []
        for rel in releases:
            mbid = rel.get("id")
            if not mbid:
                continue
            caa_url = _CAA_TEMPLATE.format(mbid=mbid)
            # Confirm the archive actually has a front image before committing.
            try:
                head = client.head(caa_url, follow_redirects=True)
                if head.status_code == 200:
                    return str(head.url)
            except httpx.HTTPError:
                continue
        return None
    except (httpx.HTTPError, ValueError):
        return None


def _download(client: httpx.Client, url: str, dest: Path) -> tuple[Optional[Path], Optional[str]]:
    try:
        resp = client.get(url, follow_redirects=True, headers={"User-Agent": _USER_AGENT})
        resp.raise_for_status()
        return images.save_cover_from_bytes(resp.content, dest, COVER_STORE_SIZE)
    except (httpx.HTTPError, OSError, ValueError):
        return None, None


def cover_path_for(ost_id: int) -> Path:
    return covers_dir() / f"cover_{ost_id}.jpg"


# --- orchestration ----------------------------------------------------------

def fetch_cover(
    ost_id: int,
    title: str,
    source: Optional[str] = None,
    client: Optional[httpx.Client] = None,
) -> CoverResult:
    """Run the full pipeline for one OST and cache the result to disk.

    Returns a :class:`CoverResult`; ``result.path`` is ``None`` when all three
    stages miss (expected for obscure/doujin OSTs — the user overrides manually).
    """
    dest = cover_path_for(ost_id)
    owns_client = client is None
    if client is None:
        client = httpx.Client(timeout=_TIMEOUT, headers={"User-Agent": _USER_AGENT})
    try:
        for term, tag in build_itunes_queries(title, source):
            art_url = _itunes_lookup(client, term)
            if art_url:
                saved, accent_hex = _download(client, art_url, dest)
                if saved:
                    return CoverResult(path=saved, source=tag, accent_hex=accent_hex)

        mb_url = _musicbrainz_lookup(client, f"{title} {source or ''}".strip())
        if mb_url:
            saved, accent_hex = _download(client, mb_url, dest)
            if saved:
                return CoverResult(path=saved, source=CoverSource.MUSICBRAINZ, accent_hex=accent_hex)

        return CoverResult(path=None, source=CoverSource.NONE)
    finally:
        if owns_client:
            client.close()


def import_cover_from_url(ost_id: int, url: str, client: Optional[httpx.Client] = None) -> CoverResult:
    """Manual override: fetch a user-pasted image URL and cache it."""
    dest = cover_path_for(ost_id)
    owns_client = client is None
    if client is None:
        client = httpx.Client(timeout=_TIMEOUT, headers={"User-Agent": _USER_AGENT})
    try:
        saved, accent_hex = _download(client, url, dest)
        return CoverResult(path=saved, source=CoverSource.NONE if saved is None else CoverSource.ITUNES,
                           accent_hex=accent_hex)
    finally:
        if owns_client:
            client.close()


def import_cover_from_file(ost_id: int, src_path: Path) -> CoverResult:
    """Manual override: copy a local image file into the cover cache."""
    dest = cover_path_for(ost_id)
    try:
        saved, accent_hex = images.save_cover_from_file(Path(src_path), dest, COVER_STORE_SIZE)
        return CoverResult(path=saved, source=CoverSource.NONE, accent_hex=accent_hex)
    except (OSError, ValueError):
        return CoverResult(path=None, source=CoverSource.NONE)


# --- YouTube helpers (pure, unit-tested) -----------------------------------

_YT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


def youtube_video_id(url: Optional[str]) -> Optional[str]:
    """Extract an 11-char YouTube video id from any common URL form
    (watch?v=, youtu.be/, embed/, shorts/, music.youtube). None if not YouTube."""
    if not url:
        return None
    try:
        u = urlparse(url.strip())
    except ValueError:
        return None
    host = (u.hostname or "").lower()
    if "youtu.be" in host:
        candidate = u.path.lstrip("/").split("/")[0]
        return candidate if _YT_ID_RE.match(candidate) else None
    if "youtube" in host:
        if u.path == "/watch":
            vid = parse_qs(u.query).get("v", [None])[0]
            return vid if vid and _YT_ID_RE.match(vid) else None
        parts = u.path.split("/")
        if len(parts) >= 3 and parts[1] in ("embed", "v", "shorts"):
            return parts[2] if _YT_ID_RE.match(parts[2]) else None
    return None


def youtube_thumbnail(video_id: str) -> tuple[str, str]:
    """(full_image_url, thumb_url) for a video id. hqdefault always exists;
    default is the small grid thumbnail."""
    return (
        f"https://img.youtube.com/vi/{video_id}/hqdefault.jpg",
        f"https://img.youtube.com/vi/{video_id}/default.jpg",
    )


def _youtube_search_results(
    client: httpx.Client, query: str, limit: int
) -> list[tuple[str, str]]:
    """Best-effort scrape of YouTube search results as (video_id, title) pairs.
    Titles let us filter YouTube candidates by franchise. Fully guarded — any
    failure yields no candidates rather than raising."""
    if not query.strip():
        return []
    try:
        resp = client.get(
            _YOUTUBE_SEARCH,
            params={"search_query": query, "hl": "en", "gl": "US"},
            headers={
                "User-Agent": _BROWSER_UA,
                "Accept-Language": "en-US,en",
                # Bypass the EU cookie-consent interstitial, which otherwise
                # serves a page with no video data (a common "no results" cause).
                "Cookie": "CONSENT=YES+1; SOCS=CAI",
            },
            follow_redirects=True,
        )
        resp.raise_for_status()
        text = resp.text
    except (httpx.HTTPError, ValueError):
        return []

    results: list[tuple[str, str]] = []
    seen: set[str] = set()
    # Chunk on videoRenderer so each id is paired with the title beside it.
    for chunk in text.split('"videoRenderer"')[1:]:
        m_id = re.search(r'"videoId":"([A-Za-z0-9_-]{11})"', chunk)
        if not m_id:
            continue
        vid = m_id.group(1)
        if vid in seen:
            continue
        seen.add(vid)
        m_title = re.search(r'"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"', chunk)
        title = ""
        if m_title:
            try:
                title = json.loads('"' + m_title.group(1) + '"')
            except ValueError:
                title = ""
        results.append((vid, title))
        if len(results) >= limit:
            break

    # Fallback for YouTube's newer result renderers (no videoRenderer blocks):
    # grab bare video ids so YouTube still contributes thumbnails.
    if not results:
        for vid in re.findall(r'"videoId":"([A-Za-z0-9_-]{11})"', text):
            if vid not in seen:
                seen.add(vid)
                results.append((vid, ""))
            if len(results) >= limit:
                break
    return results


# --- franchise relevance (pure, unit-tested) -------------------------------

_STOPWORDS = {
    "the", "of", "a", "an", "and", "to", "in", "on", "ost", "soundtrack",
    "original", "music", "theme", "themes", "from", "feat", "ft", "vol",
    "volume", "song", "track", "full", "hd", "official", "audio", "video",
}


def _tokens(text: str) -> list[str]:
    words = re.split(r"[^a-z0-9]+", (text or "").lower())
    return [w for w in words if w and w not in _STOPWORDS and len(w) > 1]


def candidate_relevance(candidate_text: str, title: str, source: Optional[str]) -> float:
    """Score how well a candidate matches the OST's title + franchise. Franchise
    token matches are weighted more heavily than title matches, plus a bonus for
    the full franchise phrase appearing verbatim."""
    text_tokens = set(_tokens(candidate_text))
    if not text_tokens:
        return 0.0
    score = 0.0
    for t in _tokens(title):
        if t in text_tokens:
            score += 1.0
    franchise_tokens = _tokens(source or "")
    for t in franchise_tokens:
        if t in text_tokens:
            score += 2.0
    if source and source.strip():
        norm_source = re.sub(r"[^a-z0-9]+", " ", source.lower()).strip()
        norm_text = re.sub(r"[^a-z0-9]+", " ", candidate_text.lower())
        if norm_source and norm_source in norm_text:
            score += 3.0
    return score


def is_franchise_relevant(candidate_text: str, title: str, source: Optional[str]) -> bool:
    """True if a candidate should survive the franchise filter. With no franchise
    given, nothing is filtered. Otherwise the candidate must mention at least one
    franchise token (e.g. an OST tagged "Yakuza" keeps only Yakuza-related art)."""
    franchise_tokens = _tokens(source or "")
    if not franchise_tokens:
        return True
    text_tokens = set(_tokens(candidate_text))
    return any(t in text_tokens for t in franchise_tokens)


# --- multi-source candidate search (cover picker) --------------------------

def _itunes_candidates(
    client: httpx.Client, term: str, entity: str, limit: int
) -> list[CoverCandidate]:
    if not term.strip():
        return []
    source_name = "iTunes album" if entity == "album" else "iTunes"
    try:
        resp = client.get(
            _ITUNES_ENDPOINT, params={"term": term, "entity": entity, "limit": limit}
        )
        resp.raise_for_status()
        results = resp.json().get("results") or []
    except (httpx.HTTPError, ValueError):
        return []

    out: list[CoverCandidate] = []
    for item in results:
        art = item.get("artworkUrl100") or item.get("artworkUrl60")
        if not art:
            continue
        name = item.get("trackName") or item.get("collectionName") or "Unknown"
        artist = item.get("artistName") or ""
        label = f"{name} — {artist}".strip(" —")
        out.append(
            CoverCandidate(
                image_url=upsize_itunes_url(art),
                thumb_url=art,
                label=label,
                source_name=source_name,
            )
        )
    return out


def _musicbrainz_candidates(
    client: httpx.Client, term: str, limit: int
) -> list[CoverCandidate]:
    if not term.strip():
        return []
    try:
        resp = client.get(
            _MUSICBRAINZ_ENDPOINT,
            params={"query": term, "fmt": "json", "limit": limit},
            headers={"User-Agent": _USER_AGENT},
        )
        resp.raise_for_status()
        releases = resp.json().get("releases") or []
    except (httpx.HTTPError, ValueError):
        return []

    out: list[CoverCandidate] = []
    for rel in releases:
        mbid = rel.get("id")
        if not mbid:
            continue
        out.append(
            CoverCandidate(
                image_url=_CAA_TEMPLATE.format(mbid=mbid),
                thumb_url=_CAA_THUMB_TEMPLATE.format(mbid=mbid),
                label=rel.get("title") or "MusicBrainz release",
                source_name="MusicBrainz",
            )
        )
    return out


def _bing_candidates(
    client: httpx.Client, query: str, api_key: str, limit: int
) -> list[CoverCandidate]:
    """Bing Image Search — the "broad web results" tier. Only reached when a key
    is configured (see config.get_bing_api_key). Covers the case iTunes and
    MusicBrainz both miss without resorting to Pinterest's non-public endpoints.
    Fully guarded like every other source."""
    if not query.strip() or not api_key:
        return []
    try:
        resp = client.get(
            _BING_ENDPOINT,
            params={"q": query, "count": limit, "imageType": "Photo", "safeSearch": "Moderate"},
            headers={"Ocp-Apim-Subscription-Key": api_key},
        )
        resp.raise_for_status()
        items = resp.json().get("value") or []
    except (httpx.HTTPError, ValueError):
        return []

    out: list[CoverCandidate] = []
    for item in items:
        img = item.get("contentUrl")
        if not img:
            continue
        out.append(
            CoverCandidate(
                image_url=img,
                thumb_url=item.get("thumbnailUrl") or img,
                label=item.get("name") or "Bing image",
                source_name="Bing",
            )
        )
    return out


def search_candidates(
    title: str,
    source: Optional[str] = None,
    external_link: Optional[str] = None,
    client: Optional[httpx.Client] = None,
    per_source: int = 5,
    bing_api_key: Optional[str] = None,
) -> list[CoverCandidate]:
    """Gather cover candidates from every source at once for the picker:
    iTunes songs, iTunes albums, MusicBrainz/Cover Art Archive, Bing Image
    Search (only if a key is configured), the OST's own YouTube link (if any),
    and a YouTube search. Deduplicated by image URL.

    Every source is independently guarded, so one being down or slow never
    blocks the others from returning options.
    """
    title = (title or "").strip()
    source = (source or "").strip()
    if bing_api_key is None:
        bing_api_key = get_bing_api_key()
    owns_client = client is None
    if client is None:
        client = httpx.Client(timeout=_TIMEOUT, headers={"User-Agent": _USER_AGENT})
    try:
        candidates: list[CoverCandidate] = []

        # The OST's own YouTube link is the single most trustworthy source —
        # the user picked that exact video — so surface it first and exempt it
        # from the franchise filter (source_name "Your link" is special-cased).
        link_id = youtube_video_id(external_link)
        if link_id:
            img, thumb = youtube_thumbnail(link_id)
            candidates.append(
                CoverCandidate(img, thumb, "This OST's YouTube link", "Your link")
            )

        combined = f"{title} {source}".strip()
        candidates += _itunes_candidates(client, title, "song", per_source)
        if source:
            candidates += _itunes_candidates(client, combined, "song", per_source)
        candidates += _itunes_candidates(client, combined or title, "album", per_source)
        candidates += _musicbrainz_candidates(client, combined or title, per_source)
        if bing_api_key:
            candidates += _bing_candidates(client, combined or title, bing_api_key, per_source)

        yt_query = f"{combined or title} soundtrack"
        for i, (vid, vtitle) in enumerate(_youtube_search_results(client, yt_query, per_source)):
            img, thumb = youtube_thumbnail(vid)
            candidates.append(
                CoverCandidate(img, thumb, vtitle or f"YouTube result {i + 1}", "YouTube")
            )

        # Dedupe by image URL, preserving order (first/most-trusted wins).
        seen: set[str] = set()
        deduped: list[CoverCandidate] = []
        for c in candidates:
            if c.image_url in seen:
                continue
            seen.add(c.image_url)
            deduped.append(c)
        return deduped
    finally:
        if owns_client:
            client.close()
