"""Integer-only scorer for the private OST competition API fixtures.

OSTTracker's local 0–10 personal ratings remain separate. This module mirrors
the competition site's 1–10 scoring rules for cross-platform parity checks.
"""

from __future__ import annotations

import hashlib
from functools import cmp_to_key
from typing import Any


def score_competition(input_data: dict[str, Any]) -> dict[str, Any]:
    seed = input_data.get("seed")
    batch_count = input_data.get("batchCount")
    reveal_group_count = input_data.get("revealGroupCount")
    if (
        not seed
        or not isinstance(batch_count, int)
        or isinstance(batch_count, bool)
        or batch_count < 1
        or not isinstance(reveal_group_count, int)
        or isinstance(reveal_group_count, bool)
        or reveal_group_count < 1
    ):
        raise ValueError("Invalid scoring configuration.")

    participants = {person["id"]: person for person in input_data["participants"]}
    entries = {entry["id"]: entry for entry in input_data["entries"]}
    required_batches = set(range(1, batch_count + 1))
    excluded_raters = sorted(
        person["id"]
        for person in input_data["participants"]
        if person["withdrawn"]
        or set(person["finalizedBatches"]) != required_batches
        or len(person["finalizedBatches"]) != batch_count
    )
    excluded = set(excluded_raters)
    by_entry: dict[str, dict[str, int]] = {}
    for rating in input_data["ratings"]:
        score = rating["score"]
        if not isinstance(score, int) or isinstance(score, bool) or not 1 <= score <= 10:
            raise ValueError("Ratings must be whole numbers from 1 to 10.")
        rater_id, entry_id = rating["raterId"], rating["entryId"]
        if rater_id not in participants or entry_id not in entries:
            raise ValueError("A rating refers to an unknown record.")
        if rater_id in excluded:
            continue
        ratings = by_entry.setdefault(entry_id, {})
        if rater_id in ratings:
            raise ValueError("Only one rating per rater and entry is allowed.")
        ratings[rater_id] = score

    raw: list[dict[str, Any]] = []
    for entry in input_data["entries"]:
        values = by_entry.setdefault(entry["id"], {})
        owner_id = entry["ownerId"]
        if owner_id in participants and owner_id not in excluded:
            values[owner_id] = 10
        scores = sorted(values.values())
        count = len(scores)
        total = sum(scores)
        median_twice = (
            0
            if count == 0
            else scores[count // 2] * 2
            if count % 2
            else scores[count // 2 - 1] + scores[count // 2]
        )
        sum_squares = sum(score * score for score in scores)
        raw.append(
            {
                "id": entry["id"],
                "sum": total,
                "count": count,
                "tens": sum(score == 10 for score in scores),
                "medianTwice": median_twice,
                "varianceNumerator": count * sum_squares - total * total,
                "varianceDenominator": max(1, count) ** 2,
            }
        )

    def compare(a: dict[str, Any], b: dict[str, Any]) -> int:
        mean_delta = a["sum"] * (b["count"] or 1) - b["sum"] * (a["count"] or 1)
        if mean_delta:
            return -1 if mean_delta > 0 else 1
        if a["tens"] != b["tens"]:
            return -1 if a["tens"] > b["tens"] else 1
        if a["medianTwice"] != b["medianTwice"]:
            return -1 if a["medianTwice"] > b["medianTwice"] else 1
        deviation_delta = (
            a["varianceNumerator"] * b["varianceDenominator"]
            - b["varianceNumerator"] * a["varianceDenominator"]
        )
        if deviation_delta:
            return -1 if deviation_delta < 0 else 1
        a_seed = hashlib.sha256(f"{seed}:{a['id']}".encode()).hexdigest()
        b_seed = hashlib.sha256(f"{seed}:{b['id']}".encode()).hexdigest()
        return (a_seed > b_seed) - (a_seed < b_seed)

    ordered = sorted(raw, key=cmp_to_key(compare))
    reveal_order = list(reversed(ordered))
    group_count = min(reveal_group_count, len(reveal_order))
    standard_size = len(reveal_order) // group_count if group_count else 0
    reveal_groups = []
    for group in range(1, group_count + 1):
        start = (group - 1) * standard_size
        end = len(reveal_order) if group == group_count else start + standard_size
        reveal_groups.append(
            {"number": group, "entryIds": [item["id"] for item in reveal_order[start:end]]}
        )
    group_by_entry = {
        entry_id: group["number"]
        for group in reveal_groups
        for entry_id in group["entryIds"]
    }

    ranked = []
    for rank, item in enumerate(ordered, start=1):
        count, total = item["count"], item["sum"]
        hundredths = (total * 100 + count // 2) // count if count else 0
        ranked.append(
            {
                **item,
                "mean": f"{hundredths // 100}.{hundredths % 100:02d}",
                "rank": rank,
                "revealGroup": group_by_entry.get(item["id"], 0),
            }
        )
    return {
        "ranked": ranked,
        "revealGroups": reveal_groups,
        "excludedRaters": excluded_raters,
    }
