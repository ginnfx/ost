"""DTOs mirroring shared/CONTRACT.md (snake_case wire keys)."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Person:
    id: int
    name: str


@dataclass
class Ost:
    id: int
    title: str
    source: Optional[str] = None
    submitter_id: Optional[int] = None
    submitter_name: Optional[str] = None
    cover_image_path: Optional[str] = None
    cover_accent_hex: Optional[str] = None
    external_link: Optional[str] = None
    created_at: str = ""


@dataclass
class Rating:
    ost_id: int
    rater_id: int
    rater_name: str
    score: float
    updated_at: str = ""


@dataclass
class Note:
    id: int
    title: str
    note: Optional[str] = None
    created_at: str = ""


@dataclass
class RankEntry:
    ost: Ost
    rating_count: int = 0
    average: Optional[float] = None
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    stddev: Optional[float] = None
    rank: Optional[int] = None


@dataclass
class PlaybackState:
    status: str = "idle"
    ost_id: Optional[int] = None
    stream_url: Optional[str] = None
    watch_url: Optional[str] = None
    position: float = 0.0


@dataclass
class BatchSlot:
    slot: int
    ost: Ost
    pinned: bool = False


@dataclass
class BatchGroup:
    index: int
    day: int
    slots: list[BatchSlot] = field(default_factory=list)


@dataclass
class Batches:
    generated_at: Optional[str] = None
    batches: list[BatchGroup] = field(default_factory=list)


@dataclass
class SliceTally:
    person_id: int
    name: str
    out_here: int
    total_out: int
    remaining: int
    eliminated_here: bool = False


@dataclass
class RankSlice:
    index: int
    bottom_rank: int
    top_rank: int
    label: str
    ost_ids: list[int] = field(default_factory=list)
    tallies: list[SliceTally] = field(default_factory=list)


@dataclass
class Elimination:
    person_id: int
    name: str
    place: int
    slice_index: int
    out_at_rank: int
    total_out: int


@dataclass
class Survivor:
    person_id: int
    name: str
    total_out: int
    remaining: int


@dataclass
class EliminationBoard:
    threshold: int = 5
    slice_size: int = 10
    ranked_count: int = 0
    slices: list[RankSlice] = field(default_factory=list)
    eliminated: list[Elimination] = field(default_factory=list)
    survivors: list[Survivor] = field(default_factory=list)


@dataclass
class HistoryEntry:
    id: int
    title: str
    source: Optional[str] = None
    batch_label: Optional[str] = None
    sender: Optional[str] = None
    created_at: str = ""


@dataclass
class CoverCandidate:
    image_url: str
    thumb_url: Optional[str] = None
    label: str = ""
    source_name: str = ""
