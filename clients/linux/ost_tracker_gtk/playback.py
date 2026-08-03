"""GStreamer playbin audio sink (the AVPlayer counterpart on Linux)."""
from __future__ import annotations

import webbrowser

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402


class Playback:
    def __init__(self) -> None:
        Gst.init(None)
        self._bin = None

    def play(self, stream_url: str, watch_url: str | None = None) -> None:
        self.stop()
        self._bin = Gst.ElementFactory.make("playbin")
        if self._bin is None:
            raise RuntimeError("gstreamer playbin unavailable")
        self._bin.set_property("uri", stream_url)
        self._bin.set_state(Gst.State.PLAYING)
        # Fallback when the stream won't play (yt-dlp missed): browser.
        if watch_url:
            GLibTimeout().later(8.0, lambda: self._fallback(watch_url))

    def _fallback(self, watch_url: str) -> None:
        if self._bin is not None and self._bin.get_state(0)[1] != Gst.State.PLAYING:
            webbrowser.open(watch_url)

    def pause(self) -> None:
        if self._bin is not None:
            self._bin.set_state(Gst.State.PAUSED)

    def resume(self) -> None:
        if self._bin is not None:
            self._bin.set_state(Gst.State.PLAYING)

    def stop(self) -> None:
        if self._bin is not None:
            self._bin.set_state(Gst.State.NULL)
            self._bin = None


class GLibTimeout:
    """Minimal GLib.timeout_add helper kept separate from the Gst import."""

    @staticmethod
    def later(seconds: float, callback) -> None:
        from gi.repository import GLib

        GLib.timeout_add(int(seconds * 1000), callback)
