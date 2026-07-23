"""In-app OST playback: one shared player, resolved off the UI thread.

``PlaybackController`` owns a single ``QMediaPlayer`` (created lazily, so the
audio backend never loads unless playback is actually used) and one in-flight
resolve at a time. Resolution runs the multi-source pipeline in
``services.link_resolver`` (direct yt-dlp on a YouTube link → parallel
YouTube/Spotify/Bing search → extraction) — network work, so it runs on the
global QThreadPool exactly like the cover fetch, with the result marshalled
back to the main thread via a queued signal. The winning watch URL is cached
per-OST in the database so the same track never re-searches; the transport's
re-search action clears that cache when a link goes stale.

Failure never surfaces as an error state: if nothing can be resolved, the best
candidate link opens in the default browser and the transport returns to
"stopped".

``TransportBar`` is the one widget all hosts (detail view, Quick Rate header)
embed: play/pause icon, seek slider, mono time readout, re-search button. It
only reacts to controller signals for its own OST, so multiple bars can exist
at once. It shows even without an ``external_link`` — the pipeline can find a
stream from the title alone.
"""

from __future__ import annotations

import time
from typing import Optional

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QHBoxLayout, QLabel, QSlider, QToolButton, QWidget

from ost_tracker.db import ost_repo
from ost_tracker.services.link_resolver import Resolution, resolve_playback
from ost_tracker.services.playback import format_time
from ost_tracker.ui import icons, theme

# Resolved stream URLs go stale (YouTube signs them with an expiry), so cached
# entries are only trusted briefly. The *watch page* cache is persistent (DB).
_STREAM_CACHE_TTL_S = 30 * 60

STATE_STOPPED = "stopped"
STATE_LOADING = "loading"
STATE_PLAYING = "playing"
STATE_PAUSED = "paused"


class _ResolveSignals(QObject):
    finished = Signal(int, object)  # ost_id, Resolution


class _ResolveTask(QRunnable):
    def __init__(
        self,
        ost_id: int,
        title: str,
        source: Optional[str],
        link: Optional[str],
        cached_watch_url: Optional[str],
    ) -> None:
        super().__init__()
        self._ost_id = ost_id
        self._title = title
        self._source = source
        self._link = link
        self._cached_watch_url = cached_watch_url
        self.signals = _ResolveSignals()

    def run(self) -> None:  # worker thread
        resolution = resolve_playback(
            self._title, self._source, self._link, self._cached_watch_url
        )
        self.signals.finished.emit(self._ost_id, resolution)


class PlaybackController(QObject):
    state_changed = Signal(int, str)          # ost_id, STATE_*
    position_changed = Signal(int, int, int)  # ost_id, position ms, duration ms

    def __init__(self) -> None:
        super().__init__()
        self._player = None            # created lazily on first successful resolve
        self._audio_out = None
        self._current_ost: Optional[int] = None
        self._current_link: Optional[str] = None
        self._resolving_ost: Optional[int] = None
        self._fell_back = False
        # In-memory stream cache: ost_id -> (stream url, monotonic timestamp).
        self._cache: dict[int, tuple[str, float]] = {}
        # Injectable for tests; production is "open the default browser".
        self._open_externally = lambda link: QDesktopServices.openUrl(QUrl(link))

    # --- public API -----------------------------------------------------

    def toggle(
        self,
        ost_id: int,
        link: Optional[str],
        title: str = "",
        source: Optional[str] = None,
    ) -> None:
        """The play/pause gesture for one OST's transport."""
        if not link and not title:
            return  # nothing to extract from and nothing to search with
        if ost_id == self._current_ost and self._player is not None:
            from PySide6.QtMultimedia import QMediaPlayer

            if self._player.playbackState() == QMediaPlayer.PlayingState:
                self._player.pause()
            else:
                self._player.play()
            return
        if ost_id == self._resolving_ost:
            return  # already resolving this track; ignore the double-click
        self._start(ost_id, link, title, source)

    def research(
        self,
        ost_id: int,
        link: Optional[str],
        title: str = "",
        source: Optional[str] = None,
    ) -> None:
        """Manual re-search: drop every cached resolution for this OST (the
        persistent watch URL and the in-memory stream) and resolve fresh."""
        ost_repo.set_playback_watch_url(ost_id, None)
        self._cache.pop(ost_id, None)
        if ost_id == self._current_ost and self._player is not None:
            self._player.stop()
            self._current_ost = None
        self._start(ost_id, link, title, source)

    def seek(self, ost_id: int, position_ms: int) -> None:
        if ost_id == self._current_ost and self._player is not None:
            self._player.setPosition(position_ms)

    def stop(self) -> None:
        if self._player is not None:
            self._player.stop()

    # --- resolve --------------------------------------------------------

    def _start(self, ost_id: int, link: Optional[str], title: str, source: Optional[str]) -> None:
        self.stop()
        cached = self._cache.get(ost_id)
        if cached and time.monotonic() - cached[1] < _STREAM_CACHE_TTL_S:
            self._play_stream(ost_id, cached[0])
            return
        self._resolving_ost = ost_id
        self.state_changed.emit(ost_id, STATE_LOADING)
        task = _ResolveTask(
            ost_id, title, source, link, ost_repo.get_playback_watch_url(ost_id)
        )
        task.signals.finished.connect(self._on_resolved)
        QThreadPool.globalInstance().start(task)

    def _on_resolved(self, ost_id: int, resolution: Resolution) -> None:
        # Main thread (queued signal). A stale resolve (user moved on) is dropped.
        if ost_id != self._resolving_ost:
            return
        self._resolving_ost = None
        if resolution.stream_url is None:
            # Graceful degradation: no error state, just the browser (when the
            # pipeline found anything worth opening at all).
            if resolution.fallback_link:
                self._open_externally(resolution.fallback_link)
            self.state_changed.emit(ost_id, STATE_STOPPED)
            return
        if resolution.watch_url:
            ost_repo.set_playback_watch_url(ost_id, resolution.watch_url)
        self._cache[ost_id] = (resolution.stream_url, time.monotonic())
        self._play_stream(ost_id, resolution.stream_url, resolution.watch_url)

    # --- player ----------------------------------------------------------

    def _ensure_player(self) -> None:
        if self._player is not None:
            return
        from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer

        self._player = QMediaPlayer(self)
        self._audio_out = QAudioOutput(self)
        self._player.setAudioOutput(self._audio_out)
        self._player.playbackStateChanged.connect(self._on_playback_state)
        self._player.positionChanged.connect(self._on_position)
        self._player.durationChanged.connect(lambda _=0: self._on_position(self._player.position()))
        self._player.errorOccurred.connect(self._on_player_error)

    def _play_stream(self, ost_id: int, url: str, watch_url: Optional[str] = None) -> None:
        self._ensure_player()
        self._current_ost = ost_id
        self._current_link = watch_url
        self._fell_back = False
        self._player.setSource(QUrl(url))
        self._player.play()

    def _on_playback_state(self, state) -> None:
        if self._current_ost is None:
            return
        from PySide6.QtMultimedia import QMediaPlayer

        mapping = {
            QMediaPlayer.PlayingState: STATE_PLAYING,
            QMediaPlayer.PausedState: STATE_PAUSED,
            QMediaPlayer.StoppedState: STATE_STOPPED,
        }
        self.state_changed.emit(self._current_ost, mapping.get(state, STATE_STOPPED))

    def _on_position(self, position_ms: int) -> None:
        if self._current_ost is not None and self._player is not None:
            self.position_changed.emit(
                self._current_ost, position_ms, self._player.duration()
            )

    def _on_player_error(self, *_args) -> None:
        # A resolved stream that then fails (expired URL, 403, codec) degrades
        # the same way a failed resolve does: browser, once, then stopped.
        if self._current_ost is None or self._fell_back:
            return
        self._fell_back = True
        ost_id, link = self._current_ost, self._current_link
        self._player.stop()
        self._current_ost = None
        self._cache.pop(ost_id, None)  # don't trust that stream again
        if link:
            self._open_externally(link)
        self.state_changed.emit(ost_id, STATE_STOPPED)


_controller: Optional[PlaybackController] = None


def playback_controller() -> PlaybackController:
    global _controller
    if _controller is None:
        _controller = PlaybackController()
    return _controller


class TransportBar(QWidget):
    """Compact play/pause + seek + time readout + re-search for one OST.
    Always shown: even without an external link the resolution pipeline can
    search a stream up from the OST's title."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost_id: Optional[int] = None
        self._link: Optional[str] = None
        self._title = ""
        self._source: Optional[str] = None
        self._duration_ms = 0
        self._scrubbing = False

        row = QHBoxLayout(self)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(8)

        self.play_button = QToolButton()
        self.play_button.setIcon(icons.icon("fa5s.play"))
        self.play_button.setCursor(Qt.PointingHandCursor)
        self.play_button.setToolTip("Play in app (falls back to the browser)")
        self.play_button.clicked.connect(self._toggle)
        row.addWidget(self.play_button)

        self.slider = QSlider(Qt.Horizontal)
        self.slider.setRange(0, 0)
        self.slider.sliderPressed.connect(lambda: setattr(self, "_scrubbing", True))
        self.slider.sliderReleased.connect(self._on_scrub_done)
        row.addWidget(self.slider, 1)

        self.time_label = QLabel("0:00 / 0:00")
        self.time_label.setFont(theme.mono_font(9))
        self.time_label.setStyleSheet(f"color:{theme.TEXT_DIM};")
        row.addWidget(self.time_label)

        self.research_button = QToolButton()
        self.research_button.setIcon(icons.refresh())
        self.research_button.setCursor(Qt.PointingHandCursor)
        self.research_button.setToolTip(
            "Re-search the playback link (use when a cached link has gone stale)"
        )
        self.research_button.setStyleSheet(
            "QToolButton { border: none; background: transparent; padding: 2px; }"
        )
        self.research_button.clicked.connect(self._research)
        row.addWidget(self.research_button)

        controller = playback_controller()
        controller.state_changed.connect(self._on_state)
        controller.position_changed.connect(self._on_position)

    def set_ost(
        self,
        ost_or_id,
        external_link: Optional[str] = None,
        title: str = "",
        source: Optional[str] = None,
    ) -> None:
        """Point the bar at one OST. Accepts the Ost record itself (preferred)
        or the explicit (ost_id, external_link, title, source) pieces."""
        if hasattr(ost_or_id, "id"):
            ost = ost_or_id
            ost_id, external_link = ost.id, ost.external_link
            title, source = ost.title, ost.source
        else:
            ost_id = ost_or_id
        if ost_id == self._ost_id and external_link == self._link:
            return  # same track re-shown (host rebuild) — keep live state
        self._ost_id = ost_id
        self._link = external_link
        self._title = title or ""
        self._source = source
        self._show_state(STATE_STOPPED)
        self.slider.setValue(0)
        self.time_label.setText("0:00 / 0:00")

    # --- interaction ------------------------------------------------------

    def _toggle(self) -> None:
        if self._ost_id is not None:
            playback_controller().toggle(self._ost_id, self._link, self._title, self._source)

    def _research(self) -> None:
        if self._ost_id is not None:
            playback_controller().research(self._ost_id, self._link, self._title, self._source)

    def _on_scrub_done(self) -> None:
        self._scrubbing = False
        if self._ost_id is not None:
            playback_controller().seek(self._ost_id, self.slider.value())

    # --- controller feedback ------------------------------------------------

    def _on_state(self, ost_id: int, state: str) -> None:
        if ost_id == self._ost_id:
            self._show_state(state)

    def _show_state(self, state: str) -> None:
        icon_name = {
            STATE_PLAYING: "fa5s.pause",
            STATE_LOADING: "fa5s.hourglass-half",
        }.get(state, "fa5s.play")
        self.play_button.setIcon(icons.icon(icon_name))
        self.play_button.setEnabled(state != STATE_LOADING)
        self.research_button.setEnabled(state != STATE_LOADING)

    def _on_position(self, ost_id: int, position_ms: int, duration_ms: int) -> None:
        if ost_id != self._ost_id:
            return
        self._duration_ms = max(0, duration_ms)
        self.slider.setRange(0, self._duration_ms)
        if not self._scrubbing:
            self.slider.setValue(position_ms)
        self.time_label.setText(f"{format_time(position_ms)} / {format_time(self._duration_ms)}")
