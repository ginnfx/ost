"""The sidecar must import and boot cleanly — the app spawns it and reads the
OSTTRACKER_READY handshake line, so an import-time error surfaces as an opaque
"exitedBeforeHandshake" with no traceback in the UI. This test keeps the
module importable and the lifespan startup reachable."""

from __future__ import annotations

import asyncio


def test_sidecar_imports_and_boots(fresh_db, monkeypatch):
    monkeypatch.setenv("OST_API_TOKEN", "dev")
    # The watchdog thread must not outlive the test: a stray daemon thread at
    # interpreter shutdown crashes pytest on Windows (exit 1 after a clean
    # summary). The production app spawns it via the real lifespan.
    monkeypatch.setenv("OST_API_WATCHDOG", "0")
    import backend.api as api  # noqa: F401 — import must not raise

    # The lifespan startup path (portable import swap + migrations) must not
    # throw against a fresh DB either.
    async def boot():
        async with api._lifespan(api.app):
            pass

    asyncio.run(boot())
