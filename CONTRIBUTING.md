# Contributing

Thanks for helping out. This is a small personal project, so a few ground
rules keep it manageable:

## Architecture rules

- **All business logic lives in Python** (`ost_tracker/`). The Swift, C# and
  GTK frontends are thin contract clients — they read state and send intents,
  they never compute ratings, ranks, batches or stats.
- **`shared/CONTRACT.md` is the wire spec.** Any endpoint or payload change
  must update the contract, the Pydantic models in `backend/api.py`, and the
  DTOs in each client (`OSTTracker/Sources/Networking/`,
  `clients/windows/OSTTracker/Networking/`, `clients/linux/ost_tracker_gtk/`).
- Wire keys are snake_case everywhere.

## Running the tests

```bash
python -m pytest tests              # domain/API suite (needs Python 3.11)
cd OSTTracker && xcodegen generate  # Swift project (macOS app)
```

The CI matrix (`pytest` on macOS/Windows/Linux, x64 + arm64) is the portability
gate — a change that breaks any platform is a regression.

## Adding a feature

1. Implement it in `ost_tracker/` (domain) + `backend/api.py` (endpoint) with tests.
2. Update `shared/CONTRACT.md`.
3. Mirror the endpoint in the three client layers.
4. Keep the audio-visualizer and platform-specific polish behind `#if os(...)`
   or the per-client folders — never regress an existing platform.
