# Contributing

Thanks for helping out. Its a small personal project so keep it simple.

## Ground rules

- All the logic lives in Python (`ost_tracker/`). The frontends (Swift, C#, GTK) just read state and send requests. They dont compute ratings, ranks, batches or stats.
- `shared/CONTRACT.md` is the spec for the wire format. If you change an endpoint or a payload, update it, the Pydantic models in `backend/api.py`, and the matching DTOs in all three clients (`OSTTracker/Sources/Networking/`, `clients/windows/OSTTracker/Networking/`, `clients/linux/ost_tracker_gtk/`).
- Wire keys are snake_case everywhere.

## Running the tests

```bash
python -m pytest tests              # domain/API suite (needs Python 3.11)
cd OSTTracker && xcodegen generate  # Swift project (macOS app)
```

The CI matrix runs pytest on macOS, Windows and Linux (x64 + arm64). If your change breaks one of them, fix it.

## Adding a feature

1. Implement it in `ost_tracker/` and add an endpoint in `backend/api.py` with tests.
2. Update `shared/CONTRACT.md`.
3. Mirror the endpoint in the three client layers.
4. Keep platform specific polish (visualizer, `#if os(...)` bits) in the right folder. Dont break a platform that already works.
