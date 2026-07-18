"""Build shareable final standings and render them to CSV / Markdown / HTML.

Pure data + string rendering, no Qt and no file I/O, so it is fully unit-tested.
The UI layer (export_dialog) picks a path and turns the HTML into a PDF.

Standings are drawn only from ``osts`` + ``ratings`` — the notes scratchpad can
never leak in here.
"""

from __future__ import annotations

import csv
import io
from dataclasses import dataclass
from typing import Optional

from ost_tracker.db import ost_repo
from ost_tracker.services import statistics

_COLUMNS = ["Rank", "Title", "Submitter", "Average", "Spread", "Std Dev", "Ratings"]


@dataclass(frozen=True)
class Standing:
    rank: Optional[int]
    title: str
    submitter: str
    average: Optional[float]
    spread: str
    stddev: Optional[float]
    rating_count: int

    def as_row(self) -> list[str]:
        return [
            str(self.rank) if self.rank is not None else "—",
            self.title,
            self.submitter,
            f"{self.average:.2f}" if self.average is not None else "—",
            self.spread,
            f"{self.stddev:.2f}" if self.stddev is not None else "—",
            str(self.rating_count),
        ]


def build_standings() -> list[Standing]:
    stats = ost_repo.list_osts_with_stats()
    stats.sort(key=lambda s: (s.rank is None, s.rank or 0, s.ost.title.lower()))
    return [
        Standing(
            rank=s.rank,
            title=s.ost.title,
            submitter=s.ost.submitter_name or "—",
            average=s.average,
            spread=statistics.spread_label(s.minimum, s.maximum),
            stddev=s.stddev,
            rating_count=s.rating_count,
        )
        for s in stats
    ]


def to_csv(standings: list[Standing]) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(_COLUMNS)
    for s in standings:
        writer.writerow(s.as_row())
    return buf.getvalue()


def to_markdown(standings: list[Standing]) -> str:
    lines = ["| " + " | ".join(_COLUMNS) + " |",
             "| " + " | ".join(["---"] * len(_COLUMNS)) + " |"]
    for s in standings:
        cells = [_md_escape(c) for c in s.as_row()]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def to_html(standings: list[Standing], title: str = "OST Standings") -> str:
    rows = []
    for s in standings:
        cells = "".join(f"<td>{_html_escape(c)}</td>" for c in s.as_row())
        rows.append(f"<tr>{cells}</tr>")
    header = "".join(f"<th>{c}</th>" for c in _COLUMNS)
    return (
        f"<html><head><style>"
        f"body {{ font-family: -apple-system, Helvetica, sans-serif; }}"
        f"h1 {{ font-size: 20px; }}"
        f"table {{ border-collapse: collapse; width: 100%; }}"
        f"th, td {{ border: 1px solid #999; padding: 6px 10px; text-align: left; }}"
        f"th {{ background: #eee; }}"
        f"</style></head><body>"
        f"<h1>{_html_escape(title)}</h1>"
        f"<table><thead><tr>{header}</tr></thead><tbody>{''.join(rows)}</tbody></table>"
        f"</body></html>"
    )


def _md_escape(text: str) -> str:
    return text.replace("|", "\\|")


def _html_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )
