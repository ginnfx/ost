import json
from pathlib import Path

import pytest

from ost_tracker.services.competition_scoring import score_competition


FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "competition-web"
    / "fixtures"
    / "scoring.json"
)


@pytest.mark.parametrize(
    "case",
    json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"],
    ids=lambda case: case["name"],
)
def test_python_scorer_matches_shared_competition_fixture(case):
    actual = score_competition(case["input"])
    expected = case["expected"]
    assert actual["excludedRaters"] == expected["excludedRaters"]
    assert [entry["id"] for entry in actual["ranked"]] == expected["ranked"]
    assert [group["entryIds"] for group in actual["revealGroups"]] == expected["revealGroups"]
    assert all(group["entryIds"] for group in actual["revealGroups"])
