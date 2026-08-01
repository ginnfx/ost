"""One-off generator: parse list.md's past-ranking tables into a static
seed data file for ost_tracker.db.migrations.

Run once by hand whenever list.md's *past* batches change:

    python scripts/generate_history_seed.py

Only batches 1-4 are captured — Batch 5 is the ranking currently live in
the `osts` table, which the app backfills directly from the database
instead of trusting this file to match it verbatim. Rows with no real
title (the two "*Image Missing*" placeholders in Batch 1) are skipped.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIST_MD = REPO_ROOT / "list.md"
OUTPUT = REPO_ROOT / "ost_tracker" / "db" / "history_seed_data.py"

BATCH_HEADER_RE = re.compile(r"^### (Batch \d+: .+)$")
MAX_PAST_BATCH = 4


def _clean(cell: str) -> str | None:
    cell = cell.strip()
    if not cell or cell == "-" or cell == "*Image Missing*":
        return None
    return cell


def parse_entries() -> list[dict]:
    entries: list[dict] = []
    batch_label: str | None = None
    batch_num = 0

    for raw_line in LIST_MD.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()

        header_match = BATCH_HEADER_RE.match(line)
        if header_match:
            batch_num += 1
            batch_label = header_match.group(1)
            continue

        if batch_label is None or batch_num > MAX_PAST_BATCH:
            continue

        if not line.startswith("|"):
            continue

        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 4:
            continue
        number, ost_name, franchise, sender = cells
        if number == "#" or set(number) <= {"-", ":"}:
            continue  # header / separator row

        title = _clean(ost_name)
        if title is None:
            continue  # placeholder row, no real title to record

        entries.append(
            {
                "title": title,
                "source": _clean(franchise),
                "batch_label": batch_label,
                "sender": _clean(sender),
            }
        )

    return entries


def render(entries: list[dict]) -> str:
    lines = [
        '"""Static seed data for `ost_history`, generated from list.md by',
        '`scripts/generate_history_seed.py`. Covers past rankings (batches 1-4);',
        "the current ranking is backfilled directly from the live `osts` table",
        "instead (see ost_tracker/db/migrations.py).",
        '"""',
        "",
        "SEED_ENTRIES: list[dict] = [",
    ]
    for e in entries:
        lines.append(
            "    {"
            f"\"title\": {e['title']!r}, \"source\": {e['source']!r}, "
            f"\"batch_label\": {e['batch_label']!r}, \"sender\": {e['sender']!r}"
            "},"
        )
    lines.append("]")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    entries = parse_entries()
    OUTPUT.write_text(render(entries), encoding="utf-8")
    print(f"Wrote {len(entries)} entries to {OUTPUT.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
