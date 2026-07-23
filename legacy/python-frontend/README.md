# Legacy — Python (PySide6) frontend

This directory is the **retired PySide6 desktop UI** for OST Tracker, archived
when the project moved to a native **SwiftUI** frontend (`OSTTracker/`) backed by
a Python FastAPI sidecar.

Nothing in here is built, shipped, imported by the backend, or covered by CI.
It's kept for reference and in case any UI behavior needs to be ported to Swift.

## Why it was archived

The frontend is now SwiftUI. The Python `ost_tracker` **domain layer**
(SQLite storage, competition rules, cover art, stats, locked-reveal, export,
playback) lives on at the repo root and is what the sidecar (`backend/api.py`)
delegates to. Only the **UI** — the PySide6/Qt presentation layer and its
UI-only tooling and tests — moved here. The domain layer was deliberately left
in place and is **not** duplicated in this folder.

## What's in here

```
main.py                         PyInstaller entry point → ost_tracker.ui.app:run
ost_tracker/
  __main__.py                   `python -m ost_tracker` → ost_tracker.ui.app:run
  ui/                           the entire PySide6 UI (windows, views, dialogs,
                                widgets, theme, animations, snapshotting)
  ui/archive/                   older UI experiments (bulk/matrix entry, etc.)
  assets/                       UI fonts (Chakra Petch, IBM Plex, JetBrains Mono)
                                and SVG icons — used only by the Qt UI
scripts/
  build_app.sh                  PyInstaller build of the old .app
  capture_screens.py            screenshot the PySide UI
  capture_evidence.py           screenshot evidence for the review gate
  kitchen_sink.py               render every widget for visual QA
  contact_sheet.py              tile screenshots into one review sheet
tests/                          14 GUI tests (pytest-qt / qtbot) for the PySide UI
```

The retired Qt runtime dependencies were `PySide6>=6.6` and `qtawesome>=1.3`
(removed from the project `requirements.txt`).

## Running it again (reference only)

The archived UI imports the live domain layer (`ost_tracker.db`, `.services`,
`.config`) that still lives at the repo root. Because `ost_tracker` is a regular
Python package (a single directory), the UI can't be imported while it sits under
`legacy/`. To run it, temporarily restore the UI into the root package:

```bash
cd <repo root>
pip install PySide6 qtawesome
cp -R legacy/python-frontend/ost_tracker/ui          ost_tracker/ui
cp    legacy/python-frontend/ost_tracker/__main__.py ost_tracker/__main__.py
cp -R legacy/python-frontend/ost_tracker/assets      ost_tracker/assets
python -m ost_tracker            # or: python legacy/python-frontend/main.py

# to re-archive, delete the copies you just restored:
rm -rf ost_tracker/ui ost_tracker/assets ost_tracker/__main__.py
```

The GUI tests here likewise expect `ost_tracker.ui` to be importable, so they
only run after the same restore, with `pytest-qt` installed.
