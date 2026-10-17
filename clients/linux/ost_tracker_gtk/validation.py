"""Pure Add-OST form rules — mirrors OSTTracker/Sources/Store/AddOstRules.swift
(kept in sync on purpose). No GTK import so tests can run without PyGObject."""

from __future__ import annotations

from typing import Optional


def _norm(text: str) -> str:
    return " ".join(text.strip().split()).lower()


def can_submit(title: str, submitter_id: Optional[int], people_ids: list[int],
               is_submitting: bool = False, has_history_conflict: bool = False) -> bool:
    """Submitter is REQUIRED (mirrors AddOstRules): an OST nobody clearly owns
    breaks the competition. The backend 400 stays the real enforcement; this
    is only the form gate."""
    return (
        bool(_norm(title))
        and submitter_id in people_ids
        and not is_submitting
        and not has_history_conflict
    )


def history_conflict(title: str, source: str,
                     history: list[tuple[Optional[str], Optional[str]]]) -> Optional[tuple]:
    """Client-side duplicate hint — mirrors AddOstRules.historyConflict: same
    title, and sources match unless either side's source is unknown.
    ``history`` is an iterable of (title, source) pairs."""
    norm_title = _norm(title)
    if not norm_title:
        return None
    norm_source = _norm(source or "")
    for entry_title, entry_source in history:
        if _norm(entry_title or "") != norm_title:
            continue
        entry_source_n = _norm(entry_source or "")
        if not entry_source_n or not norm_source or entry_source_n == norm_source:
            return (entry_title, entry_source)
    return None
