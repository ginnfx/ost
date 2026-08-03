"""GTK4 application shell: sidecar + client + WS pump + page stack."""
from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk  # noqa: E402

from . import pages
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
        self._pages: list[pages.Page] = []
        self.connect("activate", self._on_activate)

    def _on_activate(self, app: Gtk.Application) -> None:
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

        win.set_child(stack)
        win.present()

        self._sidecar = sidecar
        self._win = win
        win.connect("close-request", self._on_close)
        roster.refresh()

    def _on_event(self, event_type: str, payload) -> None:
        if event_type == "leaderboardResorted":
            GLib.idle_add(self._refresh_page, pages.RosterPage)

    def _refresh_page(self, page_type) -> None:
        for page in self._pages:
            if isinstance(page, page_type):
                page.refresh()
                break
        return False  # one-shot idle callback

    def play_ost(self, ost_id: int) -> None:
        try:
            state = self.client.play(ost_id)
            if state.status == "failed":
                if state.watch_url:
                    self._open_browser(state.watch_url)
                return
            if state.stream_url:
                self.playback.play(state.stream_url, state.watch_url)
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
