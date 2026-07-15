"""Filesystem paths and app-wide constants.

All persistent state (SQLite DB, cached cover art) lives under the macOS
Application Support directory, never next to the executable. This keeps a
packaged ``.app`` bundle read-only and the user's data safe across updates.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

APP_FOLDER_NAME = "ost-tracker"

# Competition shape. These are the expected totals, used for progress readouts
# and the "all cells filled" auto-reveal condition. They are not hard limits —
# the app degrades gracefully if the real counts differ.
EXPECTED_PEOPLE = 10
EXPECTED_OSTS = 50
SUBMISSIONS_PER_PERSON = 5

MIN_SCORE = 0
MAX_SCORE = 10

# A submitter is treated as loving their own pick: on OST creation we seed a
# rating from the submitter to themselves at this score. It counts toward the
# average like any other rating but is surfaced as a "self-rating" in the UI and
# excluded from the unrated queues (you never score your own submission).
SELF_RATING_SCORE = MAX_SCORE

# Cover art render size (logical px). Cached files are stored at 2x for Retina.
COVER_RENDER_SIZE = 300
COVER_STORE_SIZE = 600


def app_support_dir() -> Path:
    """Return (creating if needed) the app's Application Support directory.

    Honours ``OST_TRACKER_HOME`` so tests and dev runs can redirect all state
    to a scratch directory without touching the real user data.
    """
    override = os.environ.get("OST_TRACKER_HOME")
    if override:
        base = Path(override).expanduser()
    else:
        base = Path.home() / "Library" / "Application Support" / APP_FOLDER_NAME
    base.mkdir(parents=True, exist_ok=True)
    return base


def database_path() -> Path:
    return app_support_dir() / "ost.db"


def covers_dir() -> Path:
    d = app_support_dir() / "covers"
    d.mkdir(parents=True, exist_ok=True)
    return d


def exports_dir() -> Path:
    d = app_support_dir() / "exports"
    d.mkdir(parents=True, exist_ok=True)
    return d


# --- user config (config.json) ----------------------------------------------
#
# App preferences that aren't competition data live in a small JSON file next to
# the database. Secrets like the Bing key are stored here, never hardcoded. The
# file is optional: a missing/corrupt file just means "no config yet".

BING_API_KEY = "bing_image_search_api_key"
SPOTIFY_CLIENT_ID = "spotify_client_id"
SPOTIFY_CLIENT_SECRET = "spotify_client_secret"


def config_file_path() -> Path:
    return app_support_dir() / "config.json"


def load_config() -> dict:
    p = config_file_path()
    if p.exists():
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (ValueError, OSError):
            return {}
    return {}


def save_config(cfg: dict) -> None:
    config_file_path().write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def get_bing_api_key() -> Optional[str]:
    """The configured Bing Image Search key, or None if unset/blank."""
    key = load_config().get(BING_API_KEY)
    return key.strip() if isinstance(key, str) and key.strip() else None


def set_bing_api_key(key: Optional[str]) -> None:
    """Persist (or clear, if blank) the Bing Image Search key in config.json."""
    cfg = load_config()
    if key and key.strip():
        cfg[BING_API_KEY] = key.strip()
    else:
        cfg.pop(BING_API_KEY, None)
    save_config(cfg)


def get_spotify_credentials() -> Optional[tuple[str, str]]:
    """(client_id, client_secret) for Spotify's Client Credentials flow —
    metadata search only, no user auth or playback. None unless both are set."""
    cfg = load_config()
    client_id = cfg.get(SPOTIFY_CLIENT_ID)
    client_secret = cfg.get(SPOTIFY_CLIENT_SECRET)
    if (
        isinstance(client_id, str) and client_id.strip()
        and isinstance(client_secret, str) and client_secret.strip()
    ):
        return client_id.strip(), client_secret.strip()
    return None


def set_spotify_credentials(client_id: Optional[str], client_secret: Optional[str]) -> None:
    """Persist (or clear, if blank) the Spotify API credentials in config.json."""
    cfg = load_config()
    for key, value in ((SPOTIFY_CLIENT_ID, client_id), (SPOTIFY_CLIENT_SECRET, client_secret)):
        if value and value.strip():
            cfg[key] = value.strip()
        else:
            cfg.pop(key, None)
    save_config(cfg)
