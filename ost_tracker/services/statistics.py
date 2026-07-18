"""Pure statistical helpers. No I/O, no DB — trivially unit-testable.

Kept separate from the repositories so the "how to compute a spread" decision
lives in exactly one place and both the grid and the detail view agree.
"""

from __future__ import annotations

import math
from typing import Optional, Sequence


def mean(values: Sequence[float]) -> Optional[float]:
    if not values:
        return None
    return sum(values) / len(values)


def population_stddev(values: Sequence[float]) -> Optional[float]:
    """Population standard deviation. Returns 0.0 for a single value, None for
    no values. Population (not sample) is correct here: we have every rating
    that exists for the OST, not a sample of a larger set."""
    if not values:
        return None
    if len(values) == 1:
        return 0.0
    mu = mean(values)
    variance = sum((v - mu) ** 2 for v in values) / len(values)
    return math.sqrt(variance)


def format_score(value: float) -> str:
    """Render a score without a spurious decimal: 7.0 → ``7``, 8.66 → ``8.66``."""
    return f"{value:g}"


def spread_label(minimum: Optional[float], maximum: Optional[float]) -> str:
    """Human-friendly min–max spread, e.g. ``3–10`` or ``3.5–9.5``."""
    if minimum is None or maximum is None:
        return "—"
    return f"{format_score(minimum)}–{format_score(maximum)}"
