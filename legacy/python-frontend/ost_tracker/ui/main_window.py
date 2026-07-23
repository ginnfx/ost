"""Main application window: native menu bar, a sidebar of screens, and the
content stack. Screens communicate through the signal bus, so the window only
wires navigation, not data flow.
"""

from __future__ import annotations

from PySide6.QtCore import QSize, Qt
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from ost_tracker import APP_NAME
from ost_tracker.db import people_repo
from ost_tracker.ui import icons, theme
from ost_tracker.ui.history_view import HistoryScreen
from ost_tracker.ui.home_screen import HomeScreen
from ost_tracker.ui.notes_view import NotesScreen
from ost_tracker.ui.people_view import PeopleScreen
from ost_tracker.ui.signals import bus

# (key, label, icon, factory) — order defines sidebar order. Exactly two
# top-level destinations. People comes first: it's the prerequisite for the
# Leaderboard. Rating happens through Quick Rate (card click) and the detail
# view's inline strip — the old Rate batch screens live in ui/archive/. Stats
# folded into the detail view (per-OST) and People (per-rater leniency).
# Notes (scratchpad) and History (prior-OST exclusion list) are auxiliary tools,
# opened from the menu bar rather than occupying a sidebar slot.
_SIDEBAR = [
    ("people", "People", "fa5s.users", PeopleScreen),
    ("home", "Leaderboard", "fa5s.trophy", HomeScreen),
]


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.resize(1180, 800)
        self._screens: dict[str, QWidget] = {}
        self._build_central()
        self._build_menu()
        self._connect_signals()

        # Track the reveal moment: celebrate once, the instant scores become
        # visible. If already revealed at launch, don't re-celebrate.
        from ost_tracker.services import reveal

        self._reveal_seen = reveal.scores_visible()

    # --- layout -------------------------------------------------------------

    def _build_central(self) -> None:
        central = QWidget()
        layout = QHBoxLayout(central)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Sidebar: app title + icon nav, on its own darker panel.
        sidebar = QWidget()
        sidebar.setObjectName("sidebarPanel")
        sidebar.setFixedWidth(212)
        sidebar.setStyleSheet(f"#sidebarPanel {{ background:{theme.SIDEBAR_BG}; }}")
        side_col = QVBoxLayout(sidebar)
        side_col.setContentsMargins(0, 0, 0, 0)
        side_col.setSpacing(0)
        side_col.addWidget(self._build_brand())

        self.nav = QListWidget()
        self.nav.setObjectName("sidebar")
        self.nav.setFrameShape(QListWidget.NoFrame)
        self.nav.setIconSize(QSize(17, 17))
        self.nav.currentRowChanged.connect(self._on_nav_changed)
        side_col.addWidget(self.nav, 1)
        layout.addWidget(sidebar)

        self.stack = QStackedWidget()
        layout.addWidget(self.stack, 1)

        self._keys: list[str] = []
        for key, label, icon_name, factory in _SIDEBAR:
            widget = factory()
            self._screens[key] = widget
            self.stack.addWidget(widget)
            item = QListWidgetItem(icons.icon(icon_name, theme.TEXT_DIM), label)
            item.setSizeHint(item.sizeHint().expandedTo(_nav_item_height()))
            self.nav.addItem(item)
            self._keys.append(key)

        self.setCentralWidget(central)
        # Open to People on a fresh install (nothing to show yet, and it's the
        # first step); otherwise open to the Leaderboard, the default view.
        start = "people" if people_repo.count_people() == 0 else "home"
        self.nav.setCurrentRow(self._keys.index(start))

    def _build_menu(self) -> None:
        bar = self.menuBar()

        file_menu = bar.addMenu("File")
        add_action = QAction("Add OST…", self)
        add_action.setShortcut(QKeySequence.New)  # Cmd+N
        add_action.triggered.connect(lambda: self.open_add_ost())
        file_menu.addAction(add_action)

        export_action = QAction("Export Standings…", self)
        export_action.setShortcut(QKeySequence("Ctrl+E"))
        export_action.triggered.connect(self._export)
        file_menu.addAction(export_action)

        file_menu.addSeparator()
        settings_action = QAction("Settings…", self)
        settings_action.triggered.connect(self._open_settings)
        file_menu.addAction(settings_action)

        edit_menu = bar.addMenu("Edit")
        find_action = QAction("Find", self)
        find_action.setShortcut(QKeySequence.Find)  # Cmd+F
        find_action.triggered.connect(self._focus_search)
        edit_menu.addAction(find_action)

        people_action = QAction("People…", self)
        people_action.setShortcut(QKeySequence.Preferences)  # Cmd+,
        people_action.setMenuRole(QAction.PreferencesRole)
        people_action.triggered.connect(lambda: self.navigate("people"))
        edit_menu.addAction(people_action)

        view_menu = bar.addMenu("View")
        for i, (key, label, _icon, _factory) in enumerate(_SIDEBAR):
            act = QAction(label, self)
            if i < 9:
                act.setShortcut(QKeySequence(f"Ctrl+{i + 1}"))
            act.triggered.connect(lambda _=False, k=key: self.navigate(k))
            view_menu.addAction(act)
        view_menu.addSeparator()
        self.reveal_action = QAction("Reveal Leaderboard Now", self)
        self.reveal_action.setShortcut(QKeySequence("Ctrl+R"))
        self.reveal_action.triggered.connect(self._reveal_now)
        view_menu.addAction(self.reveal_action)

        # Auxiliary tools — not sidebar destinations (keeps the sidebar at four).
        tools_menu = bar.addMenu("Tools")
        notes_action = QAction("Notes…", self)
        notes_action.setShortcut(QKeySequence("Ctrl+5"))
        notes_action.triggered.connect(lambda: self._open_tool_window("Notes", NotesScreen))
        tools_menu.addAction(notes_action)
        history_action = QAction("History…", self)
        history_action.setShortcut(QKeySequence("Ctrl+6"))
        history_action.triggered.connect(lambda: self._open_tool_window("History", HistoryScreen))
        tools_menu.addAction(history_action)

    def _connect_signals(self) -> None:
        b = bus()
        b.open_detail_requested.connect(self._open_detail)
        b.navigate_requested.connect(self.navigate)
        b.open_add_ost_requested.connect(self.open_add_ost)
        b.ratings_changed.connect(self._maybe_celebrate_reveal)
        b.reveal_changed.connect(self._maybe_celebrate_reveal)

    def _maybe_celebrate_reveal(self) -> None:
        from ost_tracker.services import reveal

        if self._reveal_seen or not reveal.scores_visible():
            return
        self._reveal_seen = True
        from ost_tracker.ui.reveal_dialog import RevealDialog

        RevealDialog(self).exec()
        self.navigate("home")

    # --- navigation ---------------------------------------------------------

    def _build_brand(self) -> QWidget:
        brand = QWidget()
        row = QHBoxLayout(brand)
        row.setContentsMargins(18, 18, 18, 10)
        row.setSpacing(10)
        logo = QLabel()
        logo.setFixedSize(32, 32)
        logo.setAlignment(Qt.AlignCenter)
        logo.setPixmap(icons.icon("fa5s.compact-disc", theme.ON_ACCENT).pixmap(18, 18))
        logo.setStyleSheet(f"background: {theme.ACCENT}; border: 1px solid {theme.BORDER_DARK}; border-radius: 9px;")
        row.addWidget(logo)
        name = QLabel("OST Tracker")
        nf = name.font()
        nf.setPointSize(14)
        nf.setBold(True)
        name.setFont(nf)
        row.addWidget(name)
        row.addStretch(1)
        return brand

    def _on_nav_changed(self, row: int) -> None:
        if 0 <= row < self.stack.count():
            self.stack.setCurrentIndex(row)
        # Brighten the selected item's icon (white on the accent gradient).
        for i in range(self.nav.count()):
            icon_name = _SIDEBAR[i][2]
            color = theme.ON_ACCENT if i == row else theme.TEXT_DIM
            self.nav.item(i).setIcon(icons.icon(icon_name, color))

    def navigate(self, key: str) -> None:
        if key in self._keys:
            self.nav.setCurrentRow(self._keys.index(key))

    def _open_detail(self, ost_id: int) -> None:
        self.navigate("home")
        home = self._screens["home"]
        if isinstance(home, HomeScreen):
            home.show_detail(ost_id)

    def _focus_search(self) -> None:
        self.navigate("home")
        home = self._screens["home"]
        if isinstance(home, HomeScreen):
            home.focus_search()

    # --- actions ------------------------------------------------------------

    def open_add_ost(
        self,
        prefill_title: str = "",
        prefill_note: str = "",
        prefill_submitter_id: int | None = None,
    ) -> None:
        # An OST needs a submitter to assign; with nobody added yet, send the
        # user to People first rather than opening a dead-end dialog.
        if people_repo.count_people() == 0:
            from PySide6.QtWidgets import QMessageBox

            QMessageBox.information(
                self,
                "Add people first",
                "Add the competitors on the People screen before adding OSTs.",
            )
            self.navigate("people")
            return

        from ost_tracker.ui.add_ost_dialog import AddOstDialog

        dialog = AddOstDialog(
            self,
            prefill_title=prefill_title,
            prefill_note=prefill_note,
            prefill_submitter_id=prefill_submitter_id,
        )
        dialog.exec()

    def _export(self) -> None:
        from ost_tracker.ui.export_dialog import run_export_flow

        run_export_flow(self)

    def _open_settings(self) -> None:
        from ost_tracker.ui.settings_dialog import SettingsDialog

        SettingsDialog(self).exec()

    def _open_tool_window(self, title: str, factory) -> None:
        """Open an auxiliary screen (Notes / History) in its own window instead
        of a sidebar slot, so the sidebar stays a two-destination list."""
        from PySide6.QtWidgets import QDialog, QVBoxLayout

        dlg = QDialog(self)
        dlg.setWindowTitle(title)
        dlg.setMinimumSize(760, 560)
        lay = QVBoxLayout(dlg)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(factory())
        dlg.exec()

    def _reveal_now(self) -> None:
        from ost_tracker.services import reveal
        from PySide6.QtWidgets import QMessageBox

        if reveal.scores_visible():
            QMessageBox.information(self, "Already revealed", "The leaderboard is already visible.")
            return
        confirm = QMessageBox.question(
            self,
            "Reveal the leaderboard?",
            "This reveals all scores and rankings now, before every rating is in. Continue?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm == QMessageBox.Yes:
            reveal.set_manually_unlocked(True)
            bus().reveal_changed.emit()


def _nav_item_height():
    from PySide6.QtCore import QSize

    return QSize(0, 34)
