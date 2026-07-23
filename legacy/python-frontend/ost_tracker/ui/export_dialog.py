"""Export flow (screen 9): save final standings as CSV, Markdown, or PDF.

Format is chosen from the save dialog's filter/extension. CSV and Markdown are
written straight from the export service; PDF is rendered from the service's
HTML via Qt's built-in QPdfWriter (no extra dependency).
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtWidgets import QFileDialog, QMessageBox, QWidget

from ost_tracker.config import exports_dir
from ost_tracker.services import export, reveal

_CSV = "CSV (*.csv)"
_MD = "Markdown (*.md)"
_PDF = "PDF (*.pdf)"


def run_export_flow(parent: QWidget | None = None) -> None:
    standings = export.build_standings()
    if not standings:
        QMessageBox.information(parent, "Nothing to export", "Add some OSTs first.")
        return

    # Exporting reveals the final standings; warn if not yet revealed.
    if not reveal.scores_visible():
        confirm = QMessageBox.question(
            parent,
            "Scores not revealed yet",
            "The competition isn't fully rated / revealed. Export the current "
            "standings anyway?",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if confirm != QMessageBox.Yes:
            return

    default_path = str(exports_dir() / "ost-standings.csv")
    path_str, selected = QFileDialog.getSaveFileName(
        parent, "Export standings", default_path, ";;".join([_CSV, _MD, _PDF])
    )
    if not path_str:
        return

    path = Path(path_str)
    fmt = _format_for(path, selected)
    path = _ensure_suffix(path, fmt)

    try:
        if fmt == "csv":
            path.write_text(export.to_csv(standings), encoding="utf-8")
        elif fmt == "md":
            path.write_text(export.to_markdown(standings), encoding="utf-8")
        else:
            _write_pdf(export.to_html(standings), path)
    except OSError as exc:
        QMessageBox.warning(parent, "Export failed", str(exc))
        return

    QMessageBox.information(parent, "Exported", f"Saved standings to:\n{path}")


def _format_for(path: Path, selected_filter: str) -> str:
    suffix = path.suffix.lower()
    if suffix == ".md":
        return "md"
    if suffix == ".pdf":
        return "pdf"
    if suffix == ".csv":
        return "csv"
    if selected_filter == _MD:
        return "md"
    if selected_filter == _PDF:
        return "pdf"
    return "csv"


def _ensure_suffix(path: Path, fmt: str) -> Path:
    want = f".{fmt}"
    if path.suffix.lower() != want:
        return path.with_suffix(want)
    return path


def _write_pdf(html: str, path: Path) -> None:
    from PySide6.QtGui import QPageSize, QPdfWriter, QTextDocument

    writer = QPdfWriter(str(path))
    writer.setPageSize(QPageSize(QPageSize.A4))
    doc = QTextDocument()
    doc.setHtml(html)
    doc.print_(writer)
