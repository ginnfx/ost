"""Resolve an OST's ``external_link`` to a directly-playable audio stream URL.

``yt-dlp`` does the heavy lifting: given a YouTube (or other supported) page
URL it returns the underlying media stream URL, which ``QMediaPlayer`` can play
natively — real in-app transport instead of bouncing to a browser. The Python
module is preferred; the standalone ``yt-dlp`` binary on PATH is the fallback,
so playback works with either install style.

Every failure path returns ``None``: unsupported link, yt-dlp not installed,
network down, or YouTube having changed their site again. Callers treat None
as "open the link in the browser instead" — never an error state.

Maintenance note: yt-dlp extraction is fragile by nature — YouTube changes break it
until yt-dlp ships a fix. If in-app playback stops working, update it
(``pip install -U yt-dlp``) before debugging anything here.
"""

from __future__ import annotations

import shutil
import subprocess
from typing import Optional

_RESOLVE_TIMEOUT_S = 25
# Prefer AAC/m4a: AVFoundation (SwiftUI frontend) cannot decode webm/opus,
# which plain "bestaudio" usually selects. QMediaPlayer plays m4a equally well.
_YTDLP_FORMAT = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio/best"
# YouTube bot-checks the default web client ("Sign in to confirm you're not a
# bot") while other innertube clients still extract fine. Try default first so
# nothing changes when YouTube isn't blocking, then fall back to android (which
# verified working against the block on 2026-07-19), then tv.
_YTDLP_PLAYER_CLIENTS = ["default", "android", "tv"]


def _resolve_via_module(link: str) -> Optional[str]:
    try:
        import yt_dlp
    except ImportError:
        return None
    opts = {
        "format": _YTDLP_FORMAT,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "socket_timeout": _RESOLVE_TIMEOUT_S,
        "extractor_args": {"youtube": {"player_client": _YTDLP_PLAYER_CLIENTS}},
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(link, download=False)
    if info and info.get("entries"):  # playlist page — take the first entry
        info = next((e for e in info["entries"] if e), None)
    url = (info or {}).get("url")
    return url or None


def _resolve_via_cli(link: str) -> Optional[str]:
    binary = shutil.which("yt-dlp")
    if not binary:
        return None
    result = subprocess.run(
        [
            binary, "-f", _YTDLP_FORMAT, "--no-playlist",
            "--extractor-args", f"youtube:player_client={','.join(_YTDLP_PLAYER_CLIENTS)}",
            "-g", link,
        ],
        capture_output=True,
        text=True,
        timeout=_RESOLVE_TIMEOUT_S,
    )
    if result.returncode != 0:
        return None
    first_line = result.stdout.strip().splitlines()
    return first_line[0] if first_line else None


def resolve_stream_url(link: Optional[str]) -> Optional[str]:
    """A playable stream URL for ``link``, or None when it can't be resolved
    (caller falls back to opening the link in the browser)."""
    if not link or not link.strip():
        return None
    link = link.strip()
    for resolver in (_resolve_via_module, _resolve_via_cli):
        try:
            url = resolver(link)
        except Exception:  # yt-dlp raises many library-specific types; all mean "miss"
            url = None
        if url:
            return url
    return None


def format_time(ms: int) -> str:
    """``m:ss`` readout for the transport bar. Negative/unknown reads 0:00."""
    total_seconds = max(0, int(ms) // 1000)
    return f"{total_seconds // 60}:{total_seconds % 60:02d}"
