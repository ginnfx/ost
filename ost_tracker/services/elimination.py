"""Slice-elimination board — the roster's "who's still standing" view.

The ranked leaderboard is cut into fixed-size slices counting UP from the WORST
rank: 50 OSTs give 50–41, 40–31, 30–21, 20–11, 10–1. Bottom-anchored, so a
short roster leaves the ragged slice at the TOP (47 OSTs -> 47–38 … 7–1), never
at the bottom where the eliminations happen.

Slices are read worst-first. Every OST in a slice is "out", and each person's
out-count accumulates across slices; the moment it reaches the threshold
(``elimination_threshold``, default :data:`DEFAULT_THRESHOLD` = one full set of
submissions, host-adjustable) that person is eliminated. Places are handed out
from the bottom: whoever goes out first takes the last place, so the person
still standing at the end holds place 1.

Pure computation lives in :func:`build_board`; :func:`board` is the DB-backed
wrapper. Unrated OSTs have no rank, so they sit outside the slices entirely —
they still count toward a person's standing submissions.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

from ost_tracker.config import SUBMISSIONS_PER_PERSON
from ost_tracker.db import ost_repo, settings_repo
from ost_tracker.db.models import OstStats

THRESHOLD_KEY = "elimination_threshold"

SLICE_SIZE = 10
DEFAULT_THRESHOLD = SUBMISSIONS_PER_PERSON
MIN_THRESHOLD = 1
MAX_THRESHOLD = 20


@dataclass(frozen=True)
class SliceTally:
    """One person's standing as of a single slice. ``out_here`` is what this
    slice cost them; ``total_out`` is cumulative from the bottom slice up."""

    person_id: int
    name: str
    out_here: int
    total_out: int
    remaining: int
    eliminated_here: bool


@dataclass(frozen=True)
class RankSlice:
    """A band of ranks, worst-first. ``index`` is 1-based over the reveal order
    (slice 1 is the bottom of the table)."""

    index: int
    bottom_rank: int   # worst rank in the band (e.g. 50)
    top_rank: int      # best rank in the band (e.g. 41)
    label: str         # "50–41"
    ost_ids: list[int]  # worst rank first
    tallies: list[SliceTally]


@dataclass(frozen=True)
class Elimination:
    """A knocked-out person and the place they finished in."""

    person_id: int
    name: str
    place: int          # 1 = best; counted down from the field size
    slice_index: int    # the slice that finished them
    out_at_rank: int    # rank of the OST that took them to the threshold
    total_out: int      # out-count at the moment of elimination


@dataclass(frozen=True)
class Survivor:
    """Someone who never reached the threshold. Ordered strongest first."""

    person_id: int
    name: str
    total_out: int
    remaining: int


@dataclass(frozen=True)
class EliminationBoard:
    threshold: int
    slice_size: int
    ranked_count: int
    slices: list[RankSlice]
    eliminated: list[Elimination]   # best place first
    survivors: list[Survivor]


# --- persisted threshold -----------------------------------------------------


def get_threshold() -> int:
    """How many OSTs a person may lose before elimination (persisted, clamped
    to [MIN_THRESHOLD, MAX_THRESHOLD]); defaults to one full set of submissions."""
    raw = settings_repo.get_setting(THRESHOLD_KEY)
    if raw is None:
        return DEFAULT_THRESHOLD
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_THRESHOLD
    return max(MIN_THRESHOLD, min(MAX_THRESHOLD, n))


def set_threshold(n: int) -> None:
    if not isinstance(n, int) or n < MIN_THRESHOLD or n > MAX_THRESHOLD:
        raise ValueError(
            f"elimination threshold must be between {MIN_THRESHOLD} and {MAX_THRESHOLD}"
        )
    settings_repo.set_setting(THRESHOLD_KEY, str(n))


# --- computation -------------------------------------------------------------


def _submission_counts(stats: Sequence[OstStats]) -> dict[int, int]:
    """person -> how many OSTs they submitted (rated or not)."""
    counts: dict[int, int] = {}
    for s in stats:
        sid = s.ost.submitter_id
        if sid is not None:
            counts[sid] = counts.get(sid, 0) + 1
    return counts


def _names(stats: Sequence[OstStats]) -> dict[int, str]:
    return {
        s.ost.submitter_id: s.ost.submitter_name or f"#{s.ost.submitter_id}"
        for s in stats
        if s.ost.submitter_id is not None
    }


def _chunks(ranked_desc: list[OstStats], slice_size: int) -> list[list[OstStats]]:
    return [
        ranked_desc[start : start + slice_size]
        for start in range(0, len(ranked_desc), slice_size)
    ]


def build_board(
    stats: Sequence[OstStats],
    threshold: int,
    slice_size: int = SLICE_SIZE,
) -> EliminationBoard:
    """Pure: turn ranked OSTs into slices, tallies and placements.

    Walks the ranking worst-first. Each OST knocks one off its submitter's
    standing; crossing ``threshold`` eliminates them at that exact rank, which
    is what orders the placements (earliest out = last place).
    """
    ranked_desc = sorted(
        (s for s in stats if s.rank is not None), key=lambda s: s.rank, reverse=True
    )
    submissions = _submission_counts(stats)
    names = _names(stats)
    field_size = len(submissions)

    total_out: dict[int, int] = {}
    eliminated_at: dict[int, int] = {}   # person -> slice index they went out in
    eliminations: list[Elimination] = []
    slices: list[RankSlice] = []

    for slice_index, chunk in enumerate(_chunks(ranked_desc, slice_size), start=1):
        standing = [pid for pid in submissions if pid not in eliminated_at]
        out_here: dict[int, int] = {}
        knocked_out_here: set[int] = set()

        for entry in chunk:
            pid = entry.ost.submitter_id
            if pid is None:
                continue   # an unattributed OST still falls, it just tallies nowhere
            out_here[pid] = out_here.get(pid, 0) + 1
            total_out[pid] = total_out.get(pid, 0) + 1
            if total_out[pid] >= threshold and pid not in eliminated_at:
                eliminated_at[pid] = slice_index
                knocked_out_here.add(pid)
                eliminations.append(
                    Elimination(
                        person_id=pid,
                        name=names.get(pid, f"#{pid}"),
                        # Places are filled from the bottom of the field up, so
                        # the first person out takes the last place.
                        place=field_size - len(eliminations),
                        slice_index=slice_index,
                        out_at_rank=entry.rank,
                        total_out=total_out[pid],
                    )
                )

        tallies = [
            SliceTally(
                person_id=pid,
                name=names.get(pid, f"#{pid}"),
                out_here=out_here.get(pid, 0),
                total_out=total_out.get(pid, 0),
                remaining=max(0, submissions[pid] - total_out.get(pid, 0)),
                eliminated_here=pid in knocked_out_here,
            )
            for pid in standing
        ]
        tallies.sort(key=lambda t: (-t.total_out, -t.out_here, t.name.lower()))

        slices.append(
            RankSlice(
                index=slice_index,
                bottom_rank=chunk[0].rank,
                top_rank=chunk[-1].rank,
                label=f"{chunk[0].rank}–{chunk[-1].rank}",
                ost_ids=[s.ost.id for s in chunk],
                tallies=tallies,
            )
        )

    survivors = [
        Survivor(
            person_id=pid,
            name=names.get(pid, f"#{pid}"),
            total_out=total_out.get(pid, 0),
            remaining=max(0, count - total_out.get(pid, 0)),
        )
        for pid, count in submissions.items()
        if pid not in eliminated_at
    ]
    survivors.sort(key=lambda s: (s.total_out, -s.remaining, s.name.lower()))

    return EliminationBoard(
        threshold=threshold,
        slice_size=slice_size,
        ranked_count=len(ranked_desc),
        slices=slices,
        eliminated=sorted(eliminations, key=lambda e: e.place),
        survivors=survivors,
    )


def board() -> EliminationBoard:
    """The live board off the current leaderboard and persisted threshold."""
    return build_board(ost_repo.list_osts_with_stats(), get_threshold())
