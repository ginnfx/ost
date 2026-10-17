"""Perfect-score celebration overlay — GTK port of the macOS ParticleBurst:
26 accent dots launch outward from one point and fade over ~1.8 s. Purely
decorative and non-interactive; the app shows it above the page stack."""
from __future__ import annotations

import math
import random
import time

import gi

gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Graphene, GLib, Gtk  # noqa: E402

from . import theme

DOTS = 26
LIFE = 1.8  # seconds, matches Swift ParticleBurst


class ParticleBurst(Gtk.DrawingArea):
    def __init__(self, app) -> None:
        super().__init__()
        self.app = app
        self._started: float | None = None
        self._cx = 0.0
        self._cy = 0.0
        self._tick_id: int | None = None
        self.set_visible(False)
        self.set_can_target(False)  # non-interactive, like .allowsHitTesting(false)

    def fire(self) -> None:
        """Start the burst from this overlay's center."""
        self._cx = self.get_allocated_width() / 2
        self._cy = self.get_allocated_height() / 2
        self._started = time.monotonic()
        self.set_visible(True)
        if self._tick_id is None:
            self._tick_id = GLib.timeout_add(16, self._tick)

    def _tick(self) -> bool:
        assert self._started is not None
        if time.monotonic() - self._started >= LIFE:
            self.set_visible(False)
            self._started = None
            self._tick_id = None
            return False  # stop repeating
        self.queue_draw()
        return True  # keep repeating

    def do_snapshot(self, snapshot: Gtk.Snapshot) -> None:  # noqa: N802 — GTK virtual
        if self._started is None:
            return Gtk.DrawingArea.do_snapshot(self, snapshot)
        if not hasattr(snapshot, "append_fill"):
            # GTK < 4.8 lacks fill primitives — draw nothing rather than crash.
            return Gtk.DrawingArea.do_snapshot(self, snapshot)
        accent = theme.accent()
        red = int(accent[1:3], 16) / 255
        green = int(accent[3:5], 16) / 255
        blue = int(accent[5:7], 16) / 255
        t = (time.monotonic() - self._started) / LIFE
        for index in range(DOTS):
            angle = math.pi * 2 * index / DOTS + random.Random(index).random() * 0.4
            speed = 120 + random.Random(index + 1).random() * 130
            distance = speed * (time.monotonic() - self._started)
            x = self._cx + math.cos(angle) * distance
            y = self._cy + math.sin(angle) * distance
            alpha = max(0.0, 0.9 * (1 - t))
            rect = Graphene.Rect()
            rect.init(x - 2, y - 2, 5, 5)
            color = Gdk.RGBA(red, green, blue, alpha)
            snapshot.append_fill(rect, color)
        Gtk.DrawingArea.do_snapshot(self, snapshot)
