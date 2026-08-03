"""GTK4 screens for the Linux client. Code-built widgets; every page is a thin
view over the sidecar contract — no business logic here."""
from __future__ import annotations

from typing import Optional

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: E402


class Page(Gtk.Box):
    """Base page: vertical box with a title, a status line, and a refresh hook."""

    def __init__(self, title: str) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.set_margin_top(12)
        self.set_margin_bottom(12)
        self.set_margin_start(12)
        self.set_margin_end(12)

        label = Gtk.Label(label=title, xalign=0.0)
        label.add_css_class("title-1")
        self.append(label)

        self._body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.append(self._body)

        self.status = Gtk.Label(label="", xalign=0.0)
        self.status.add_css_class("dim-label")
        self.append(self.status)

    # --- helpers -----------------------------------------------------------------

    def _scroll(self, child: Gtk.Widget) -> Gtk.ScrolledWindow:
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_vexpand(True)
        scrolled.set_child(child)
        return scrolled

    def _list(self) -> Gtk.ListBox:
        box = Gtk.ListBox()
        box.set_selection_mode(Gtk.SelectionMode.SINGLE)
        box.set_vexpand(True)
        return box

    def _fill_list(self, box: Gtk.ListBox, lines: list[str]) -> None:
        for child in list(box):
            box.remove(child)
        for line in lines:
            row = Gtk.ListBoxRow()
            row.set_child(Gtk.Label(label=line, xalign=0.0, wrap=True))
            box.append(row)

    def _entry(self, placeholder: str = "") -> Gtk.Entry:
        entry = Gtk.Entry()
        entry.set_placeholder_text(placeholder)
        return entry

    def _button(self, label: str, on_click) -> Gtk.Button:
        button = Gtk.Button(label=label)
        button.connect("clicked", on_click)
        return button

    def _hbox(self, *children: Gtk.Widget) -> Gtk.Box:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        for child in children:
            box.append(child)
        return box


class RosterPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Roster")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self.append(self._button("Refresh", lambda _: self.refresh()))
        self._list.connect("row-activated", self._on_activate)

    def refresh(self) -> None:
        try:
            entries = self.app.client.get_leaderboard()
            self._fill_list(self._list, [
                f"#{r.rank if r.rank is not None else '—':<4} "
                f"{r.average if r.average is not None else '—':>6}  {r.ost.title}  ({r.ost.submitter_name or '?'})"
                for r in entries
            ])
            self.status.set_text(f"{len(entries)} ranked")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _on_activate(self, box: Gtk.ListBox, row: Gtk.ListBoxRow) -> None:
        label = row.get_child()
        title = label.get_text() if isinstance(label, Gtk.Label) else ""
        try:
            entries = self.app.client.get_leaderboard()
            match = next((r for r in entries if r.ost.title in title), None)
            if match:
                self.app.play_ost(match.ost.id)
        except Exception as exc:
            self.status.set_text(str(exc))


class PeoplePage(Page):
    def __init__(self, app) -> None:
        super().__init__("People")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self._name = self._entry("Name")
        add = self._button("Add", lambda _: self._add())
        self.append(self._hbox(self._name, add))
        self.append(self._button("Remove selected", lambda _: self._remove()))
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            people = self.app.client.get_people()
            self._fill_list(self._list, [f"{p.id}: {p.name}" for p in people])
            self.status.set_text(f"{len(people)} people")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _add(self) -> None:
        name = self._name.get_text().strip()
        if not name:
            return
        self.app.client.add_person(name)
        self._name.set_text("")
        self.refresh()

    def _remove(self) -> None:
        row = self._list.get_selected_row()
        if row is None:
            return
        text = row.get_child().get_text()
        person_id = int(text.split(":")[0])
        self.app.client.delete_person(person_id)
        self.refresh()


class EntryPage(Page):
    """Bulk entry by rater — pick a person, type scores into each OST row."""

    def __init__(self, app) -> None:
        super().__init__("Entry")
        self.app = app
        self._person: Optional[Gtk.DropDown] = None
        self._rows = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self._people: list = []
        self._osts: list = []
        self._ratings: dict[int, float] = {}
        self.refresh_people()

    def refresh_people(self) -> None:
        try:
            self._people = self.app.client.get_people()
            self._osts = self.app.client.get_osts()
        except Exception as exc:
            self.status.set_text(str(exc))
            return
        names = [p.name for p in self._people]
        self._person = Gtk.DropDown()
        self._person.set_model(Gtk.StringList.new(names))
        self._person.set_selected(0 if names else Gtk.INVALID_LIST_POSITION)
        self._person.connect("notify::selected", lambda *_: self._load_ratings())
        self.append(self._person)
        self.append(self._scroll(self._rows))
        if not names:
            self.status.set_text("Add people first.")
        else:
            self._load_ratings()

    def _load_ratings(self) -> None:
        idx = self._person.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION or idx >= len(self._people):
            return
        rater = self._people[idx]
        try:
            ratings = self.app.client.get_ratings()
            self._ratings = {r.ost_id: r.score for r in ratings if r.rater_id == rater.id}
        except Exception as exc:
            self.status.set_text(str(exc))
            return
        for child in list(self._rows):
            self._rows.remove(child)
        for ost in self._osts:
            entry = self._entry("0–10")
            entry.set_width_chars(5)
            entry.set_text(f"{self._ratings[ost.id]:g}" if ost.id in self._ratings else "")
            entry.connect("activate", lambda _, e=entry, o=ost: self._save(e, o, rater))
            title = Gtk.Label(label=ost.title, xalign=0.0, hexpand=True)
            title.set_ellipsize(3)  # PANGO_ELLIPSIZE_END
            self._rows.append(self._hbox(title, entry))
        self.status.set_text(f"{len(self._ratings)}/{len(self._osts)} rated for {rater.name}")

    def _save(self, entry: Gtk.Entry, ost, rater) -> None:
        text = entry.get_text().strip()
        score = float(text) if text else None
        try:
            self.app.client.put_rating(ost.id, rater.id, score)
            if score is None:
                self._ratings.pop(ost.id, None)
            else:
                self._ratings[ost.id] = score
            self.status.set_text(f"{len(self._ratings)}/{len(self._osts)} rated for {rater.name}")
        except Exception as exc:
            self.status.set_text(str(exc))


class StatsPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Stats")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            entries = self.app.client.get_leaderboard()
            self._fill_list(self._list, [
                f"{r.ost.title:<40} n={r.rating_count:2}  avg {r.average if r.average is not None else '—':>6}"
                f"  min {r.minimum if r.minimum is not None else '—':>4}"
                f"  max {r.maximum if r.maximum is not None else '—':>4}"
                f"  σ {r.stddev if r.stddev is not None else '—':.2f}" if r.stddev is not None
                else f"{r.ost.title:<40} n={r.rating_count:2}  avg {r.average if r.average is not None else '—':>6}"
            ])
        except Exception as exc:
            self.status.set_text(str(exc))


class BatchesPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Batches")
        self.app = app
        self._loaded = False
        self._list = self._list()
        self.append(self._scroll(self._list))
        self.append(self._button("Randomize", lambda _: self._randomize()))
        self._count = Gtk.DropDown()
        self._count.set_model(Gtk.StringList.new([str(i) for i in range(1, 9)]))
        self._count.connect("notify::selected", lambda *_: self._set_count())
        self.append(self._hbox(Gtk.Label(label="Days (1–8):"), self._count))
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            batches = self.app.client.get_batches()
            self._fill_list(self._list, [
                f"Day {g.day}: " + ", ".join(s.ost.title for s in g.slots) for g in batches.batches
            ])
            self.status.set_text("not yet generated" if batches.generated_at is None else f"generated {batches.generated_at}")
            self._loaded = True
        except Exception as exc:
            self.status.set_text(str(exc))

    def _randomize(self) -> None:
        self.app.client.randomize_batches()
        self.refresh()

    def _set_count(self) -> None:
        if not self._loaded:   # no accidental write while the page first renders
            return
        idx = self._count.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION:
            return
        self.app.client.put_batch_count(idx + 1)
        self.refresh()


class SlicesPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Slice elimination")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self._threshold = Gtk.SpinButton.new(Gtk.Adjustment(lower=1, upper=20, step_increment=1), 1.0, 0)
        self.append(self._hbox(Gtk.Label(label="Threshold:"), self._threshold,
                               self._button("Set", lambda _: self._set_threshold())))
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            board = self.app.client.get_elimination()
            lines: list[str] = []
            for slice_ in board.slices:
                tally = ", ".join(
                    f"{t.name} (out here {t.out_here}/{t.total_out}{' ✗' if t.eliminated_here else ''})"
                    for t in slice_.tallies
                )
                lines.append(f"{slice_.label}: {tally}")
            for s in board.survivors:
                lines.append(f"safe: {s.name} ({s.remaining} left)")
            for e in board.eliminated:
                lines.append(f"ELIMINATED #{e.place}: {e.name} at rank {e.out_at_rank}")
            self._fill_list(self._list, lines)
            self._threshold.set_value(board.threshold)
            self.status.set_text(f"{board.ranked_count} ranked, slice size {board.slice_size}")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _set_threshold(self) -> None:
        self.app.client.put_threshold(int(self._threshold.get_value()))
        self.refresh()


class RevealPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Reveal")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            entries = sorted(self.app.client.get_leaderboard(), key=lambda r: r.rank if r.rank is not None else 10**9)
            self._fill_list(self._list, [
                (f"#{r.rank:3}  {r.ost.title:<40}  {r.average:.2f}" if r.rank is not None
                 else f"—     {r.ost.title:<40}  (unrated)")
                for r in entries
            ])
        except Exception as exc:
            self.status.set_text(str(exc))


class HistoryPage(Page):
    def __init__(self, app) -> None:
        super().__init__("History")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self._title = self._entry("Title to check (duplicates are blocked on submit)")
        self.append(self._hbox(self._title, self._button("Search matches", lambda _: self._search()),
                               self._button("Show all", lambda _: self.refresh())))

    def refresh(self) -> None:
        try:
            entries = self.app.client.get_history()
            self._fill_list(self._list, [
                f"{h.title}  ({h.source or '?'})  — {h.batch_label or '?'}  from {h.sender or '?'}"
                for h in entries
            ])
            self.status.set_text(f"{len(entries)} past entries")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _search(self) -> None:
        try:
            matches = self.app.client.history_matches(self._title.get_text())
            self._fill_list(self._list, [f"{h.title}  ({h.source or '?'})" for h in matches])
            self.status.set_text("no matches — free to submit" if not matches else f"{len(matches)} match(es) — blocked")
        except Exception as exc:
            self.status.set_text(str(exc))


class NotesPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Notes")
        self.app = app
        self._list = self._list()
        self.append(self._scroll(self._list))
        self._title = self._entry("Title")
        self._note = Gtk.TextView()
        self._note.set_vexpand(False)
        self._note.set_size_request(-1, 80)
        self.append(self._note)
        self.append(self._hbox(self._title, self._button("Add", lambda _: self._add()),
                               self._button("Delete selected", lambda _: self._delete())))
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            notes = self.app.client.get_notes()
            self._fill_list(self._list, [f"{n.id}: {n.title} — {n.note or ''}" for n in notes])
            self.status.set_text(f"{len(notes)} notes (scratchpad only — never part of standings)")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _add(self) -> None:
        buffer = self._note.get_buffer()
        note_text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
        self.app.client.add_note(self._title.get_text(), note_text)
        self._title.set_text("")
        buffer.set_text("", -1)
        self.refresh()

    def _delete(self) -> None:
        row = self._list.get_selected_row()
        if row is None:
            return
        text = row.get_child().get_text()
        note_id = int(text.split(":")[0])
        self.app.client.delete_note(note_id)
        self.refresh()


class SettingsPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Settings")
        self.app = app
        self._info = Gtk.Label(label="", xalign=0.0, wrap=True)
        self.append(self._info)
        self.append(self._button("Refresh", lambda _: self.refresh()))

    def refresh(self) -> None:
        try:
            board = self.app.client.get_elimination()
            self._info.set_text(
                "Data dir:  ~/.local/share/ost-tracker (or $XDG_DATA_HOME)\n"
                f"Sidecar port:  {self.app.port}\n"
                f"Elimination threshold: {board.threshold} (edit on the Slices page)\n"
                f"Elimination slice size: {board.slice_size}\n\n"
                "OST Tracker for Linux — the Python sidecar does all the work;\n"
                "this UI is just a contract client."
            )
        except Exception as exc:
            self._info.set_text(str(exc))


class CoverPage(Page):
    def __init__(self, app) -> None:
        super().__init__("Cover picker")
        self.app = app
        self._osts: list = []
        self._cands: list = []
        self._dropdown = Gtk.DropDown()
        self._dropdown.connect("notify::selected", lambda *_: self._load_candidates())
        self.append(self._dropdown)
        self._list = self._list()
        self.append(self._scroll(self._list))
        self.append(self._button("Apply selected candidate", lambda _: self._apply()))
        self.refresh()

    def refresh(self) -> None:
        try:
            self._osts = self.app.client.get_osts()
            self._dropdown.set_model(Gtk.StringList.new([f"{o.title} ({o.submitter_name or '?'})" for o in self._osts]))
        except Exception as exc:
            self.status.set_text(str(exc))

    def _load_candidates(self) -> None:
        idx = self._dropdown.get_selected()
        if idx == Gtk.INVALID_LIST_POSITION or idx >= len(self._osts):
            return
        try:
            self._cands = self.app.client.cover_candidates(self._osts[idx].id)
            self._fill_list(self._list, [f"{c.label}  [{c.source_name}]" for c in self._cands])
            self.status.set_text(f"{len(self._cands)} candidates")
        except Exception as exc:
            self.status.set_text(str(exc))

    def _apply(self) -> None:
        idx = self._dropdown.get_selected()
        row = self._list.get_selected_row()
        if idx == Gtk.INVALID_LIST_POSITION or row is None:
            return
        cand_idx = row.get_index()
        if cand_idx >= len(self._cands):
            return
        self.app.client.set_cover(self._osts[idx].id, self._cands[cand_idx].image_url)
        self.status.set_text("cover updated")
