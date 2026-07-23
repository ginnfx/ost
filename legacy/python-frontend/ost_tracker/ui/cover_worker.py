"""Background cover-art fetching.

The fetch pipeline makes network calls, so it must never run on the UI thread.
This runs each fetch on the global QThreadPool and marshals the result back to
the main thread (Qt queues the cross-thread signal), where the DB write and the
``osts_changed`` broadcast happen safely. Both the Add OST dialog and the detail
view's manual re-fetch go through the same service.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal

from ost_tracker.db import ost_repo
from ost_tracker.services import coverart
from ost_tracker.services.coverart import CoverResult
from ost_tracker.ui.signals import bus


class _TaskSignals(QObject):
    finished = Signal(int, object)  # ost_id, CoverResult


class _CoverTask(QRunnable):
    def __init__(self, ost_id: int, title: str, source: Optional[str]) -> None:
        super().__init__()
        self._ost_id = ost_id
        self._title = title
        self._source = source
        self.signals = _TaskSignals()

    def run(self) -> None:  # executed on a worker thread
        try:
            result = coverart.fetch_cover(self._ost_id, self._title, self._source)
        except Exception:
            result = CoverResult(path=None, source=coverart.CoverSource.NONE)
        self.signals.finished.emit(self._ost_id, result)


class CoverService(QObject):
    """Owns cover-fetch lifecycle and persistence. Screens connect to
    ``fetch_started`` / ``fetch_finished`` for progress feedback."""

    fetch_started = Signal(int)          # ost_id
    fetch_finished = Signal(int, object)  # ost_id, CoverResult

    def fetch(self, ost_id: int, title: str, source: Optional[str]) -> None:
        task = _CoverTask(ost_id, title, source)
        task.signals.finished.connect(self._on_finished)
        self.fetch_started.emit(ost_id)
        QThreadPool.globalInstance().start(task)

    def _on_finished(self, ost_id: int, result: CoverResult) -> None:
        # Runs on the main thread (queued signal) — DB write is safe here.
        if result.found and result.path is not None:
            ost_repo.set_cover(ost_id, str(result.path))
            bus().osts_changed.emit()
        self.fetch_finished.emit(ost_id, result)


_service: Optional[CoverService] = None


def cover_service() -> CoverService:
    global _service
    if _service is None:
        _service = CoverService()
    return _service
