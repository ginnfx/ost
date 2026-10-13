"""Atomic retirement and restoration of the live competition."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from ost_tracker.db.connection import get_db
from ost_tracker.db import settings_repo
from ost_tracker.db.ost_repo import CURRENT_RANKING_LABEL, current_ranking_label

ROUND_SETTING_KEYS = (
    "reveal_unlocked", "batch_assignment", "batch_pins", "batch_count",
    settings_repo.ACTIVE_ROUND_NAME, settings_repo.ROUND_STATE,
)


def round_status() -> dict:
    count = active_ost_count()
    state = settings_repo.get_setting(settings_repo.ROUND_STATE)
    needs_start = count == 0 and state != "active"
    return {
        "active_ost_count": count,
        "current_name": current_ranking_label() if not needs_start else None,
        "needs_start": needs_start,
        "archives": list_rounds(),
    }


def start_round(name: str) -> dict:
    name = name.strip()
    if not name or len(name) > 80 or name.casefold() == CURRENT_RANKING_LABEL.casefold():
        raise ValueError("Choose a ranking name between 1 and 80 characters; Current Ranking is reserved.")
    with get_db().transaction() as conn:
        if conn.execute("SELECT 1 FROM osts LIMIT 1").fetchone():
            raise ValueError("Retire the current rating before starting another one.")
        if conn.execute(
            "SELECT 1 FROM ost_history WHERE LOWER(TRIM(batch_label)) = LOWER(?) LIMIT 1", (name,)
        ).fetchone():
            raise ValueError("A history ranking already has that name.")
        conn.execute(
            "INSERT INTO app_settings (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (settings_repo.ACTIVE_ROUND_NAME, name),
        )
        conn.execute(
            "INSERT INTO app_settings (key, value) VALUES (?, 'active') ON CONFLICT(key) DO UPDATE SET value = 'active'",
            (settings_repo.ROUND_STATE,),
        )
    return round_status()


def list_rounds() -> list[dict]:
    rows = get_db().query(
        "SELECT id, retired_at, ost_count, restored_at, name, payload FROM retired_rounds ORDER BY id DESC"
    )
    result = []
    for row in rows:
        item = {key: row[key] for key in ("id", "retired_at", "ost_count", "restored_at", "name")}
        if not item["name"]:
            payload = json.loads(row["payload"])
            history_ids = payload.get("changed_history", []) + payload.get("created_history", [])
            if history_ids:
                item["name"] = get_db().scalar(
                    "SELECT batch_label FROM ost_history WHERE id = ?", (history_ids[0],)
                )
            item["name"] = item["name"] or f"Retired {row['retired_at']}"
        result.append(item)
    return result


def get_round_archive(round_id: int) -> dict | None:
    row = get_db().query_one(
        "SELECT id, retired_at, ost_count, restored_at, name, payload FROM retired_rounds WHERE id = ?",
        (round_id,),
    )
    if row is None:
        return None
    return {
        "id": row["id"],
        "retired_at": row["retired_at"],
        "ost_count": row["ost_count"],
        "restored_at": row["restored_at"],
        "name": row["name"] or f"Retired {row['retired_at']}",
        "payload_json": row["payload"],
    }


def active_ost_count() -> int:
    return int(get_db().scalar("SELECT COUNT(*) FROM osts") or 0)


def retire_round() -> dict:
    """Snapshot first, then move the roster into labeled history in one commit."""
    with get_db().transaction() as conn:
        osts = [dict(row) for row in conn.execute("SELECT * FROM osts ORDER BY id")]
        if not osts:
            raise ValueError("There are no active OSTs to retire.")
        ratings = [dict(row) for row in conn.execute("SELECT * FROM ratings ORDER BY id")]
        settings = [dict(row) for row in conn.execute(
            f"SELECT key, value FROM app_settings WHERE key IN ({','.join('?' for _ in ROUND_SETTING_KEYS)})",
            ROUND_SETTING_KEYS,
        )]
        active_label = current_ranking_label()
        current_history = [dict(row) for row in conn.execute(
            "SELECT id, title, source, batch_label, sender FROM ost_history WHERE batch_label = ? ORDER BY id",
            (active_label,),
        )]
        label = active_label if active_label != CURRENT_RANKING_LABEL else (
            "Retired " + datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        )
        changed_history: list[int] = []
        created_history: list[int] = []
        used: set[int] = set()
        for ost in osts:
            title = (ost["title"] or "").strip().casefold()
            source = (ost["source"] or "").strip().casefold()
            match = next((row for row in current_history
                          if row["id"] not in used
                          and (row["title"] or "").strip().casefold() == title
                          and (row["source"] or "").strip().casefold() == source), None)
            if match:
                used.add(match["id"])
                changed_history.append(match["id"])
                conn.execute("UPDATE ost_history SET batch_label = ? WHERE id = ?", (label, match["id"]))
            else:
                sender = conn.execute("SELECT name FROM people WHERE id = ?", (ost["submitter_id"],)).fetchone() if ost["submitter_id"] is not None else None
                cur = conn.execute(
                    "INSERT INTO ost_history (title, source, batch_label, sender) VALUES (?,?,?,?)",
                    (ost["title"], ost["source"], label, sender[0] if sender else None),
                )
                created_history.append(cur.lastrowid)
        payload = json.dumps({"osts": osts, "ratings": ratings, "settings": settings,
                              "changed_history": changed_history, "created_history": created_history},
                             default=str)
        cur = conn.execute("INSERT INTO retired_rounds (ost_count, payload, name) VALUES (?,?,?)", (len(osts), payload, label))
        conn.execute("DELETE FROM osts")  # ratings cascade; people and notes remain
        conn.executemany("DELETE FROM app_settings WHERE key = ?", [(key,) for key in ROUND_SETTING_KEYS])
        conn.execute("INSERT INTO app_settings (key, value) VALUES (?, 'retired')", (settings_repo.ROUND_STATE,))
        row = conn.execute("SELECT id, retired_at, ost_count, restored_at, name FROM retired_rounds WHERE id = ?", (cur.lastrowid,)).fetchone()
        return dict(row)


def rename_history_label(old_label: str, new_label: str) -> dict:
    """Rename one displayed history group and its related round archive."""
    old_label = old_label.strip()
    new_label = new_label.strip()
    if not old_label or not new_label or len(new_label) > 80:
        raise ValueError("Enter a ranking name between 1 and 80 characters.")
    if old_label == CURRENT_RANKING_LABEL or new_label.casefold() == CURRENT_RANKING_LABEL.casefold():
        raise ValueError("Current Ranking is reserved for the active rating.")
    with get_db().transaction() as conn:
        rows = conn.execute("SELECT id FROM ost_history WHERE batch_label = ?", (old_label,)).fetchall()
        if not rows:
            raise ValueError("That history ranking was not found.")
        if old_label != new_label and conn.execute(
            "SELECT 1 FROM ost_history WHERE LOWER(TRIM(batch_label)) = LOWER(?) LIMIT 1", (new_label,)
        ).fetchone():
            raise ValueError("Another history ranking already has that name.")
        ids = {row["id"] for row in rows}
        conn.execute("UPDATE ost_history SET batch_label = ? WHERE batch_label = ?", (new_label, old_label))
        active_name = conn.execute("SELECT value FROM app_settings WHERE key = ?", (settings_repo.ACTIVE_ROUND_NAME,)).fetchone()
        if active_name and active_name[0] == old_label:
            conn.execute("UPDATE app_settings SET value = ? WHERE key = ?", (new_label, settings_repo.ACTIVE_ROUND_NAME))
        for archive in conn.execute("SELECT id, payload FROM retired_rounds WHERE restored_at IS NULL"):
            payload = json.loads(archive["payload"])
            archive_ids = set(payload.get("changed_history", [])) | set(payload.get("created_history", []))
            if ids & archive_ids:
                saved_settings = [s for s in payload.get("settings", []) if s["key"] != settings_repo.ACTIVE_ROUND_NAME]
                saved_settings.append({"key": settings_repo.ACTIVE_ROUND_NAME, "value": new_label})
                payload["settings"] = saved_settings
                conn.execute("UPDATE retired_rounds SET name = ?, payload = ? WHERE id = ?",
                             (new_label, json.dumps(payload), archive["id"]))
        return {"label": new_label, "count": len(rows)}


def restore_round(round_id: int) -> dict:
    """Restore a saved round only into an empty live roster."""
    with get_db().transaction() as conn:
        row = conn.execute("SELECT * FROM retired_rounds WHERE id = ?", (round_id,)).fetchone()
        if row is None:
            raise ValueError("That retired round was not found.")
        if row["restored_at"] is not None:
            raise ValueError("That round has already been restored.")
        if conn.execute("SELECT 1 FROM osts LIMIT 1").fetchone():
            raise ValueError("Retire the current round before restoring an older one.")
        payload = json.loads(row["payload"])
        restore_name = next((s["value"] for s in payload.get("settings", [])
                             if s["key"] == settings_repo.ACTIVE_ROUND_NAME), CURRENT_RANKING_LABEL)
        ost_columns = ("id", "title", "source", "submitter_id", "cover_image_path", "cover_accent_hex",
                       "external_link", "playback_watch_url", "created_at")
        rating_columns = ("id", "ost_id", "rater_id", "score", "updated_at")
        for ost in payload["osts"]:
            conn.execute(
                f"INSERT INTO osts ({','.join(ost_columns)}) VALUES ({','.join('?' for _ in ost_columns)})",
                tuple(ost.get(key) for key in ost_columns),
            )
        for rating in payload["ratings"]:
            conn.execute(
                f"INSERT INTO ratings ({','.join(rating_columns)}) VALUES ({','.join('?' for _ in rating_columns)})",
                tuple(rating.get(key) for key in rating_columns),
            )
        conn.executemany("DELETE FROM app_settings WHERE key = ?", [(key,) for key in ROUND_SETTING_KEYS])
        for setting in payload["settings"]:
            conn.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?,?)", (setting["key"], setting["value"]))
        conn.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, 'active')", (settings_repo.ROUND_STATE,))
        for history_id in payload["changed_history"]:
            conn.execute("UPDATE ost_history SET batch_label = ? WHERE id = ?",
                         (restore_name, history_id))
        for history_id in payload["created_history"]:
            conn.execute("UPDATE ost_history SET batch_label = ? WHERE id = ?", (restore_name, history_id))
        conn.execute("UPDATE retired_rounds SET restored_at = CURRENT_TIMESTAMP WHERE id = ?", (round_id,))
        return {"id": round_id, "ost_count": row["ost_count"]}
