"""Detail window for one OST — mirrors the macOS DetailView (cover, info,
per-rater scores, playback, delete) plus the synced-lyrics takeover from the
macOS player: LRCLIB lookup cached on disk, current line full-bright and
scrolled to center on a 5Hz tick, tap a line to seek. Highlight follows the
local playbin position; seeking sets the canonical sidecar position too."""

from __future__ import annotations

import threading
import time
import webbrowser
import os
from pathlib import Path
from typing import Optional

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk  # noqa: E402

from . import covers, lyrics


class DetailWindow(Gtk.Window):
    def __init__(self, app, entry) -> None:
        super().__init__(title=entry.ost.title)
        self.app = app
        self.ost_id = entry.ost.id
        self.ost = entry.ost
        self.set_default_size(560, 520)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_top(14)
        box.set_margin_bottom(14)
        box.set_margin_start(14)
        box.set_margin_end(14)

        picture = Gtk.Picture.new_for_pixbuf(covers.load(entry.ost.cover_image_path, size=240))
        picture.set_size_request(240, 240)
        box.append(picture)

        title = Gtk.Label(label=entry.ost.title, xalign=0.0, wrap=True)
        title.add_css_class("title-1")
        box.append(title)

        info = Gtk.Label(
            label=f"{entry.ost.source or 'no source'} · by {entry.ost.submitter_name or '?'}\n"
                  f"{entry.ost.external_link or ''}",
            xalign=0.0, wrap=True,
        )
        info.add_css_class("dim-label")
        box.append(info)

        controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        for label, handler in (("Play", self._play), ("Stop", self._stop),
                               ("Lyrics", self._lyrics), ("Open link", self._link),
                               ("Delete", self._delete)):
            button = Gtk.Button(label=label)
            button.connect("clicked", handler)
            controls.append(button)
        box.append(controls)

        self._scores = Gtk.ListBox()
        self._scores.set_selection_mode(Gtk.SelectionMode.NONE)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_child(self._scores)
        self._scores_area = scrolled
        box.append(self._scores_area)

        self._lyrics_area = lyrics_area = Gtk.ScrolledWindow()
        lyrics_list = Gtk.ListBox()
        lyrics_list.set_selection_mode(Gtk.SelectionMode.NONE)
        self._lyrics_rows: list[Gtk.ListBoxRow] = []
        self._lyrics_list = lyrics_list
        self._lyrics_lines: Optional[list] = None
        self._lyrics_loaded = False
        self._lyrics_position_anchor = 0.0
        self._lyrics_position_updated = time.monotonic()
        lyrics_area.set_vexpand(True)
        lyrics_area.set_child(lyrics_list)
        lyrics_area.hide()
        box.append(lyrics_area)

        self.status = Gtk.Label(label="", xalign=0.0)
        self.status.add_css_class("dim-label")
        box.append(self.status)

        self.set_child(box)
        self._load()
        self._lyrics_tick_id = GLib.timeout_add(200, self._lyrics_tick)

    # --- core detail ----------------------------------------------------------------

    def _load(self) -> None:
        try:
            ratings = self.app.client.get_ratings()
            rows = sorted((r for r in ratings if r.ost_id == self.ost_id), key=lambda r: -r.score)
            for child in list(self._scores):
                self._scores.remove(child)
            for r in rows:
                row = Gtk.ListBoxRow()
                row.set_child(Gtk.Label(label=f"{r.rater_name}: {r.score:g}", xalign=0.0))
                self._scores.append(row)
            self.status.set_text(f"{len(rows)} scores")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _play(self, *_args) -> None:
        self.app.play_ost(self.ost_id)
        self._lyrics_position_updated = time.monotonic()

    def _stop(self, *_args) -> None:
        self.app.playback.stop()
        try:
            self.app.client.stop()
        except Exception:
            pass

    def _link(self, *_args) -> None:
        if self.ost.external_link:
            webbrowser.open(self.ost.external_link)

    def _delete(self, *_args) -> None:
        try:
            self.app.client.delete_ost(self.ost_id)
        except Exception as exc:
            self.status.set_text(str(exc))
            return
        self.close()

    # --- lyrics takeover ------------------------------------------------------------

    def _lyrics(self, *_args) -> None:
        if self._lyrics_loaded:
            showing = self._lyrics_area.get_visible()
            self._scores_area.set_visible(showing)
            self._lyrics_area.set_visible(not showing)
            if not showing:
                self._lyrics_position_updated = time.monotonic()
            return
        self._lyrics_loaded = True
        self._scores_area.set_visible(False)
        self._lyrics_area.set_visible(True)
        placeholder = Gtk.ListBoxRow()
        placeholder.set_child(Gtk.Label(label="Fetching lyrics…", xalign=0.0))
        placeholder.set_opacity(0.45)
        self._lyrics_list.append(placeholder)
        thread = threading.Thread(target=self._lyrics_worker, daemon=True)
        thread.start()

    def _lyrics_worker(self) -> None:
        try:
            result = lyrics.fetch(self.ost, cache_dir=self._lyrics_cache_dir())
        except Exception:
            result = None
        GLib.idle_add(self._lyrics_apply, result)

    @staticmethod
    def _lyrics_cache_dir():
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        return base / "ost-tracker" / "lyrics-cache"

    def _lyrics_apply(self, result) -> bool:
        for child in list(self._lyrics_list):
            self._lyrics_list.remove(child)
        self._lyrics_rows = []
        if result is None:
            self.status.set_text("No lyrics found.")
            self._lyrics_lines = None
            return False
        if result.synced:
            self._lyrics_lines = result.synced
            for index, line in enumerate(result.synced):
                row = Gtk.ListBoxRow()
                label = Gtk.Label(label=line.text, xalign=0.0, wrap=True)
                label.add_css_class("title-4")
                row.set_child(label)
                row.lyric_index = index
                row.time = line.time
                row.connect("activate", self._on_lyric_line)
                # ListBox rows respond to click activation like the tap-to-seek.
                self._lyrics_list.append(row)
                self._lyrics_rows.append(row)
            self._lyrics_list.connect("row-activated", self._on_row_activate)
        elif result.plain:
            self._lyrics_lines = None
            for paragraph in result.plain.splitlines():
                row = Gtk.ListBoxRow()
                row.set_child(Gtk.Label(label=paragraph or " ", xalign=0.0, wrap=True))
                self._lyrics_list.append(row)
        return False  # one-shot idle callback

    def _on_row_activate(self, _list, row) -> None:
        index = row.get_index()
        if self._lyrics_lines and 0 <= index < len(self._lyrics_lines):
            self._seek_to(self._lyrics_lines[index].time)

    def _on_lyric_line(self, row) -> None:  # kept for keyboard activation parity
        self._on_row_activate(self._lyrics_list, row)

    def _seek_to(self, seconds: float) -> None:
        try:
            self.app.client.seek(seconds)
        except Exception:
            pass
        self.app.playback.seek(seconds)
        self._lyrics_position_anchor = seconds
        self._lyrics_position_updated = time.monotonic()

    def _lyrics_tick(self) -> bool:
        if not self._lyrics_lines or not self._lyrics_area.get_visible():
            return True
        playing = self.app.playing
        position = self.app.playback.position()
        if playing and position is None:
            # Fallback: wall-clock extrapolation between sidecar ticks.
            position = self._lyrics_position_anchor + min(time.monotonic() - self._lyrics_position_updated, 5.0)
        if position is None:
            return True
        current = None
        for index, line in enumerate(self._lyrics_lines):
            if line.time <= position + 0.2:
                current = index
        for index, row in enumerate(self._lyrics_rows):
            if index == current:
                row.set_opacity(1.0)
                self._lyrics_list.select_row(row)
            elif current is not None and index < current:
                row.set_opacity(0.28)
            else:
                row.set_opacity(0.45)
        return True

    def do_close_request(self, *args):  # noqa: N802 — GTK virtual
        if getattr(self, "_lyrics_tick_id", None):
            GLib.source_remove(self._lyrics_tick_id)
            self._lyrics_tick_id = None
        return super().do_close_request(*args)
