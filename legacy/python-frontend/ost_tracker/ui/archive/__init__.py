"""ARCHIVED SCREENS — not reachable from the UI. Do not wire these back in.

Retired in the 2026-07 IA simplification patch:

* ``rate_screen`` / ``bulk_entry`` / ``matrix_entry`` — the Rate tab's batch
  entry modes. Single-track rating now happens through Quick Rate (card click)
  and the detail view's inline rating strip. Kept because spreadsheet-style
  bulk entry is meaningfully faster for initial data population (entering all
  ~500 scores at once); revive deliberately if a new competition needs it.
* ``stats_view`` — the Stats tab. Per-OST stats live on the detail view;
  per-rater leniency moved to the People screen.

These modules still import and their tests still run, so they stay healthy
enough to resurrect, but nothing in the live app may depend on them.
"""
