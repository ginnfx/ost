"""GStreamer playbin audio sink (the AVPlayer counterpart on Linux).

When gst-plugins-good ships the ``spectrum`` element the sink chain reports
live log-spaced bands (poll via ``bands()``); without it the accessor returns
``None`` and the visualizer falls back to its ambient animation — the same
division the macOS app makes between measured and ambient motion.
"""
from __future__ import annotations

import threading

import webbrowser

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst  # noqa: E402

BAND_COUNT = 48


class Playback:
    def __init__(self) -> None:
        Gst.init(None)
        self._bin = None
        self._bands: list[float] | None = None
        self._bands_lock = threading.Lock()
        # Probe once: gst-plugins-good may ship without the spectrum element.
        self._spectrum_attached = self._probe_spectrum()

    # --- spectrum wiring ------------------------------------------------------------

    def _probe_spectrum(self) -> bool:
        return self._spectrum_element() is not None

    def _spectrum_element(self) -> Gst.Element | None:
        """None when gst-plugins-good is missing — callers must tolerate that."""
        return Gst.ElementFactory.make("spectrum")

    def _build_audio_sink(self) -> Gst.Element | None:
        """playbin audio chain with spectrum tapped mid-flight: convert →
        spectrum → autoaudiosink, exposed over a ghost sink pad. None ⇒
        playbin's default sink (no bands)."""
        if not self._spectrum_attached:
            return None
        convert = Gst.ElementFactory.make("audioconvert")
        output = Gst.ElementFactory.make("autoaudiosink")
        spectrum = self._spectrum_element()
        if convert is None or output is None or spectrum is None:
            self._spectrum_attached = False
            return None
        spectrum.set_property("bands", BAND_COUNT)
        # One magnitude message per 50ms of audio is plenty for smooth bars.
        spectrum.set_property("interval", 50_000_000)  # ns
        spectrum.set_property("multi-channel", False)
        chain = Gst.Bin()
        chain.add(convert)
        chain.add(spectrum)
        chain.add(output)
        if not convert.link(spectrum) or not spectrum.link(output):
            self._spectrum_attached = False
            return None
        sink_pad = Gst.GhostPad.new("sink", convert.get_static_pad("sink"))
        if not chain.add_pad(sink_pad):
            self._spectrum_attached = False
            return None
        return chain

    def _bands_message(self, spectrum_msg: Gst.Message) -> None:
        """Bus callback: magnitudes (dB, -120..0) → normalized 0..1 bands."""
        structure = spectrum_msg.get_structure()
        if structure.get_name() != "spectrum":
            return
        magnitudes = structure.get_value("magnitude")
        if not magnitudes or len(magnitudes) == 0:
            return
        # Log-scale resample down to the display band count.
        count = len(magnitudes)
        sampled = []
        for band in range(BAND_COUNT):
            index = min(count - 1, band * count // BAND_COUNT)
            db = magnitudes[index]
            level = 0.0 if db <= -60 else min(1.0, (db + 60) / 55)
            sampled.append(level)
        with self._bands_lock:
            self._bands = sampled

    # --- transport ------------------------------------------------------------------

    def play(self, stream_url: str, watch_url: str | None = None) -> None:
        self.stop()
        self._bin = Gst.ElementFactory.make("playbin")
        if self._bin is None:
            raise RuntimeError("gstreamer playbin unavailable")
        self._bin.set_property("uri", stream_url)
        chain = self._build_audio_sink()
        if chain is not None:
            self._bin.set_property("audio-sink", chain)
            self._bin.get_bus().add_signal_watch()
            self._bin.get_bus().connect("message::element", self._on_element_message)
        self._bin.set_state(Gst.State.PLAYING)
        # Fallback when the stream won't play (yt-dlp missed): browser.
        if watch_url:
            GLib.timeout_add(8000, lambda: self._fallback(watch_url))

    def _on_element_message(self, _bus, message: Gst.Message) -> None:
        if message.get_structure().get_name() == "spectrum":
            self._bands_message(message)

    def _fallback(self, watch_url: str) -> None:
        if self._bin is not None and self._bin.get_state(0)[1] != Gst.State.PLAYING:
            webbrowser.open(watch_url)

    def pause(self) -> None:
        if self._bin is not None:
            self._bin.set_state(Gst.State.PAUSED)

    def resume(self) -> None:
        if self._bin is not None:
            self._bin.set_state(Gst.State.PLAYING)

    def position(self) -> float | None:
        """Seconds into the stream (for the synced-lyrics highlight)."""
        if self._bin is None:
            return None
        ok, nanoseconds = self._bin.query_position(Gst.Format.TIME)
        return nanoseconds / Gst.SECOND if ok else None

    def seek(self, seconds: float) -> None:
        if self._bin is not None:
            self._bin.seek_simple(Gst.Format.TIME,
                                  Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT,
                                  int(seconds * Gst.SECOND))

    def bands(self) -> list[float] | None:
        """Latest spectrum snapshot, or None while no measurement exists."""
        with self._bands_lock:
            return None if self._bands is None else list(self._bands)

    def stop(self) -> None:
        if self._bin is not None:
            self._bin.set_state(Gst.State.NULL)
            self._bin = None
        with self._bands_lock:
            self._bands = None
