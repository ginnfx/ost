"""GTK4 application shell: sidecar + client + WS pump + page stack."""
from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk  # noqa: E402

from . import covers, pages, theme
from .client import Client, WsPump
from .playback import Playback
from .sidecar import Sidecar


class OstApp(Gtk.Application):
    def __init__(self) -> None:
        super().__init__(application_id="dev.brajanzalta.osttracker")
        self.client: Client | None = None
        self._pump: WsPump | None = None
        self.playback = Playback()
        self.port = 0
        self._current_ost: int | None = None
        self._pages: list[pages.Page] = []
        self.connect("activate", self._on_activate)

    def _on_activate(self, app: Gtk.Application) -> None:
        theme.apply()
        try:
            sidecar = Sidecar()
            self.port, token = sidecar.start()
        except Exception as exc:
            self._fatal(f"sidecar failed to start: {exc}")
            return

        self.client = Client(self.port, token)
        self._pump = WsPump(self.port, token, self._on_event)
        self._pump.start()

        win = Gtk.ApplicationWindow(application=self)
        win.set_title("OST Tracker")
        win.set_default_size(900, 640)

        stack = Gtk.Stack()
        stack.set_hexpand(True)
        stack.set_vexpand(True)

        roster = pages.RosterPage(self)
        self._pages = [roster, pages.PeoplePage(self), pages.EntryPage(self), pages.StatsPage(self),
                       pages.BatchesPage(self), pages.SlicesPage(self), pages.RevealPage(self),
                       pages.HistoryPage(self), pages.NotesPage(self), pages.SettingsPage(self),
                       pages.CoverPage(self)]
        for page in self._pages:
            stack.add_named(page, type(page).__name__)

        switcher = Gtk.StackSwitcher()
        switcher.set_stack(stack)

        header = Gtk.HeaderBar()
        header.set_title_widget(switcher)
        win.set_titlebar(header)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.append(stack)
        root.append(self._build_bar())
        win.set_child(root)
        win.present()

        self._sidecar = sidecar
        self._win = win
        win.connect("close-request", self._on_close)
        roster.refresh()

    def _on_event(self, event_type: str, payload) -> None:
        if event_type == "leaderboardResorted":
            GLib.idle_add(self._refresh_page, pages.RosterPage)
        elif event_type == "playbackState":
            GLib.idle_add(self._apply_playback_state, payload)

    def _refresh_page(self, page_type) -> None:
        for page in self._pages:
            if isinstance(page, page_type):
                page.refresh()
                break
        return False  # one-shot idle callback

    def _apply_playback_state(self, payload) -> None:
        status = payload.get("status", "idle")
        self._bar_play.set_label("Pause" if status == "playing" else "Play")
        self._bar_status.set_text(status)
        if status == "idle":
            self._bar_title.set_text("Nothing playing")
        return False  # one-shot idle callback

    def _build_bar(self) -> Gtk.Widget:
        self._bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self._bar.set_margin_top(4)
        self._bar.set_margin_bottom(4)
        self._bar.set_margin_start(8)
        self._bar.set_margin_end(8)
        self._bar.add_css_class("card")

        self._bar_cover = Gtk.Picture()
        self._bar_cover.set_size_request(40, 40)
        self._bar.append(self._bar_cover)

        self._bar_title = Gtk.Label(label="Nothing playing", xalign=0.0, hexpand=True)
        self._bar.append(self._bar_title)

        self._bar_status = Gtk.Label(label="idle")
        self._bar_status.add_css_class("dim-label")
        self._bar.append(self._bar_status)

        self._bar_play = Gtk.Button(label="Play")
        self._bar_play.connect("clicked", lambda *_: self._bar_play_toggle())
        self._bar.append(self._bar_play)

        stop = Gtk.Button(label="Stop")
        stop.connect("clicked", lambda *_: self._bar_stop())
        self._bar.append(stop)
        return self._bar

    def _bar_play_toggle(self) -> None:
        if self._bar_play.get_label() == "Pause":
            self.playback.pause()
            try:
                self.client.pause()
            except Exception:
                pass
        elif self._current_ost:
            self.play_ost(self._current_ost)

    def _bar_stop(self) -> None:
        self.playback.stop()
        try:
            self.client.stop()
        except Exception:
            pass
        self._bar_title.set_text("Nothing playing")
        self._bar_status.set_text("stopped")

    def play_ost(self, ost_id: int) -> None:
        self._current_ost = ost_id
        try:
            state = self.client.play(ost_id)
            if state.status == "failed":
                if state.watch_url:
                    self._open_browser(state.watch_url)
                return
            if state.stream_url:
                self.playback.play(state.stream_url, state.watch_url)
            try:
                ost = next(o for o in self.client.get_osts() if o.id == ost_id)
                self._bar_title.set_text(ost.title)
                self._bar_cover.set_pixbuf(covers.load(ost.cover_image_path, size=80))
            except Exception:
                pass
        except Exception:
            pass

    def _open_browser(self, url: str) -> None:
        import webbrowser

        webbrowser.open(url)

    def _on_close(self, *_args) -> bool:
        self.playback.stop()
        if self._pump:
            self._pump.stop()
        if self.client:
            self.client.close()
        sidecar = getattr(self, "_sidecar", None)
        if sidecar:
            sidecar.stop()
        return False

    def _fatal(self, message: str) -> None:
        # AlertDialog needs GTK >= 4.10; older distros get a plain window.
        if hasattr(Gtk, "AlertDialog"):
            dialog = Gtk.AlertDialog.new(message)
            dialog.set_detail("Could not launch the Python backend. Check the install and try again.")
            dialog.show()
        else:
            win = Gtk.Window()
            win.set_title("OST Tracker")
            win.set_default_size(480, 140)
            win.set_child(Gtk.Label(label=f"{message}\n\nCould not launch the Python backend.", wrap=True))
            win.present()


def main() -> None:
    app = OstApp()
    app.run(None)


if __name__ == "__main__":
    main()
