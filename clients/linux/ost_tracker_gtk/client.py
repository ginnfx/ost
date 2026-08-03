"""Thin HTTP + WebSocket client for the sidecar (delegation only)."""
from __future__ import annotations

import json
import threading
from typing import Any, Callable, Optional

import httpx

from . import models


class ApiError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


class Client:
    """Sync HTTP wrapper. All calls are small and localhost-fast."""

    def __init__(self, port: int, token: str):
        self._http = httpx.Client(base_url=f"http://127.0.0.1:{port}", timeout=20.0)
        self._http.headers["X-OST-Token"] = token

    def close(self) -> None:
        self._http.close()

    # --- helpers ----------------------------------------------------------------

    def _get(self, path: str, **params: Any):
        return self._request("GET", path, params=params)

    def _send(self, method: str, path: str, body: Optional[dict] = None):
        return self._request(method, path, json=body)

    def _request(self, method: str, path: str, params=None, json=None):
        resp = self._http.request(method, path, params=params, json=json)
        if resp.status_code >= 400:
            detail = ""
            try:
                detail = resp.json().get("detail", "")
            except ValueError:
                pass
            raise ApiError(resp.status_code, str(detail))
        if resp.status_code == 204 or not resp.content:
            return None
        return resp.json()

    # --- people -----------------------------------------------------------------

    def get_people(self) -> list[models.Person]:
        return [models.Person(**p) for p in self._get("people")]

    def add_person(self, name: str) -> models.Person:
        return models.Person(**self._send("POST", "people", {"name": name}))

    def delete_person(self, person_id: int) -> None:
        self._send("DELETE", f"people/{person_id}")

    # --- osts -------------------------------------------------------------------

    def get_osts(self) -> list[models.Ost]:
        return [models.Ost(**o) for o in self._get("osts")]

    # --- history ----------------------------------------------------------------

    def get_history(self) -> list[models.HistoryEntry]:
        return [models.HistoryEntry(**h) for h in self._get("history")]

    def history_matches(self, title: str = "", source: Optional[str] = None) -> list[models.HistoryEntry]:
        params = {"title": title}
        if source is not None:
            params["source"] = source
        return [models.HistoryEntry(**h) for h in self._get("history/matches", **params)]

    # --- ratings ----------------------------------------------------------------

    def get_ratings(self) -> list[models.Rating]:
        return [models.Rating(**r) for r in self._get("ratings")]

    def put_rating(self, ost_id: int, rater_id: int, score: Optional[float]) -> None:
        self._send("PUT", "ratings", {"ost_id": ost_id, "rater_id": rater_id, "score": score})

    # --- notes ------------------------------------------------------------------

    def get_notes(self) -> list[models.Note]:
        return [models.Note(**n) for n in self._get("notes")]

    def add_note(self, title: str, note: Optional[str]) -> models.Note:
        return models.Note(**self._send("POST", "notes", {"title": title, "note": note}))

    def patch_note(self, note_id: int, **fields) -> models.Note:
        return models.Note(**self._send("PATCH", f"notes/{note_id}", fields))

    def delete_note(self, note_id: int) -> None:
        self._send("DELETE", f"notes/{note_id}")

    # --- leaderboard / elimination ------------------------------------------------

    def get_leaderboard(self) -> list[models.RankEntry]:
        return [models.RankEntry(ost=models.Ost(**r["ost"]), **{k: v for k, v in r.items() if k != "ost"})
                for r in self._get("leaderboard")]

    def get_elimination(self) -> models.EliminationBoard:
        return models.EliminationBoard(
            **{k: v for k, v in self._get("elimination").items() if k in models.EliminationBoard.__dataclass_fields__}
        )

    def put_threshold(self, threshold: int) -> models.EliminationBoard:
        return models.EliminationBoard(**self._send("PUT", "elimination/threshold", {"threshold": threshold}))

    # --- batches -----------------------------------------------------------------

    def _parse_batches(self, data: dict) -> models.Batches:
        return models.Batches(
            generated_at=data.get("generated_at"),
            batches=[
                models.BatchGroup(
                    index=g["index"], day=g["day"],
                    slots=[models.BatchSlot(slot=s["slot"], pinned=s["pinned"],
                                            ost=models.Ost(**s["ost"])) for s in g["slots"]],
                )
                for g in data.get("batches", [])
            ],
        )

    def get_batches(self) -> models.Batches:
        return self._parse_batches(self._get("batches"))

    def randomize_batches(self) -> models.Batches:
        return self._parse_batches(self._send("POST", "batches/randomize"))

    def put_batch_count(self, count: int) -> models.Batches:
        return self._parse_batches(self._send("PUT", "batches/count", {"count": count}))

    # --- player ------------------------------------------------------------------

    def play(self, ost_id: int) -> models.PlaybackState:
        return models.PlaybackState(**self._send("POST", "player/play", {"ost_id": ost_id}))

    # --- covers ------------------------------------------------------------------

    def cover_candidates(self, ost_id: int) -> list[models.CoverCandidate]:
        return [models.CoverCandidate(**c) for c in self._get(f"osts/{ost_id}/cover/candidates")]

    def set_cover(self, ost_id: int, image_url: str) -> models.Ost:
        return models.Ost(**self._send("POST", f"osts/{ost_id}/cover", {"image_url": image_url}))


class WsPump:
    """Background /ws consumer: reconnects with backoff, dispatches envelopes."""

    def __init__(self, port: int, token: str, on_event: Callable[[str, Any], None]):
        self._uri = f"ws://127.0.0.1:{port}/ws"
        self._token = token
        self._on_event = on_event
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        import time

        from websockets.sync.client import connect

        delay = 0.5
        while not self._stop.is_set():
            try:
                with connect(self._uri, additional_headers={"X-OST-Token": self._token}) as ws:
                    for message in ws:
                        if self._stop.is_set():
                            return
                        # Reset the backoff only once traffic actually flows —
                        # a server that accepts then immediately drops must not
                        # keep us hammering at 0.5s.
                        delay = 0.5
                        try:
                            env = json.loads(message)
                            self._on_event(env.get("type", ""), env.get("payload"))
                        except (ValueError, AttributeError):
                            continue
            except Exception:
                pass  # dropped socket — back off and retry
            if self._stop.wait(delay):
                return
            delay = min(delay * 2, 10.0)
