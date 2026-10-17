"""Idle attract overlay for the Linux client — mirror of the macOS
AttractOverlay: while the UI sits idle the roster area shows dark cover
slides on a 10s cycle (pinned to the now-playing OST while one is playing).
Any input on the window wakes it; app.py forwards the window's input events
here. Lifecycle timers run on the GTK main loop."""
from __future__ import annotations

from gi.repository import GLib, Gtk  # noqa: E402

SLIDE_SECONDS = 10
IDLE_SECONDS = 90


class AttractOverlay(Gtk.Overlay):
    def __init__(self, app, content: Gtk.Widget) -> None:
        super().__init__()
        self.app = app
        self.set_child(content)

        self._index = 0
        self._visible = False
        self._entries: list = []
        self._revealed = True
        self._picture = Gtk.Picture()
        self._title = Gtk.Label(label="", xalign=0.0, wrap=True)
        self._title.add_css_class("title-1")
        self._hint = Gtk.Label(label="Move the mouse to continue", xalign=0.0)
        self._hint.add_css_class("dim-label")
        slide = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        slide.append(self._picture)
        slide.append(self._title)
        slide.append(self._hint)
        slide.add_css_class("card")
        self.add_overlay(slide)
        self._slide = slide

        slide.set_opacity(0.92)
        slide.set_margin_top(48)
        slide.set_margin_bottom(48)
        slide.set_margin_start(48)
        slide.set_margin_end(48)

        GLib.timeout_add_seconds(SLIDE_SECONDS, self._advance)
        GLib.timeout_add_seconds(IDLE_SECONDS, self._pop)

    def wake(self, *_args) -> None:
        if not self._visible:
            return
        self._visible = False
        self._slide.hide()

    def _fresh_entries(self) -> list:
        try:
            self._entries = self.app.client.get_leaderboard()
            self._revealed = self.app.client.get_reveal()
        except Exception:
            pass
        return self._entries

    def _pop(self) -> bool:
        if self._visible or self.app.playing:
            return True  # retry at the next idle tick
        entries = self._fresh_entries()
        if not entries:
            return True
        entry = next((e for e in entries if e.ost.id == self.app.current_ost), None)
        if entry is None:
            entry = entries[self._index % len(entries)]
        self._apply_slide(entry)
        self._visible = True
        self._slide.show()
        return True

    def _advance(self) -> bool:
        if self._visible and not self.app.current_ost:
            self._index += 1
            if self._entries:
                self._apply_slide(self._entries[self._index % len(self._entries)])
        return True

    def _apply_slide(self, entry) -> None:
        from . import covers

        self._picture.set_pixbuf(covers.load(entry.ost.cover_image_path, size=480))
        rank = f"  #{entry.rank}" if (self._revealed and entry.rank is not None) else ""
        self._title.set_text(f"{entry.ost.title}{rank}")
