"""Cover picker dialog.

Automated cover matching for game/anime OSTs is unreliable — iTunes almost
always returns *a* song, but often the wrong one. This dialog instead pulls
candidates from every source at once (iTunes songs + albums, MusicBrainz/Cover
Art Archive, the OST's own YouTube link, and a YouTube search) and shows them as
a grid of thumbnails so you can click the correct one. Pasting an image/YouTube
URL or choosing a local file are folded in as fallbacks.

The search + thumbnail downloads run on a background thread so the UI never
blocks; results are marshaled back to the main thread to build the grid.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

import httpx
from PySide6.QtCore import QObject, QRunnable, QSize, Qt, QThreadPool, Signal
from PySide6.QtGui import QIcon, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QDialog,
    QFileDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QScrollArea,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ost_tracker.db import ost_repo
from ost_tracker.db.models import Ost
from ost_tracker.services import coverart
from ost_tracker.ui import theme
from ost_tracker.ui.signals import bus
from ost_tracker.ui.widgets import ghost_button, primary_button

_THUMB = 120
_COLUMNS = 4
_USER_AGENT = "OSTTracker/1.0 (local desktop app; personal use)"


class _SearchSignals(QObject):
    ready = Signal(list)  # list[(CoverCandidate, bytes | None)]


# Keep in-flight tasks referenced until they finish, so a task (and its signal
# source) is never garbage-collected mid-run when the dialog closes early.
_active_tasks: set["_SearchTask"] = set()


class _SearchTask(QRunnable):
    def __init__(self, title: str, source: Optional[str], external_link: Optional[str]) -> None:
        super().__init__()
        self._title = title
        self._source = source
        self._link = external_link
        self.signals = _SearchSignals()

    def run(self) -> None:
        results: list[tuple[coverart.CoverCandidate, Optional[bytes]]] = []
        try:
            with httpx.Client(timeout=coverart._TIMEOUT, headers={"User-Agent": _USER_AGENT}) as client:
                candidates = coverart.search_candidates(
                    self._title, self._source, self._link, client=client
                )
                for cand in candidates:
                    thumb = self._download(client, cand.thumb_url)
                    results.append((cand, thumb))
        except Exception:
            results = []
        try:
            self.signals.ready.emit(results)
        except RuntimeError:
            pass  # dialog/signal source went away before we finished — harmless

    @staticmethod
    def _download(client: httpx.Client, url: str) -> Optional[bytes]:
        try:
            resp = client.get(url, follow_redirects=True, headers={"User-Agent": _USER_AGENT})
            resp.raise_for_status()
            return resp.content
        except (httpx.HTTPError, ValueError):
            return None


def _square_pixmap(data: Optional[bytes], size: int) -> QPixmap:
    if data:
        pm = QPixmap()
        if pm.loadFromData(data) and not pm.isNull():
            scaled = pm.scaled(size, size, Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation)
            x = max(0, (scaled.width() - size) // 2)
            y = max(0, (scaled.height() - size) // 2)
            return scaled.copy(x, y, size, size)
    placeholder = QPixmap(size, size)
    placeholder.fill(Qt.gray)
    return placeholder


class CoverPickerDialog(QDialog):
    def __init__(self, ost: Ost, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._ost = ost
        self.setWindowTitle("Choose a cover")
        self.setMinimumSize(660, 580)
        self._task: Optional[_SearchTask] = None
        self._results: list = []  # [(CoverCandidate, thumb_bytes | None)]
        self._build_ui()
        self._start_search()

    # --- construction -------------------------------------------------------

    def _build_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(theme.HEADER_GAP)

        subtitle = f" · filtered to “{self._ost.source}”" if (self._ost.source or "").strip() else ""
        heading = QLabel(f"Choose a cover for “{self._ost.title}”{subtitle}")
        hf = heading.font()
        hf.setPointSize(15)
        hf.setBold(True)
        heading.setFont(hf)
        heading.setWordWrap(True)
        root.addWidget(heading)

        status_row = QHBoxLayout()
        self.status = QLabel("Searching iTunes, MusicBrainz, Bing and YouTube…")
        self.status.setStyleSheet(f"color:{theme.TEXT_DIM};")
        status_row.addWidget(self.status)
        status_row.addStretch(1)
        self._show_all = QCheckBox("Show all sources")
        self._show_all.setToolTip("Include results that don't match the franchise")
        self._show_all.toggled.connect(self._render_results)
        status_row.addWidget(self._show_all)
        root.addLayout(status_row)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        self._grid_host = QWidget()
        self._grid = QGridLayout(self._grid_host)
        self._grid.setContentsMargins(0, 0, 0, 0)
        self._grid.setSpacing(12)
        self._grid.setAlignment(Qt.AlignTop)
        scroll.setWidget(self._grid_host)
        root.addWidget(scroll, 1)

        # Manual fallbacks: paste an image/YouTube URL, or pick a file.
        manual = QHBoxLayout()
        self.url_edit = QLineEdit()
        self.url_edit.setPlaceholderText("Paste an image URL or a YouTube link…")
        self.url_edit.returnPressed.connect(self._use_url)
        manual.addWidget(self.url_edit, 1)
        use_url_btn = ghost_button("Use URL")
        use_url_btn.clicked.connect(self._use_url)
        manual.addWidget(use_url_btn)
        file_btn = ghost_button("From file…")
        file_btn.clicked.connect(self._use_file)
        manual.addWidget(file_btn)
        root.addLayout(manual)

        footer = QHBoxLayout()
        footer.addStretch(1)
        retry = ghost_button("Search again")
        retry.clicked.connect(self._start_search)
        footer.addWidget(retry)
        close_btn = primary_button("Cancel")
        close_btn.clicked.connect(self.reject)
        footer.addWidget(close_btn)
        root.addLayout(footer)

    # --- search -------------------------------------------------------------

    def _start_search(self) -> None:
        self._clear_grid()
        self.status.setVisible(True)
        self.status.setText("Searching iTunes, MusicBrainz, Bing and YouTube…")
        task = _SearchTask(self._ost.title, self._ost.source, self._ost.external_link)
        task.signals.ready.connect(self._on_results)
        task.signals.ready.connect(lambda *_: _active_tasks.discard(task))
        self._task = task
        _active_tasks.add(task)
        QThreadPool.globalInstance().start(task)

    def _on_results(self, results: list) -> None:
        self._results = results
        self._render_results()

    def _render_results(self) -> None:
        self._clear_grid()
        if not self._results:
            self.status.setVisible(True)
            self.status.setText(
                "No covers found automatically — paste a URL or choose a file below."
            )
            return

        # Only keep candidates whose image actually loaded — this drops dead
        # tiles (e.g. MusicBrainz releases with no Cover Art Archive image), so
        # every tile shown is a real, usable cover.
        loadable = [(c, t) for c, t in self._results if t is not None]
        if not loadable:
            self.status.setVisible(True)
            self.status.setText(
                "Sources returned no usable images — paste a URL or choose a file below."
            )
            return

        title = self._ost.title
        source = self._ost.source
        scored = []
        for cand, thumb in loadable:
            own = cand.source_name == "Your link"
            relevant = own or coverart.is_franchise_relevant(cand.label, title, source)
            score = 1e9 if own else coverart.candidate_relevance(cand.label, title, source)
            scored.append((cand, thumb, relevant, score))
        # Relevant first, then by relevance score descending.
        scored.sort(key=lambda x: (not x[2], -x[3]))

        show_all = self._show_all.isChecked()
        visible = scored if show_all else [s for s in scored if s[2]]
        hidden = len(scored) - len(visible)
        if not visible:  # franchise filter hid everything — fall back to all
            visible = scored
            hidden = 0

        for i, (cand, thumb, _rel, _score) in enumerate(visible):
            self._grid.addWidget(self._make_tile(cand, thumb), i // _COLUMNS, i % _COLUMNS)

        self.status.setVisible(True)
        if hidden and not show_all:
            self.status.setText(
                f"{len(visible)} matches for “{source}” · {hidden} off-franchise hidden "
                f"— tick “Show all sources” to see them"
            )
        else:
            self.status.setText(f"{len(visible)} result{'s' if len(visible) != 1 else ''}")

    def _make_tile(self, cand: coverart.CoverCandidate, thumb: Optional[bytes]) -> QToolButton:
        btn = QToolButton()
        btn.setToolButtonStyle(Qt.ToolButtonTextUnderIcon)
        btn.setIcon(QIcon(_square_pixmap(thumb, _THUMB)))
        btn.setIconSize(QSize(_THUMB, _THUMB))
        btn.setCursor(Qt.PointingHandCursor)
        btn.setFixedSize(_THUMB + 24, _THUMB + 46)
        label = cand.source_name
        btn.setText(label)
        btn.setToolTip(f"{cand.source_name}: {cand.label}")
        btn.setStyleSheet(
            f"QToolButton {{ border:1px solid {theme.BORDER}; border-radius:8px;"
            f" padding:6px; color:{theme.TEXT_DIM}; font-size:10px; }}"
            f"QToolButton:hover {{ border-color:{theme.ACCENT}; color:{theme.TEXT}; }}"
        )
        btn.clicked.connect(lambda: self._apply_url(cand.image_url))
        return btn

    def _clear_grid(self) -> None:
        while self._grid.count():
            item = self._grid.takeAt(0)
            w = item.widget()
            if w:
                w.deleteLater()

    # --- apply --------------------------------------------------------------

    def _apply_url(self, url: str) -> None:
        # A YouTube link resolves to that video's thumbnail; anything else is
        # treated as a direct image URL.
        vid = coverart.youtube_video_id(url)
        image_url = coverart.youtube_thumbnail(vid)[0] if vid else url
        QApplication.setOverrideCursor(Qt.WaitCursor)
        try:
            result = coverart.import_cover_from_url(self._ost.id, image_url)
        finally:
            QApplication.restoreOverrideCursor()
        if result.found:
            self._commit(result.path)
        else:
            QMessageBox.warning(self, "Couldn't use that", "That image couldn't be fetched.")

    def _use_url(self) -> None:
        url = self.url_edit.text().strip()
        if url:
            self._apply_url(url)

    def _use_file(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self, "Choose cover image", "", "Images (*.png *.jpg *.jpeg *.webp *.gif *.bmp)"
        )
        if not path:
            return
        result = coverart.import_cover_from_file(self._ost.id, Path(path))
        if result.found:
            self._commit(result.path)
        else:
            QMessageBox.warning(self, "Couldn't use that", "That file couldn't be read as an image.")

    def _commit(self, path) -> None:
        ost_repo.set_cover(self._ost.id, str(path))
        bus().osts_changed.emit()
        self.accept()
