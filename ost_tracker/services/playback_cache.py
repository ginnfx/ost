"""Small persistent cache for OST audio already played in the app."""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

from ost_tracker import config
from ost_tracker.db.models import Ost

logger = logging.getLogger("ost_tracker.playback")

_MAX_CACHE_BYTES = 1_000_000_000
_MAX_TRACK_BYTES = 250_000_000
_jobs_lock = threading.Lock()
_jobs: set[str] = set()


def _cache_dir() -> Path:
    path = config.app_support_dir() / "playback-cache"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _cache_key(ost: Ost) -> str:
    identity = "\0".join((
        str(ost.id), ost.title.strip(), (ost.source or "").strip(),
        (ost.external_link or "").strip(),
    ))
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def cached_audio_url(ost: Ost) -> Optional[str]:
    try:
        path = _cache_dir() / f"{_cache_key(ost)}.m4a"
        if not path.is_file() or path.stat().st_size == 0:
            return None
        os.utime(path, None)  # LRU timestamp
        return path.as_uri()
    except OSError:
        return None


def cache_audio(ost: Ost, watch_url: Optional[str]) -> None:
    """Download a played track after playback has started; never blocks play."""
    if not watch_url:
        return
    key = _cache_key(ost)
    target = _cache_dir() / f"{key}.m4a"
    if target.is_file() and target.stat().st_size > 0:
        return
    with _jobs_lock:
        if key in _jobs:
            return
        _jobs.add(key)
    try:
        # Give AVPlayer time to establish the live stream before a second
        # request for the same media competes for bandwidth.
        time.sleep(8)
        _download(ost, watch_url, key)
    finally:
        with _jobs_lock:
            _jobs.discard(key)


def _download(ost: Ost, watch_url: str, key: str) -> None:
    target = _cache_dir() / f"{key}.m4a"
    if target.is_file() and target.stat().st_size > 0:
        return

    try:
        import yt_dlp

        with tempfile.TemporaryDirectory(prefix="ost-audio-", dir=_cache_dir()) as temp:
            def check_size(data: dict) -> None:
                total = data.get("total_bytes") or data.get("total_bytes_estimate") or 0
                downloaded = data.get("downloaded_bytes") or 0
                if max(total, downloaded) > _MAX_TRACK_BYTES:
                    raise yt_dlp.utils.DownloadError("OST exceeds the local cache limit")

            options = {
                "format": "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]",
                "outtmpl": str(Path(temp) / "track.%(ext)s"),
                "quiet": True,
                "no_warnings": True,
                "noplaylist": True,
                "socket_timeout": 20,
                "extractor_args": {"youtube": {"player_client": ["default", "android", "tv"]}},
                "progress_hooks": [check_size],
                "max_filesize": _MAX_TRACK_BYTES,
            }
            with yt_dlp.YoutubeDL(options) as ydl:
                ydl.extract_info(watch_url, download=True)
            downloaded = next(Path(temp).glob("*.m4a"), None)
            if downloaded is None or downloaded.stat().st_size == 0:
                logger.info("audio cache skipped for OST %s: no playable m4a", ost.id)
                return
            os.replace(downloaded, target)
        _prune_cache(keep=target)
        logger.info("cached audio for OST %s (%s)", ost.id, _format_size(target.stat().st_size))
    except Exception as exc:
        logger.info("audio cache failed for OST %s: %s", ost.id, exc)


def _prune_cache(keep: Path) -> None:
    files = sorted(
        (p for p in _cache_dir().glob("*.m4a") if p.is_file() and p != keep),
        key=lambda p: p.stat().st_mtime,
    )
    total = keep.stat().st_size
    sizes = {path: path.stat().st_size for path in files}
    total += sum(sizes.values())
    for path in files:
        if total <= _MAX_CACHE_BYTES:
            break
        try:
            path.unlink()
            total -= sizes[path]
        except OSError:
            pass


def _format_size(size: int) -> str:
    return f"{size / (1024 * 1024):.1f} MB"
