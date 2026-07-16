"""Plain immutable data records returned by the repositories.

These are read models. The UI never mutates them; all changes go back through
the repository write functions, which return fresh rows.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Person:
    id: int
    name: str


@dataclass(frozen=True)
class Note:
    id: int
    title: str
    note: str
    created_at: str


@dataclass(frozen=True)
class Ost:
    id: int
    title: str
    source: Optional[str]
    submitter_id: Optional[int]
    submitter_name: Optional[str]
    cover_image_path: Optional[str]
    external_link: Optional[str]
    created_at: str
    # Accent colour derived from the cover (services/accent.py). Defaulted and
    # last so pre-existing keyword constructions stay valid.
    cover_accent_hex: Optional[str] = None


@dataclass(frozen=True)
class OstStats:
    """An OST joined with its aggregate rating stats.

    ``rank`` is 1-based over the leaderboard (average descending) and is only
    meaningful once ratings exist; unrated OSTs sort last.
    """

    ost: Ost
    rating_count: int
    average: Optional[float]
    minimum: Optional[float]
    maximum: Optional[float]
    stddev: Optional[float]
    rank: Optional[int]


@dataclass(frozen=True)
class HistoryEntry:
    """A previously-used OST (from an earlier competition). Reference/exclusion
    data only — never part of the current competition's rankings or stats."""

    id: int
    title: str
    source: Optional[str]
    batch_label: Optional[str]
    sender: Optional[str]
    created_at: str


@dataclass(frozen=True)
class Rating:
    ost_id: int
    rater_id: int
    rater_name: str
    score: float  # 0–10, any decimal (stored rounded to 2 places)
    updated_at: str
