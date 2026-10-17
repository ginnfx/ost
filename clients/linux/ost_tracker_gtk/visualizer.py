"""Centered spectrum ribbon for the bottom bar — GTK port of the macOS
SpectrumView ribbon (bars up/down, peak line, reflection). Measured bands come
from playback.bands(); without a measurement (no spectrum element, or paused)
it falls back to the same ambient silhouette the macOS app draws."""
from __future__ import annotations

import math

from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from . import theme


def _ambient(now: float, unit: float) -> float:
    """Matches SpectrumView's ambient fallback wave."""
    return 0.11 + 0.10 * (math.sin(now * 3.1 + unit * 13) * math.sin(now * 1.7 - unit * 21) + 1) / 2


def _silhouette(unit: float) -> float:
    return 0.035 + 0.045 * max(0.0, math.sin(math.pi * unit)) ** 0.7


def _edge(unit: float) -> float:
    return 0.22 + 0.78 * max(0.0, math.sin(math.pi * unit)) ** 0.42


class VisualizerWidget(Gtk.DrawingArea):
    def __init__(self, app, width: int = 160, height: int = 28) -> None:
        super().__init__()
        self.app = app
        self.set_size_request(width, height)
        self.set_draw_func(self._draw)
        GLib.timeout_add(33, self._tick)

    def _tick(self) -> bool:
        self.queue_draw()
        return True  # keep repeating

    def _levels(self, width: int) -> list[float]:
        playing = self.app.playing
        measured = self.app.playback.bands()
        import time
        now = time.monotonic()
        levels = []
        for index in range(width):
            unit = index / max(width - 1, 1)
            if measured and playing:
                band = unit * (len(measured) - 1)
                lower = int(band)
                blend = band - lower
                m = measured[lower] * (1 - blend) + measured[min(lower + 1, len(measured) - 1)] * blend
                value = max(0.006, m)
            elif playing:
                value = _ambient(now, unit)
            else:
                value = 0.0
            levels.append(max(_silhouette(unit), value ** 0.78 * _edge(unit)))
        return levels

    def _draw(self, area: Gtk.DrawingArea, cr, width: int, height: int) -> None:
        accent = theme.accent()
        accent_rgba = Gdk.RGBA()
        accent_rgba.parse(accent)
        dim = self.app.playing is not True

        mid_y = height / 2
        step = max(width / 48, 2.2)
        bar_width = max(1.6, step * 0.58)
        levels = self._levels(48)

        for index, level in enumerate(levels):
            height_px = max(2.0, min(height * 0.43, level * height * 0.59))
            x = (index + 0.5) * step
            alpha = (0.24 if not dim else 0.5 * 0.24) + level * 0.6
            cr.set_source_rgba(accent_rgba.red, accent_rgba.green, accent_rgba.blue, min(alpha, 0.95))
            cr.rectangle(x - bar_width / 2, mid_y - height_px, bar_width, height_px * 2)
            cr.fill()

        # center axis
        cr.set_source_rgba(accent_rgba.red, accent_rgba.green, accent_rgba.blue, 0.24)
        cr.set_line_width(0.7)
        cr.move_to(0, mid_y)
        cr.line_to(width, mid_y)
        cr.stroke()
