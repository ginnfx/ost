"""Export: standings ordering plus CSV/Markdown/HTML rendering. Notes must
never appear in standings. (PDF generation and file-dialog format detection
lived in the archived PySide UI; see legacy/python-frontend/.)"""

from __future__ import annotations

from ost_tracker.db import notes_repo, ost_repo, people_repo, rating_repo
from ost_tracker.services import export


def test_build_standings_orders_rated_first(fresh_db):
    a = people_repo.add_person("Alice")
    b = people_repo.add_person("Bob")
    low = ost_repo.add_ost("Low", "G", a.id)
    high = ost_repo.add_ost("High", "G", b.id)
    ost_repo.add_ost("Unrated", "G", None)  # no submitter -> stays unrated
    rating_repo.upsert_rating(low, a.id, 2)
    rating_repo.upsert_rating(high, a.id, 9)

    standings = export.build_standings()
    assert standings[0].title == "High" and standings[0].rank == 1
    assert standings[1].title == "Low" and standings[1].rank == 2
    assert standings[2].title == "Unrated" and standings[2].rank is None


def test_csv_has_header_and_rows(fresh_db):
    a = people_repo.add_person("Alice")
    oid = ost_repo.add_ost("Song", "G", a.id)
    rating_repo.upsert_rating(oid, a.id, 7)
    csv_text = export.to_csv(export.build_standings())
    lines = csv_text.strip().splitlines()
    assert lines[0].startswith("Rank,Title,Submitter,Average,Spread")
    assert "Song" in lines[1]
    assert "Alice" in lines[1]


def test_markdown_is_a_table(fresh_db):
    a = people_repo.add_person("Alice")
    ost_repo.add_ost("Song", "G", a.id)
    md = export.to_markdown(export.build_standings())
    assert md.startswith("| Rank | Title |")
    assert "| --- |" in md


def test_html_escapes_and_tables(fresh_db):
    a = people_repo.add_person("Alice")
    ost_repo.add_ost("Rock & <Roll>", "G", a.id)
    html = export.to_html(export.build_standings())
    assert "<table" in html
    assert "Rock &amp; &lt;Roll&gt;" in html


def test_notes_never_leak_into_standings(fresh_db):
    people_repo.add_person("Alice")
    notes_repo.add_note("Secret idea", "should not appear")
    standings = export.build_standings()
    assert all("Secret idea" != s.title for s in standings)
    assert len(standings) == 0  # only a note exists, no OSTs
