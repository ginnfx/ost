"""Locked-reveal logic.

The leaderboard's scores and ranks stay hidden until the competition is either
fully entered (every rater has scored every OST) or the operator manually flips
the reveal switch. This makes the reveal feel like a deliberate moment rather
than something that gradually resolves as data trickles in.
"""

from __future__ import annotations

from ost_tracker.db import ost_repo, people_repo, rating_repo, settings_repo


def expected_cells() -> int:
    """Total (person, ost) pairs that would exist if everyone rated everything."""
    return people_repo.count_people() * ost_repo.count_osts()


def filled_cells() -> int:
    return rating_repo.total_ratings()


def is_complete() -> bool:
    """True when every rater has scored every OST (and there is data to speak of)."""
    total = expected_cells()
    return total > 0 and filled_cells() >= total


def is_manually_unlocked() -> bool:
    return settings_repo.get_bool(settings_repo.REVEAL_UNLOCKED, default=False)


def set_manually_unlocked(unlocked: bool) -> None:
    settings_repo.set_bool(settings_repo.REVEAL_UNLOCKED, unlocked)


def scores_visible() -> bool:
    """Whether the leaderboard may show scores and ranks right now."""
    return is_complete() or is_manually_unlocked()
