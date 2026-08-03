"""Detail window for one OST — mirrors the macOS DetailView (cover, info,
per-rater scores, playback, delete)."""

from __future__ import annotations

import webbrowser

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402

from . import covers


class DetailWindow(Gtk.Window):
    def __init__(self, app, entry) -> None:
        super().__init__(title=entry.ost.title)
        self.app = app
        self.ost_id = entry.ost.id
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
                               ("Open link", self._link), ("Delete", self._delete)):
            button = Gtk.Button(label=label)
            button.connect("clicked", handler)
            controls.append(button)
        box.append(controls)

        self._scores = Gtk.ListBox()
        self._scores.set_selection_mode(Gtk.SelectionMode.NONE)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_child(self._scores)
        box.append(scrolled)

        self.status = Gtk.Label(label="", xalign=0.0)
        self.status.add_css_class("dim-label")
        box.append(self.status)

        self.set_child(box)
        self._load()

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

    def _stop(self, *_args) -> None:
        self.app.playback.stop()
        try:
            self.app.client.stop()
        except Exception:
            pass

    def _link(self, *_args) -> None:
        try:
            ost = next(o for o in self.app.client.get_osts() if o.id == self.ost_id)
            if ost.external_link:
                webbrowser.open(ost.external_link)
        except Exception:
            pass

    def _delete(self, *_args) -> None:
        try:
            self.app.client.delete_ost(self.ost_id)
        except Exception as exc:
            self.status.set_text(str(exc))
            return
        self.close()
