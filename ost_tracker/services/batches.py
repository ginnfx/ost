"""Batch randomizer.

Splits every OST into a configurable number of sequential batches ("days") with
a private, stable ordering the host consults while raters only hear audio (OST
title/franchise stay obscured on their side).

Two OSTs are pinned by default in batch 1:

  - "At the Limit" (Metal Gear Solid: Peace Walker) -> Batch 1, OST 1
  - "Shining Star" (Marvel Rivals)                  -> Batch 1, OST 3

Pins are host-editable at runtime (any OST can be pinned): a pinned OST keeps
its slot through re-randomize and never gets shoved by a slide-in. The batch
count is a persisted setting (``batch_count``); the host can also hand-place
every OST via ``save_arrangement`` (drag-and-drop). All state lives in
``app_settings`` so it survives restarts.
"""

from __future__ import annotations

import json
import random
from datetime import datetime, timezone
from typing import Optional

from ost_tracker.db import ost_repo, settings_repo
from ost_tracker.db.models import Ost

_ASSIGNMENT_KEY = "batch_assignment"
_COUNT_KEY = "batch_count"
_PINS_KEY = "batch_pins"

DEFAULT_BATCH_COUNT = 3
_MIN_COUNT = 1
_MAX_COUNT = 8

# (0-based default slot within batch 1, title needle, source needle). Matching
# is a case-insensitive substring; the title is authoritative and the source
# only breaks ties — e.g. two Marvel Rivals tracks exist, but only "Shining
# Star" should pin. Used only to SEED the editable pin set on first run.
_PINS: list[tuple[int, str, str]] = [
    (0, "at the limit", "peace walker"),
    (2, "shining star", "marvel rivals"),
]


def _now_iso() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


# --- batch count -------------------------------------------------------------


def get_count() -> int:
    """Configured batch count (persisted, clamped to [1, 8]); default 3."""
    raw = settings_repo.get_setting(_COUNT_KEY)
    if raw is None:
        return DEFAULT_BATCH_COUNT
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_BATCH_COUNT
    return max(_MIN_COUNT, min(_MAX_COUNT, n))


def set_count(n: int) -> None:
    """Persist a new batch count and re-flow the CURRENT arrangement into the
    new sizes, preserving global order (so manual work isn't reshuffled away).
    No-op re-flow when nothing has been arranged yet."""
    if not isinstance(n, int) or n < _MIN_COUNT or n > _MAX_COUNT:
        raise ValueError(f"batch count must be between {_MIN_COUNT} and {_MAX_COUNT}")
    settings_repo.set_setting(_COUNT_KEY, str(n))
    payload = _load_payload()
    if payload is None:
        return
    flat = [oid for batch in payload.get("batches", []) for oid in batch]
    reflowed = _chunk(flat, batch_sizes(len(flat), n))
    _persist_ids(payload.get("generated_at") or _now_iso(), reflowed)


def batch_sizes(total: int, count: Optional[int] = None) -> list[int]:
    """Even split with the remainder dumped on the LAST batch, matching the
    host's intent (50 -> 16, 16, 18). Never negative."""
    if count is None:
        count = get_count()
    if count <= 0:
        return []
    base = total // count
    sizes = [base] * count
    sizes[-1] = total - base * (count - 1)
    return sizes


# --- pins --------------------------------------------------------------------


def _find_pin(osts: list[Ost], title_needle: str, source_needle: str) -> Optional[Ost]:
    title_needle = title_needle.lower()
    source_needle = source_needle.lower()
    matches = [o for o in osts if title_needle in (o.title or "").lower()]
    if not matches:
        return None
    # Prefer a title match whose source also matches; otherwise first title hit.
    for o in matches:
        if source_needle in (o.source or "").lower():
            return o
    return matches[0]


def _default_pin_positions(osts: list[Ost]) -> dict[int, tuple[int, int]]:
    """Needle-seeded default positions (batch 1) for the two competition pins."""
    positions: dict[int, tuple[int, int]] = {}
    for slot_idx, title_needle, source_needle in _PINS:
        found = _find_pin(osts, title_needle, source_needle)
        if found is not None and found.id not in positions:
            positions[found.id] = (0, slot_idx)
    return positions


def _load_pins() -> Optional[set[int]]:
    raw = settings_repo.get_setting(_PINS_KEY)
    if raw is None:
        return None  # unseeded — caller seeds from needles
    try:
        return set(json.loads(raw))
    except (ValueError, TypeError):
        return set()


def _store_pins(pins: set[int]) -> None:
    settings_repo.set_setting(_PINS_KEY, json.dumps(sorted(pins)))


def pinned_ids(osts: list[Ost]) -> set[int]:
    """Editable set of pinned OST ids. Seeds from the two default needle pins
    the first time it's read, then persists. Stale ids (deleted OSTs) are hidden
    but left in storage."""
    stored = _load_pins()
    live = {o.id for o in osts}
    if stored is not None:
        return {i for i in stored if i in live}
    seeded: set[int] = set(_default_pin_positions(osts).keys())
    _store_pins(seeded)
    return seeded


def set_pin(ost_id: int, pinned: bool) -> None:
    """Pin or unpin a single OST (drag-and-drop / context menu)."""
    if ost_repo.get_ost(ost_id) is None:
        raise ValueError(f"unknown OST id {ost_id}")
    pins = _load_pins()
    if pins is None:
        pins = pinned_ids(ost_repo.list_osts())  # seed defaults first
    if pinned:
        pins.add(ost_id)
    else:
        pins.discard(ost_id)
    _store_pins(pins)


# --- assignment building -----------------------------------------------------


def build_assignment(
    osts: list[Ost],
    pinned_positions: Optional[dict[int, tuple[int, int]]] = None,
    rng: Optional[random.Random] = None,
) -> list[list[Ost]]:
    """Pure: lay ``osts`` into ``get_count()`` batches. Each id in
    ``pinned_positions`` is dropped at its fixed (batch, slot); an unplaceable
    pin (slot out of range or taken) falls back into the shuffle pool so it's
    never lost. Deterministic when ``rng`` is seeded."""
    shuffler = rng or random
    sizes = batch_sizes(len(osts))
    pinned_positions = pinned_positions or {}
    by_id = {o.id: o for o in osts}

    grid: list[list[Optional[Ost]]] = [[None] * size for size in sizes]
    reserved: set[int] = set()
    for oid, (bi, si) in pinned_positions.items():
        if oid in by_id and 0 <= bi < len(sizes) and 0 <= si < sizes[bi] and grid[bi][si] is None:
            grid[bi][si] = by_id[oid]
            reserved.add(oid)

    pool = [o for o in osts if o.id not in reserved]
    shuffler.shuffle(pool)
    for bi, batch in enumerate(grid):
        for si in range(len(batch)):
            if batch[si] is None:
                batch[si] = pool.pop(0)
    # Every slot is filled now (slot count == len(osts)); the casts are safe.
    return [[o for o in batch if o is not None] for batch in grid]


# Placement scoring weights (see `_placement_score`). Saturation dominates so a
# new OST lands in the batch where its submitter is least represented.
_W_SATURATION = 3.0  # penalty per same-submitter OST already in the batch
_W_SPREAD = 1.0      # reward for distance to nearest same-submitter neighbour
_W_BALANCE = 0.5     # penalty per existing OST in the batch (keeps sizes even)
_SPREAD_CAP = 6      # far-enough neighbours count the same as no neighbour


def _placement_score(batch: list[Ost], pos: int, ost: Ost, rng: random.Random) -> float:
    """How good it is to insert `ost` at index `pos` of `batch`. Higher = better.
    Rewards keeping same-submitter OSTs apart and batches evenly sized."""
    sub = ost.submitter_id
    same = [i for i, o in enumerate(batch) if sub is not None and o.submitter_id == sub]
    if same:
        # After inserting at `pos`, an existing item at i shifts to i+1 when i>=pos.
        nearest = min((i + 1 - pos) if i >= pos else (pos - i) for i in same)
    else:
        nearest = _SPREAD_CAP
    spread = min(nearest, _SPREAD_CAP)
    return (
        -_W_SATURATION * len(same)
        + _W_SPREAD * spread
        - _W_BALANCE * len(batch)
        + rng.random() * 0.4  # tie-break jitter so equal spots vary
    )


def slide_in(
    batches: list[list[Ost]],
    new_osts: list[Ost],
    pinned: Optional[set[int]] = None,
    rng: Optional[random.Random] = None,
) -> list[list[Ost]]:
    """Insert each new OST into its best position across the existing batches,
    spreading same-submitter OSTs apart and keeping batches balanced. Pinned
    OSTs are never shifted: within a batch, insertions only land after the last
    pinned slot."""
    shuffler = rng or random
    pinned = pinned or set()
    additions = list(new_osts)
    shuffler.shuffle(additions)  # so add-order (created_at) doesn't bias slots
    for ost in additions:
        best: Optional[tuple[float, int, int]] = None
        for batch_index, batch in enumerate(batches):
            pinned_idxs = [i for i, o in enumerate(batch) if o.id in pinned]
            # Inserting at pos shifts every item at index >= pos; to leave every
            # pinned slot untouched, start just past the last pinned index.
            start = (max(pinned_idxs) + 1) if pinned_idxs else 0
            for pos in range(start, len(batch) + 1):
                score = _placement_score(batch, pos, ost, shuffler)
                if best is None or score > best[0]:
                    best = (score, batch_index, pos)
        if best is None:
            continue  # no batches to slide into
        _, batch_index, pos = best
        batches[batch_index].insert(pos, ost)
    return batches


# --- persistence -------------------------------------------------------------


def _persist_ids(generated_at: str, id_batches: list[list[int]]) -> None:
    settings_repo.set_setting(
        _ASSIGNMENT_KEY,
        json.dumps({"generated_at": generated_at, "batches": id_batches}),
    )


def _persist(generated_at: str, batches: list[list[Ost]]) -> None:
    _persist_ids(generated_at, [[o.id for o in batch] for batch in batches])


def _load_payload() -> Optional[dict]:
    raw = settings_repo.get_setting(_ASSIGNMENT_KEY)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


def _chunk(flat: list[int], sizes: list[int]) -> list[list[int]]:
    out: list[list[int]] = []
    idx = 0
    for size in sizes:
        out.append(flat[idx : idx + size])
        idx += size
    return out


def _current_positions(osts: list[Ost]) -> dict[int, tuple[int, int]]:
    """ost_id -> (batch_index, slot_index) from the stored arrangement."""
    payload = _load_payload()
    if payload is None:
        return {}
    live = {o.id for o in osts}
    positions: dict[int, tuple[int, int]] = {}
    for bi, batch in enumerate(payload.get("batches", [])):
        for si, oid in enumerate(batch):
            if oid in live:
                positions[oid] = (bi, si)
    return positions


# --- public operations -------------------------------------------------------


def save_arrangement(ordered_ids: list[list[int]]) -> None:
    """Persist a hand-placed arrangement (drag-and-drop). Rejects unknown or
    duplicated ids. Omitted OSTs are self-healed back in by ``current()`` on the
    next read, so a partial arrangement is tolerated (the UI always sends a full
    one). Keeps the existing generated-at stamp."""
    live = {o.id for o in ost_repo.list_osts()}
    seen: set[int] = set()
    for batch in ordered_ids:
        for oid in batch:
            if oid not in live:
                raise ValueError(f"unknown OST id {oid}")
            if oid in seen:
                raise ValueError(f"duplicate OST id {oid}")
            seen.add(oid)
    payload = _load_payload()
    generated_at = (payload or {}).get("generated_at") or _now_iso()
    _persist_ids(generated_at, ordered_ids)


def randomize() -> tuple[str, list[list[Ost]], set[int]]:
    """Build a fresh random assignment, keeping pinned OSTs in place (their
    current slot, or the default needle slot on a first run), persist it, and
    return (generated_at, batches, pinned_ids)."""
    osts = ost_repo.list_osts()
    pins = pinned_ids(osts)
    current_pos = _current_positions(osts)
    defaults = _default_pin_positions(osts)
    pinned_positions: dict[int, tuple[int, int]] = {}
    for oid in pins:
        pos = current_pos.get(oid, defaults.get(oid))
        if pos is not None:
            pinned_positions[oid] = pos
    batches = build_assignment(osts, pinned_positions)
    generated_at = _now_iso()
    _persist(generated_at, batches)
    return generated_at, batches, pins


def current() -> tuple[Optional[str], list[list[Ost]], set[int]]:
    """Load the stored assignment, resolving OST ids against the live table.

    Self-healing: OSTs deleted since the last save are dropped, and OSTs added
    since are slid into the existing batches (spread by submitter, pins never
    shifted). Any change is persisted so the arrangement stays stable on the
    next read. Returns (None, [], set()) when nothing has been arranged yet."""
    payload = _load_payload()
    if payload is None:
        return None, [], set()

    live = ost_repo.list_osts()
    by_id = {o.id: o for o in live}
    pins = pinned_ids(live)

    placed: set[int] = set()
    dropped = False
    batches: list[list[Ost]] = []
    for batch in payload.get("batches", []):
        resolved: list[Ost] = []
        for ost_id in batch:
            ost = by_id.get(ost_id)
            if ost is None:
                dropped = True
                continue
            resolved.append(ost)
            placed.add(ost_id)
        batches.append(resolved)

    new_osts = [o for o in live if o.id not in placed]
    generated_at = payload.get("generated_at")
    if new_osts and batches:
        slide_in(batches, new_osts, pinned=pins)
    if (new_osts and batches) or dropped:
        _persist(generated_at or _now_iso(), batches)
    return generated_at, batches, pins
