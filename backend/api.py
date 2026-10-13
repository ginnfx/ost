"""FastAPI sidecar for the SwiftUI frontend.

Thin adapter only: every endpoint delegates to the existing ost_tracker
repositories/services. No rating math, no cover lookup, no yt-dlp handling
lives here — if the frontend needs something, it gets an endpoint that calls
the existing function.

Launch (production, spawned by the app):
    python backend/api.py
    -> binds 127.0.0.1:<ephemeral>, prints one handshake line on stdout:
       OSTTRACKER_READY port=<port> token=<secret>

Launch (dev, fixed port for UI work against --reload):
    OST_API_TOKEN=dev OST_API_PORT=8765 uvicorn backend.api:app --reload --port 8765

Every HTTP request and the /ws upgrade require the X-OST-Token header
(dev convenience: /ws also accepts ?token=). The process self-terminates
when its parent dies (ppid poll) so a crashed app never leaks a sidecar.
"""

from __future__ import annotations

import asyncio
import errno
import json
import logging
import os
import secrets
import socket
import sys
import tempfile
import threading
import time
import httpx
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

# User-writable package layer (packaged app only). The Swift host installs
# yt-dlp upgrades here — never inside the signed bundle — and this prepend
# makes the writable copy shadow the bundled fallback.
_writable_site = os.environ.get("OST_WRITABLE_SITE")
if _writable_site and os.path.isdir(_writable_site):
    sys.path.insert(0, _writable_site)

from fastapi import FastAPI, File, HTTPException, Query, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel
from starlette.background import BackgroundTask

from ost_tracker.db import history_repo, migrations, notes_repo, ost_repo, people_repo, rating_repo, rounds_repo, settings_repo
from ost_tracker.db.connection import get_db
from ost_tracker.db.models import HistoryEntry, Note, Ost, OstStats, Person, Rating
from ost_tracker.services import batches as batches_service
from ost_tracker.services import coverart
from ost_tracker.services import catalog_search
from ost_tracker.services import elimination as elimination_service
from ost_tracker.services import portable
from ost_tracker.services.link_resolver import resolve_playback
from ost_tracker.services import playback_cache
from ost_tracker import config as app_config

LAN_ENABLED = os.environ.get("OST_LAN_ENABLED") == "1"
LAN_PORT = 8765


def _lan_token() -> str:
    """Keep the pairing secret stable across Mac app launches and private to the user."""
    path = app_config.app_support_dir() / "lan-token"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, "w") as output:
            output.write(secrets.token_hex(32))
    token = path.read_text(encoding="ascii").strip()
    if len(token) != 64 or any(c not in "0123456789abcdef" for c in token):
        raise RuntimeError(f"Invalid LAN pairing token at {path}")
    return token


TOKEN = _lan_token() if LAN_ENABLED else (os.environ.get("OST_API_TOKEN") or secrets.token_hex(16))
_bound_port: Optional[int] = None  # set by __main__ before uvicorn runs
logger = logging.getLogger("ost_tracker.playback")


# --- wire models (mirror /shared/CONTRACT.md exactly) ------------------------


class PersonOut(BaseModel):
    id: int
    name: str


class PersonIn(BaseModel):
    name: str


class OstOut(BaseModel):
    id: int
    title: str
    source: Optional[str]
    submitter_id: Optional[int]
    submitter_name: Optional[str]
    cover_image_path: Optional[str]
    cover_accent_hex: Optional[str]
    external_link: Optional[str]
    created_at: str


class OstIn(BaseModel):
    title: str
    source: Optional[str] = None
    submitter_id: Optional[int] = None
    external_link: Optional[str] = None


class OstPatch(BaseModel):
    title: Optional[str] = None
    source: Optional[str] = None
    submitter_id: Optional[int] = None
    external_link: Optional[str] = None


class RetireConfirmIn(BaseModel):
    challenge_id: str
    word: str


class HistoryLabelRenameIn(BaseModel):
    old_label: str
    new_label: str


class StartRoundIn(BaseModel):
    name: str


class CoverCandidateOut(BaseModel):
    image_url: str
    thumb_url: str
    label: str
    source_name: str


class CoverSetIn(BaseModel):
    image_url: str


class RatingOut(BaseModel):
    ost_id: int
    rater_id: int
    rater_name: str
    score: float  # 0–10, any decimal (stored rounded to 2 places)
    updated_at: str


class RatingIn(BaseModel):
    ost_id: int
    rater_id: int
    score: Optional[float]  # 0–10, any decimal; null clears the cell


class BulkRatingsIn(BaseModel):
    ratings: list[RatingIn]


class NoteOut(BaseModel):
    id: int
    title: str
    note: str
    created_at: str
    source: Optional[str] = None
    artist: Optional[str] = None
    external_link: Optional[str] = None


class NoteIn(BaseModel):
    title: str
    note: str = ""
    source: Optional[str] = None
    artist: Optional[str] = None
    external_link: Optional[str] = None


class NotePatch(BaseModel):
    title: Optional[str] = None
    note: Optional[str] = None


class HistoryEntryOut(BaseModel):
    id: int
    title: str
    source: Optional[str]
    batch_label: Optional[str]
    sender: Optional[str]
    created_at: str


class BatchSlotOut(BaseModel):
    slot: int  # 1-based position within the batch (OST 1, OST 2, ...)
    ost: OstOut
    pinned: bool  # host-only flag: this slot is fixed, not shuffled


class BatchGroupOut(BaseModel):
    index: int  # 1-based batch number
    day: int  # which listening day this batch belongs to (mirrors index)
    slots: list[BatchSlotOut]


class BatchesOut(BaseModel):
    generated_at: Optional[str] = None
    batches: list[BatchGroupOut]


class BatchCountIn(BaseModel):
    count: int


class BatchArrangeIn(BaseModel):
    batches: list[list[int]]  # nested OST ids, host-ordered


class BatchPinIn(BaseModel):
    ost_id: int
    pinned: bool


class RankEntry(BaseModel):
    ost: OstOut
    rating_count: int
    average: Optional[float]
    minimum: Optional[float]
    maximum: Optional[float]
    stddev: Optional[float]
    rank: Optional[int]


class SliceTallyOut(BaseModel):
    person_id: int
    name: str
    out_here: int
    total_out: int
    remaining: int
    eliminated_here: bool


class RankSliceOut(BaseModel):
    index: int
    bottom_rank: int
    top_rank: int
    label: str
    ost_ids: list[int]
    tallies: list[SliceTallyOut]


class EliminationOut(BaseModel):
    person_id: int
    name: str
    place: int
    slice_index: int
    out_at_rank: int
    total_out: int


class SurvivorOut(BaseModel):
    person_id: int
    name: str
    total_out: int
    remaining: int


class EliminationBoardOut(BaseModel):
    threshold: int
    slice_size: int
    ranked_count: int
    slices: list[RankSliceOut]
    eliminated: list[EliminationOut]
    survivors: list[SurvivorOut]


class EliminationThresholdIn(BaseModel):
    threshold: int


class PlaybackState(BaseModel):
    status: str  # idle | resolving | playing | paused | stopped
    ost_id: Optional[int] = None
    stream_url: Optional[str] = None
    watch_url: Optional[str] = None
    position: float = 0.0


class SeekIn(BaseModel):
    position: float


class PlayIn(BaseModel):
    ost_id: int


def _iso(value) -> str:
    """SQLite TIMESTAMP columns decode to datetime under PARSE_DECLTYPES;
    the wire format is always an ISO-8601 UTC string."""
    if isinstance(value, datetime):
        return value.replace(microsecond=0).isoformat() + "Z"
    return str(value)


def _ost_out(o: Ost) -> OstOut:
    return OstOut(
        id=o.id, title=o.title, source=o.source,
        submitter_id=o.submitter_id, submitter_name=o.submitter_name,
        cover_image_path=o.cover_image_path, cover_accent_hex=o.cover_accent_hex,
        external_link=o.external_link, created_at=_iso(o.created_at),
    )


def _rank_entry(s: OstStats) -> RankEntry:
    return RankEntry(
        ost=_ost_out(s.ost), rating_count=s.rating_count, average=s.average,
        minimum=s.minimum, maximum=s.maximum, stddev=s.stddev, rank=s.rank,
    )


def _rating_out(r: Rating) -> RatingOut:
    return RatingOut(
        ost_id=r.ost_id, rater_id=r.rater_id, rater_name=r.rater_name,
        score=r.score, updated_at=_iso(r.updated_at),
    )


def _note_out(n: Note) -> NoteOut:
    return NoteOut(id=n.id, title=n.title, note=n.note, created_at=_iso(n.created_at),
                   source=n.source, artist=n.artist, external_link=n.external_link)


def _person_out(p: Person) -> PersonOut:
    return PersonOut(id=p.id, name=p.name)


def _history_entry_out(h: HistoryEntry) -> HistoryEntryOut:
    return HistoryEntryOut(
        id=h.id, title=h.title, source=h.source,
        batch_label=h.batch_label, sender=h.sender, created_at=_iso(h.created_at),
    )


def _batches_out(generated_at, batches, pinned) -> BatchesOut:
    groups = [
        BatchGroupOut(
            index=batch_index + 1,
            day=batch_index + 1,
            slots=[
                BatchSlotOut(slot=slot_index + 1, ost=_ost_out(o), pinned=o.id in pinned)
                for slot_index, o in enumerate(batch)
            ],
        )
        for batch_index, batch in enumerate(batches)
    ]
    return BatchesOut(generated_at=generated_at, batches=groups)


def _elimination_out(board: elimination_service.EliminationBoard) -> EliminationBoardOut:
    return EliminationBoardOut(
        threshold=board.threshold,
        slice_size=board.slice_size,
        ranked_count=board.ranked_count,
        slices=[
            RankSliceOut(
                index=s.index, bottom_rank=s.bottom_rank, top_rank=s.top_rank,
                label=s.label, ost_ids=s.ost_ids,
                tallies=[
                    SliceTallyOut(
                        person_id=t.person_id, name=t.name, out_here=t.out_here,
                        total_out=t.total_out, remaining=t.remaining,
                        eliminated_here=t.eliminated_here,
                    )
                    for t in s.tallies
                ],
            )
            for s in board.slices
        ],
        eliminated=[
            EliminationOut(
                person_id=e.person_id, name=e.name, place=e.place,
                slice_index=e.slice_index, out_at_rank=e.out_at_rank,
                total_out=e.total_out,
            )
            for e in board.eliminated
        ],
        survivors=[
            SurvivorOut(
                person_id=s.person_id, name=s.name,
                total_out=s.total_out, remaining=s.remaining,
            )
            for s in board.survivors
        ],
    )


# --- websocket hub -----------------------------------------------------------


class Hub:
    """Fan-out of {type, payload} envelopes to every connected /ws client.

    Broadcasts arrive from worker threads (resolution, cover fetch) and from
    endpoint threadpool threads, so delivery is marshalled onto the event loop
    captured at startup.
    """

    def __init__(self) -> None:
        self._clients: set[WebSocket] = set()
        self._lock = threading.Lock()
        self.loop: Optional[asyncio.AbstractEventLoop] = None

    def add(self, ws: WebSocket) -> None:
        with self._lock:
            self._clients.add(ws)

    def remove(self, ws: WebSocket) -> None:
        with self._lock:
            self._clients.discard(ws)

    def broadcast(self, type_: str, payload: object) -> None:
        """Thread-safe fire-and-forget broadcast."""
        if self.loop is None:
            return
        message = json.dumps({"type": type_, "payload": payload})
        self.loop.call_soon_threadsafe(self._send_all, message)

    def _send_all(self, message: str) -> None:
        with self._lock:
            clients = list(self._clients)
        for ws in clients:
            asyncio.ensure_future(self._send_one(ws, message))

    async def _send_one(self, ws: WebSocket, message: str) -> None:
        try:
            await ws.send_text(message)
        except Exception:
            self.remove(ws)


hub = Hub()


def _broadcast_leaderboard() -> None:
    """Coalesce leaderboard broadcasts.

    Bulk entry writes scores in bursts (up to hundreds per session), and
    recomputing + re-fanning the whole board on every write is wasted work on
    a slow CPU. A trailing timer fires one broadcast ~150ms after the last
    request, so a burst collapses into a single recompute.
    """
    global _leaderboard_due, _leaderboard_thread
    with _leaderboard_lock:
        _leaderboard_due = time.monotonic() + _BROADCAST_WINDOW
        if _leaderboard_thread is not None and _leaderboard_thread.is_alive():
            return
        thread = threading.Thread(target=_leaderboard_worker, daemon=True)
        _leaderboard_thread = thread
        thread.start()


def _leaderboard_worker() -> None:
    global _leaderboard_due
    while True:
        with _leaderboard_lock:
            due = _leaderboard_due
        remaining = due - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
            continue
        with _leaderboard_lock:
            _leaderboard_due = 0.0
        payload = [_rank_entry(s).model_dump() for s in ost_repo.list_osts_with_stats()]
        hub.broadcast("leaderboardResorted", payload)
        return


_leaderboard_lock = threading.Lock()
_leaderboard_due = 0.0
_leaderboard_thread: Optional[threading.Thread] = None
_BROADCAST_WINDOW = 0.15


# --- resolution progress: tap the existing playback logger -------------------
#
# link_resolver.py already logs each pipeline step on "ost_tracker.playback".
# Observing those records maps 1:1 onto the contract's phases without touching
# the business logic. The handler runs in the emitting (worker) thread, so a
# threadlocal carries the OST id set by the worker that owns the resolution.

_resolving = threading.local()

_PHASE_BY_LOG_PREFIX = [
    ("search[youtube] started", "searchingYouTube"),
    ("search[spotify] started", "searchingSpotifyMeta"),
    ("search[bing] started", "searchingBing"),
    ("search winner", "extracting"),
]


class _PhaseTap(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        ost_id = getattr(_resolving, "ost_id", None)
        if ost_id is None:
            return
        message = record.getMessage()
        for prefix, phase in _PHASE_BY_LOG_PREFIX:
            if message.startswith(prefix):
                hub.broadcast("resolutionProgress", {"ost_id": ost_id, "phase": phase})
                return


logging.getLogger("ost_tracker.playback").addHandler(_PhaseTap())
logging.getLogger("ost_tracker.playback").setLevel(logging.INFO)


def _emit_phase(ost_id: int, phase: str) -> None:
    hub.broadcast("resolutionProgress", {"ost_id": ost_id, "phase": phase})


def _resolve_worker(ost: Ost, play: bool) -> None:
    """Runs the existing resolution pipeline on a worker thread, emitting
    resolutionProgress phases and (when ``play``) the final playbackState."""
    _resolving.ost_id = ost.id
    try:
        if play:
            cached_audio = playback_cache.cached_audio_url(ost)
            if cached_audio:
                _emit_phase(ost.id, "ready")
                _set_player(PlaybackState(
                    status="playing", ost_id=ost.id,
                    stream_url=cached_audio,
                    watch_url=ost_repo.get_playback_watch_url(ost.id),
                ))
                logger.info("started OST %s from local audio cache", ost.id)
                return
        _emit_phase(ost.id, "externalLink")
        cached = ost_repo.get_playback_watch_url(ost.id)
        result = resolve_playback(ost.title, ost.source, ost.external_link, cached)
        if result.watch_url and result.watch_url != cached:
            ost_repo.set_playback_watch_url(ost.id, result.watch_url)
        if result.stream_url:
            _emit_phase(ost.id, "ready")
            if play:
                playable_url = _register_player_stream(result.stream_url, result.stream_headers)
                _set_player(PlaybackState(
                    status="playing", ost_id=ost.id,
                    stream_url=playable_url, watch_url=result.watch_url,
                ))
                _spawn(playback_cache.cache_audio, ost, result.watch_url or result.fallback_link)
        else:
            _emit_phase(ost.id, "failed")
            if play:
                _set_player(PlaybackState(status="idle"))
    finally:
        _resolving.ost_id = None


# --- player state (canonical here; the Swift AVPlayer is only the audio sink)


_player = PlaybackState(status="idle")
_player_lock = threading.Lock()
_player_stream_sources: dict[str, tuple[str, dict[str, str]]] = {}
_player_stream_sources_lock = threading.Lock()


def _register_player_stream(url: str, headers: Optional[dict[str, str]]) -> str:
    """Expose yt-dlp media through localhost so its required headers are kept."""
    if _bound_port is None:
        return url
    stream_id = secrets.token_urlsafe(18)
    with _player_stream_sources_lock:
        if len(_player_stream_sources) >= 128:
            _player_stream_sources.pop(next(iter(_player_stream_sources)))
        _player_stream_sources[stream_id] = (url, dict(headers or {}))
    return f"http://127.0.0.1:{_bound_port}/player/audio/{stream_id}"


def _set_player(state: PlaybackState) -> None:
    global _player
    with _player_lock:
        _player = state
    hub.broadcast("playbackState", state.model_dump())


def _cover_worker(ost_id: int, title: str, source: Optional[str]) -> None:
    result = coverart.fetch_cover(ost_id, title, source)
    if not result.found:
        return
    ost_repo.set_cover(ost_id, str(result.path), result.accent_hex)
    fresh = ost_repo.get_ost(ost_id)
    if fresh:
        hub.broadcast("coverArtReady", {
            "ost_id": ost_id,
            "path": fresh.cover_image_path,
            "accent_hex": fresh.cover_accent_hex,
        })


def _spawn(target, *args) -> None:
    threading.Thread(target=target, args=args, daemon=True).start()


# --- app ----------------------------------------------------------------------


def _watchdog() -> None:
    """Exit when the parent process dies.

    POSIX: an orphan is re-parented (ppid changes away from the original
    parent), which the macOS/GTK hosts rely on. Windows: processes are not
    re-parented, so probe the recorded parent pid for existence instead; the
    WinUI host additionally enforces teardown with a Job Object, making this
    a second layer there.
    """
    import time

    parent = os.getppid()
    while True:
        time.sleep(1.0)
        if sys.platform == "win32":
            try:
                os.kill(parent, 0)
            except OSError as exc:
                # ESRCH (posix) / WinError 87 "invalid parameter" (win32)
                # mean the process is gone; EPERM / WinError 5 mean it is
                # still alive but not signalable.
                if getattr(exc, "winerror", None) == 87 or getattr(exc, "errno", None) == errno.ESRCH:
                    os._exit(0)
        elif os.getppid() != parent:
            os._exit(0)


@asynccontextmanager
async def _lifespan(app: FastAPI):
    hub.loop = asyncio.get_running_loop()
    # A staged portable import (see /import/portable) is swapped in before the
    # DB opens, so the running connection never fights the file.
    await asyncio.to_thread(portable.apply_staged_import)
    # Database is thread-safe (single connection, RLock-guarded, see
    # connection.py) — run off the loop so a first-launch backfill can't
    # freeze socket accept while it churns through history rows.
    await asyncio.to_thread(migrations.run_pending)
    if os.environ.get("OST_API_WATCHDOG", "1") != "0":
        _spawn(_watchdog)
    port = _bound_port or int(os.environ.get("OST_API_PORT", 0))
    print(f"OSTTRACKER_READY port={port} token={TOKEN}", flush=True)
    yield


app = FastAPI(title="OST Tracker sidecar", lifespan=_lifespan)


@app.middleware("http")
async def _require_token(request: Request, call_next):
    # AVPlayer cannot attach the sidecar auth header. Audio URLs include a
    # high-entropy per-play token, so only that endpoint is exempt.
    if request.url.path.startswith("/player/audio/"):
        return await call_next(request)
    if not secrets.compare_digest(request.headers.get("X-OST-Token") or "", TOKEN):
        return JSONResponse({"detail": "invalid token"}, status_code=401)
    return await call_next(request)


@app.exception_handler(ValueError)
async def _value_error(_request: Request, exc: ValueError):
    return JSONResponse({"detail": str(exc)}, status_code=400)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


_SYNC_TABLES = {
    "people": "id, name",
    "osts": "id, title, source, submitter_id, cover_accent_hex, external_link, playback_watch_url, created_at",
    "ratings": "id, ost_id, rater_id, score, updated_at",
    "notes": "id, title, note, source, artist, external_link, created_at",
    "ost_history": "id, title, source, batch_label, sender, created_at",
    "app_settings": "key, value",
    "retired_rounds": "id, retired_at, ost_count, payload, name, restored_at",
}


def _sync_snapshot() -> dict[str, Any]:
    db = get_db()
    tables = {
        name: [dict(row) for row in db.query(f"SELECT {columns} FROM {name}")]
        for name, columns in _SYNC_TABLES.items()
    }
    # Retired-round payloads contain full OST rows, including local cover
    # paths. Keep those paths on each device just like active OST artwork.
    for archive in tables["retired_rounds"]:
        archive["payload"] = _portable_round_payload(archive.get("payload"))
    return {
        "version": 1,
        "tables": tables,
    }


def _portable_round_payload(raw: Any) -> str | None:
    if raw is None:
        return None
    try:
        payload = json.loads(raw) if isinstance(raw, str) else raw
        for ost in payload.get("osts", []):
            if isinstance(ost, dict):
                ost.pop("cover_image_path", None)
        return json.dumps(payload, separators=(",", ":"), sort_keys=True)
    except (TypeError, ValueError, AttributeError):
        return raw if isinstance(raw, str) else json.dumps(raw, separators=(",", ":"), sort_keys=True)


@app.get("/sync/state")
def get_sync_state() -> dict[str, Any]:
    """Export portable competition data for the signed-in Supabase account."""
    return _sync_snapshot()


@app.put("/sync/state")
def put_sync_state(payload: dict[str, Any]) -> dict[str, str]:
    """Replace this device's portable data with a validated cloud snapshot."""
    if payload.get("version") != 1 or not isinstance(payload.get("tables"), dict):
        raise HTTPException(400, "Unsupported sync snapshot")
    tables = payload["tables"]
    if any(not isinstance(tables.get(name), list) for name in _SYNC_TABLES):
        raise HTTPException(400, "Sync snapshot is missing a data table")

    db = get_db()
    # Artwork paths are private to each device. Keep any local artwork already
    # cached for matching OST IDs, and never copy a Mac filesystem path to iOS.
    cover_paths = {
        row["id"]: row["cover_image_path"]
        for row in db.query("SELECT id, cover_image_path FROM osts")
    }
    for archive in db.query("SELECT payload FROM retired_rounds"):
        try:
            archived_osts = json.loads(archive["payload"]).get("osts", [])
            cover_paths.update({ost["id"]: ost["cover_image_path"] for ost in archived_osts
                                if ost.get("id") is not None and ost.get("cover_image_path")})
        except (TypeError, ValueError, AttributeError):
            continue
    columns = {
        "people": ("id", "name"),
        "osts": ("id", "title", "source", "submitter_id", "cover_image_path", "cover_accent_hex", "external_link", "playback_watch_url", "created_at"),
        "ratings": ("id", "ost_id", "rater_id", "score", "updated_at"),
        "notes": ("id", "title", "note", "source", "artist", "external_link", "created_at"),
        "ost_history": ("id", "title", "source", "batch_label", "sender", "created_at"),
        "app_settings": ("key", "value"),
        "retired_rounds": ("id", "retired_at", "ost_count", "payload", "name", "restored_at"),
    }
    with db.transaction() as conn:
        for table in ("ratings", "osts", "notes", "ost_history", "retired_rounds", "people", "app_settings"):
            conn.execute(f"DELETE FROM {table}")
        for table in ("people", "osts", "ratings", "notes", "ost_history", "app_settings", "retired_rounds"):
            names = columns[table]
            placeholders = ", ".join("?" for _ in names)
            statement = f"INSERT INTO {table} ({', '.join(names)}) VALUES ({placeholders})"
            rows = tables[table]
            if len(rows) > 20000:
                raise HTTPException(413, "Sync snapshot is too large")
            for row in rows:
                if not isinstance(row, dict):
                    raise HTTPException(400, "Invalid row in sync snapshot")
                if table == "osts":
                    row = {**row, "cover_image_path": cover_paths.get(row.get("id"))}
                elif table == "retired_rounds" and isinstance(row.get("payload"), str):
                    try:
                        archived_payload = json.loads(row["payload"])
                        for ost in archived_payload.get("osts", []):
                            if ost.get("id") in cover_paths:
                                ost["cover_image_path"] = cover_paths[ost["id"]]
                        row = {**row, "payload": json.dumps(archived_payload, separators=(",", ":"), sort_keys=True)}
                    except (TypeError, ValueError, AttributeError):
                        pass
                try:
                    values = [
                        row.get(column).replace("T", " ", 1)
                        if column.endswith("_at") and isinstance(row.get(column), str) and "T" in row[column]
                        else row.get(column)
                        for column in names
                    ]
                    conn.execute(statement, values)
                except Exception as exc:
                    raise HTTPException(400, f"Invalid {table} row: {exc}") from exc
    return {"status": "ok"}


@app.get("/covers/{ost_id}")
def get_cover(ost_id: int) -> FileResponse:
    """Send Mac-cached artwork to a paired iPhone without exposing file paths."""
    ost = ost_repo.get_ost(ost_id)
    expected = app_config.covers_dir() / f"cover_{ost_id}.jpg"
    if not ost or not ost.cover_image_path or Path(ost.cover_image_path) != expected or not expected.is_file():
        raise HTTPException(404, "Cover not found")
    return FileResponse(expected, media_type="image/jpeg")


# --- people -------------------------------------------------------------------


@app.get("/people")
def get_people() -> list[PersonOut]:
    return [_person_out(p) for p in people_repo.list_people()]


@app.post("/people", status_code=201)
def post_person(body: PersonIn) -> PersonOut:
    return _person_out(people_repo.add_person(body.name))


@app.delete("/people/{person_id}", status_code=204, response_model=None)
def delete_person(person_id: int) -> None:
    # FK cascade (schema): their ratings are deleted; their OSTs' submitter_id
    # is set NULL. The leaderboard then recomputes without them.
    if people_repo.get_person(person_id) is None:
        raise HTTPException(404, "Person not found")
    people_repo.delete_person(person_id)
    _broadcast_leaderboard()


# --- osts ---------------------------------------------------------------------


@app.get("/osts")
def get_osts() -> list[OstOut]:
    return [_ost_out(o) for o in ost_repo.list_osts()]


@app.post("/osts", status_code=201)
def post_ost(body: OstIn) -> OstOut:
    ost_id = ost_repo.add_ost(
        body.title, source=body.source,
        submitter_id=body.submitter_id, external_link=body.external_link,
    )
    created = ost_repo.get_ost(ost_id)
    if created is None:
        raise HTTPException(500, "OST was not created")
    _spawn(_cover_worker, ost_id, created.title, created.source)
    _broadcast_leaderboard()
    return _ost_out(created)


@app.patch("/osts/{ost_id}")
def patch_ost(ost_id: int, body: OstPatch) -> OstOut:
    current = ost_repo.get_ost(ost_id)
    if current is None:
        raise HTTPException(404, "OST not found")
    fields = body.model_dump(exclude_unset=True)
    ost_repo.update_ost(
        ost_id,
        title=fields.get("title", current.title),
        source=fields.get("source", current.source),
        submitter_id=fields.get("submitter_id", current.submitter_id),
        external_link=fields.get("external_link", current.external_link),
    )
    updated = ost_repo.get_ost(ost_id)
    if updated is None:
        raise HTTPException(500, "OST was not updated")
    _broadcast_leaderboard()
    return _ost_out(updated)


@app.delete("/osts/{ost_id}", status_code=204, response_model=None)
def delete_ost(ost_id: int) -> None:
    if ost_repo.get_ost(ost_id) is None:
        raise HTTPException(404, "OST not found")
    ost_repo.delete_ost(ost_id)
    _broadcast_leaderboard()


@app.post("/osts/{ost_id}/resolve", status_code=202)
def resolve_ost(ost_id: int) -> dict:
    ost = ost_repo.get_ost(ost_id)
    if ost is None:
        raise HTTPException(404, "OST not found")
    _spawn(_resolve_worker, ost, False)
    return {"started": True}


# --- history --------------------------------------------------------------------


@app.get("/history")
def get_history() -> list[HistoryEntryOut]:
    return [_history_entry_out(h) for h in history_repo.list_history()]


@app.get("/history/matches")
def get_history_matches(
    title: str = Query(""), source: Optional[str] = Query(None)
) -> list[HistoryEntryOut]:
    return [_history_entry_out(h) for h in history_repo.find_matches(title, source)]


@app.patch("/history/label")
def patch_history_label(body: HistoryLabelRenameIn) -> dict:
    return rounds_repo.rename_history_label(body.old_label, body.new_label)


# --- round retirement ---------------------------------------------------------

_retire_words = ("HARBOR", "LANTERN", "ORBIT", "MEADOW", "PAPER", "RIVER", "SUNSET", "WILLOW")
_retire_challenges: dict[str, tuple[str, float]] = {}
_retire_challenge_lock = threading.Lock()


@app.get("/rounds")
def get_rounds() -> dict:
    return rounds_repo.round_status()


@app.post("/rounds/start")
def post_start_round(body: StartRoundIn) -> dict:
    return rounds_repo.start_round(body.name)


@app.get("/rounds/retire-challenge")
def get_retire_challenge() -> dict:
    challenge_id = secrets.token_urlsafe(18)
    word = secrets.choice(_retire_words)
    with _retire_challenge_lock:
        _retire_challenges.clear()  # only the latest open confirmation can be used
        _retire_challenges[challenge_id] = (word, time.monotonic() + 300)
    return {"challenge_id": challenge_id, "word": word}


@app.post("/rounds/retire")
def post_retire_round(body: RetireConfirmIn) -> dict:
    with _retire_challenge_lock:
        challenge = _retire_challenges.pop(body.challenge_id, None)
    if challenge is None or time.monotonic() > challenge[1] or not secrets.compare_digest(body.word, challenge[0]):
        raise HTTPException(400, "Confirmation word was incorrect or expired.")
    retired = rounds_repo.retire_round()
    _set_player(PlaybackState(status="idle"))
    _broadcast_leaderboard()
    return retired


@app.post("/rounds/{round_id}/restore")
def post_restore_round(round_id: int) -> dict:
    restored = rounds_repo.restore_round(round_id)
    _broadcast_leaderboard()
    return restored


# --- covers -------------------------------------------------------------------


@app.get("/osts/{ost_id}/cover/candidates")
def cover_candidates(ost_id: int) -> list[CoverCandidateOut]:
    """Advanced cover changer: gather options from iTunes, MusicBrainz, the
    OST's own YouTube link, and a YouTube search so the user can pick one."""
    ost = ost_repo.get_ost(ost_id)
    if ost is None:
        raise HTTPException(404, "OST not found")
    candidates = coverart.search_candidates(ost.title, ost.source, ost.external_link)
    return [
        CoverCandidateOut(
            image_url=c.image_url, thumb_url=c.thumb_url,
            label=c.label, source_name=c.source_name,
        )
        for c in candidates
    ]


@app.post("/osts/{ost_id}/cover")
def set_ost_cover(ost_id: int, body: CoverSetIn) -> OstOut:
    """Apply a chosen cover (a candidate's image URL or a pasted URL). Downloads
    it, recomputes the accent, and broadcasts the change like the auto-fetch."""
    ost = ost_repo.get_ost(ost_id)
    if ost is None:
        raise HTTPException(404, "OST not found")
    result = coverart.import_cover_from_url(ost_id, body.image_url)
    if not result.found:
        raise HTTPException(422, "Could not download that image")
    ost_repo.set_cover(ost_id, str(result.path), result.accent_hex)
    fresh = ost_repo.get_ost(ost_id)
    if fresh is None:
        raise HTTPException(500, "OST was not updated")
    hub.broadcast("coverArtReady", {
        "ost_id": ost_id,
        "path": fresh.cover_image_path,
        "accent_hex": fresh.cover_accent_hex,
    })
    _broadcast_leaderboard()
    return _ost_out(fresh)


# --- ratings ------------------------------------------------------------------


@app.get("/ratings")
def get_ratings(rater_id: Optional[int] = Query(None)) -> list[RatingOut]:
    if rater_id is not None:
        return [_rating_out(r) for r in rating_repo.ratings_for_rater(rater_id)]
    return [_rating_out(r) for r in rating_repo.all_ratings()]


@app.post("/ratings/bulk")
def put_ratings_bulk(body: BulkRatingsIn) -> dict:
    """Apply many upserts/clears in one request (bulk entry). One transaction,
    one debounced leaderboard recompute — no per-row broadcast spam."""
    updates: list[tuple[int, int, float]] = []
    clears: list[tuple[int, int]] = []
    for r in body.ratings:
        if r.score is None:
            clears.append((r.ost_id, r.rater_id))
        else:
            updates.append((r.ost_id, r.rater_id, r.score))
    try:
        applied = rating_repo.bulk_apply(updates, clears)
    except ValueError as e:
        raise HTTPException(422, str(e))
    _broadcast_leaderboard()
    return {"applied": applied}


@app.put("/ratings")
def put_rating(body: RatingIn) -> dict:
    if body.score is None:
        rating_repo.delete_rating(body.ost_id, body.rater_id)
    else:
        try:
            rating_repo.upsert_rating(body.ost_id, body.rater_id, body.score)
        except ValueError as e:
            raise HTTPException(422, str(e))
    hub.broadcast("ratingUpdated", {
        "ost_id": body.ost_id, "rater_id": body.rater_id, "score": body.score,
    })
    _broadcast_leaderboard()
    return {"ost_id": body.ost_id, "rater_id": body.rater_id, "score": body.score}


# --- settings ------------------------------------------------------------------


class RevealIn(BaseModel):
    unlocked: bool


@app.get("/settings/reveal")
def get_reveal() -> dict:
    return {"unlocked": settings_repo.get_bool(settings_repo.REVEAL_UNLOCKED)}


@app.put("/settings/reveal")
def put_reveal(body: RevealIn) -> dict:
    settings_repo.set_bool(settings_repo.REVEAL_UNLOCKED, body.unlocked)
    hub.broadcast("revealState", {"unlocked": body.unlocked})
    return {"unlocked": body.unlocked}


# --- notes --------------------------------------------------------------------


@app.get("/notes")
def get_notes() -> list[NoteOut]:
    return [_note_out(n) for n in notes_repo.list_notes()]


@app.get("/notes/catalog-search")
def search_note_catalog(q: str = Query(min_length=3, max_length=120)) -> list[dict]:
    try:
        return catalog_search.search_tracks(q)
    except (httpx.HTTPError, ValueError):
        raise HTTPException(503, "Music catalog is temporarily unavailable.")


@app.post("/notes", status_code=201)
def post_note(body: NoteIn) -> NoteOut:
    return _note_out(notes_repo.add_note(body.title, body.note, body.source,
                                         body.artist, body.external_link))


@app.patch("/notes/{note_id}")
def patch_note(note_id: int, body: NotePatch) -> NoteOut:
    current = notes_repo.get_note(note_id)
    if current is None:
        raise HTTPException(404, "Note not found")
    fields = body.model_dump(exclude_unset=True)
    notes_repo.update_note(
        note_id,
        title=fields.get("title", current.title),
        note=fields.get("note", current.note),
    )
    updated = notes_repo.get_note(note_id)
    if updated is None:
        raise HTTPException(500, "Note was not updated")
    return _note_out(updated)


@app.delete("/notes/{note_id}", status_code=204, response_model=None)
def delete_note(note_id: int) -> None:
    if notes_repo.get_note(note_id) is None:
        raise HTTPException(404, "Note not found")
    notes_repo.delete_note(note_id)


# --- leaderboard ----------------------------------------------------------------


@app.get("/leaderboard")
def get_leaderboard() -> list[RankEntry]:
    return [_rank_entry(s) for s in ost_repo.list_osts_with_stats()]


# --- elimination ----------------------------------------------------------------


@app.get("/elimination")
def get_elimination() -> EliminationBoardOut:
    return _elimination_out(elimination_service.board())


@app.put("/elimination/threshold")
def put_elimination_threshold(body: EliminationThresholdIn) -> EliminationBoardOut:
    elimination_service.set_threshold(body.threshold)
    return _elimination_out(elimination_service.board())


# --- batches --------------------------------------------------------------------


@app.get("/batches")
def get_batches() -> BatchesOut:
    return _batches_out(*batches_service.current())


@app.post("/batches/randomize")
def post_randomize_batches() -> BatchesOut:
    return _batches_out(*batches_service.randomize())


@app.put("/batches/count")
def put_batch_count(body: BatchCountIn) -> BatchesOut:
    batches_service.set_count(body.count)
    return _batches_out(*batches_service.current())


@app.post("/batches/arrange")
def post_arrange_batches(body: BatchArrangeIn) -> BatchesOut:
    batches_service.save_arrangement(body.batches)
    return _batches_out(*batches_service.current())


@app.post("/batches/pin")
def post_pin_batch(body: BatchPinIn) -> BatchesOut:
    batches_service.set_pin(body.ost_id, body.pinned)
    return _batches_out(*batches_service.current())


# --- player ---------------------------------------------------------------------


@app.api_route("/player/audio/{stream_id}", methods=["GET", "HEAD"])
async def player_audio(stream_id: str, request: Request):
    """Range-capable local relay. AVPlayer cannot send yt-dlp's full headers."""
    with _player_stream_sources_lock:
        source = _player_stream_sources.get(stream_id)
    if source is None:
        raise HTTPException(404, "Audio stream expired. Play the OST again.")

    source_url, source_headers = source
    headers = dict(source_headers)
    headers["Accept-Encoding"] = "identity"
    client_range = None if request.method == "HEAD" else request.headers.get("range")
    range_start, requested_end = 0, None
    if client_range:
        unit, separator, span = client_range.partition("=")
        start, dash, end = span.partition("-")
        if not (separator and unit.lower() == "bytes" and dash and start.isdecimal()):
            raise HTTPException(416, "Unsupported audio byte range.")
        range_start = int(start)
        requested_end = int(end) if end.isdecimal() else None
    # This YouTube CDN URL permits 16 KiB nonzero ranges. Larger continuation
    # ranges return 403, which makes AVPlayer stop a few seconds into playback.
    chunk_size = 16_384
    first_end = min(requested_end, range_start + chunk_size - 1) if requested_end is not None else range_start + chunk_size - 1
    # YouTube rejects open-ended and very large ranges. Fetch bounded pieces,
    # then present AVPlayer with the exact range it requested.
    headers["Range"] = f"bytes={range_start}-{0 if request.method == 'HEAD' else first_end}"
    for name in ("range", "if-range", "if-modified-since", "if-none-match"):
        if name != "range" and (value := request.headers.get(name)):
            headers[name] = value

    client = httpx.AsyncClient(follow_redirects=True, timeout=httpx.Timeout(30, connect=10))
    try:
        upstream_request = client.build_request("GET", source_url, headers=headers)
        upstream = await client.send(upstream_request, stream=True)
    except httpx.HTTPError as exc:
        await client.aclose()
        raise HTTPException(502, "Audio source could not be reached.") from exc

    response_headers = {
        name: upstream.headers[name]
        for name in ("content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag")
        if name in upstream.headers
    }
    content_range = upstream.headers.get("content-range", "")
    try:
        delivered_span, total_text = content_range.removeprefix("bytes ").split("/", 1)
        delivered_start, delivered_end = map(int, delivered_span.split("-", 1))
        total_size = int(total_text)
    except (ValueError, TypeError):
        await upstream.aclose()
        await client.aclose()
        raise HTTPException(502, "Audio source returned invalid range metadata.")

    if request.method == "HEAD":
        await upstream.aclose()
        await client.aclose()
        response_headers.pop("content-range", None)
        response_headers["content-length"] = str(total_size)
        return Response(status_code=200, headers=response_headers)

    range_end = min(requested_end if requested_end is not None else total_size - 1, total_size - 1)
    segmented = range_start != delivered_start or range_end != delivered_end
    if segmented:
        response_headers["content-length"] = str(range_end - range_start + 1)
        if client_range:
            response_headers["content-range"] = f"bytes {range_start}-{range_end}/{total_size}"
        else:
            response_headers.pop("content-range", None)

    async def chunks():
        current = upstream
        cursor = delivered_end + 1
        try:
            while True:
                async for chunk in current.aiter_raw(64 * 1024):
                    yield chunk
                await current.aclose()
                if cursor > range_end or not segmented:
                    break
                next_end = min(cursor + chunk_size - 1, range_end)
                next_headers = dict(headers)
                next_headers["Range"] = f"bytes={cursor}-{next_end}"
                next_request = client.build_request("GET", source_url, headers=next_headers)
                current = await client.send(next_request, stream=True)
                if current.status_code != 206:
                    logger.error("audio relay range failed: HTTP %s", current.status_code)
                    await current.aclose()
                    break
                cursor = next_end + 1
        finally:
            await current.aclose()

    return StreamingResponse(
        chunks(), status_code=upstream.status_code if client_range else 200, headers=response_headers,
        background=BackgroundTask(client.aclose),
    )


@app.post("/player/play")
def player_play(body: PlayIn) -> PlaybackState:
    ost = ost_repo.get_ost(body.ost_id)
    if ost is None:
        raise HTTPException(404, "OST not found")
    _set_player(PlaybackState(status="resolving", ost_id=ost.id))
    _spawn(_resolve_worker, ost, True)
    return _player


@app.post("/player/pause")
def player_pause() -> PlaybackState:
    with _player_lock:
        state = _player.model_copy(update={"status": "paused"})
    _set_player(state)
    return state


@app.post("/player/seek")
def player_seek(body: SeekIn) -> PlaybackState:
    with _player_lock:
        state = _player.model_copy(update={"position": body.position})
    _set_player(state)
    return state


@app.post("/player/stop")
def player_stop() -> PlaybackState:
    state = PlaybackState(status="idle")
    _set_player(state)
    return state


# --- portable competition bundle -------------------------------------------------


@app.get("/export/portable")
def export_portable() -> FileResponse:
    """Download a zip of ost.db + covers/ so a competition can move platforms."""
    bundle = portable.export_bundle()
    return FileResponse(
        bundle,
        media_type="application/zip",
        filename="ost-tracker-portable.zip",
        background=BackgroundTask(bundle.unlink, missing_ok=True),
    )


@app.post("/import/portable", status_code=202)
async def import_portable(bundle: UploadFile = File(...)) -> dict:
    """Stage a portable zip; applied on the next launch (see lifespan)."""
    fd, tmp_name = tempfile.mkstemp(suffix=".zip")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        tmp.write_bytes(await bundle.read())
        await asyncio.to_thread(portable.stage_import, tmp)
    finally:
        tmp.unlink(missing_ok=True)
    return {"staged": True, "applies_after": "restart"}


# --- websocket ------------------------------------------------------------------


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket) -> None:
    supplied = ws.headers.get("X-OST-Token") or ws.query_params.get("token")
    if not secrets.compare_digest(supplied or "", TOKEN):
        await ws.close(code=4401)
        return
    await ws.accept()
    hub.add(ws)
    with _player_lock:
        snapshot = _player.model_dump()
    await ws.send_text(json.dumps({"type": "playbackState", "payload": snapshot}))
    try:
        while True:
            await ws.receive_text()  # client pings; content ignored
    except WebSocketDisconnect:
        pass
    finally:
        hub.remove(ws)


# --- entry point -----------------------------------------------------------------


def main() -> None:
    import uvicorn

    # Become our own process-group leader so the Swift/GTK hosts can tear
    # down the whole sidecar tree with one kill(-pgid). No-op/EPERM under a
    # job-control shell that already made us a leader; absent on Windows,
    # where the host kills the tree with a Job Object instead.
    if hasattr(os, "setpgid"):
        try:
            os.setpgid(0, 0)
        except OSError:
            pass

    global _bound_port
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    host = "0.0.0.0" if LAN_ENABLED else "127.0.0.1"
    port = LAN_PORT if LAN_ENABLED else int(os.environ.get("OST_API_PORT", 0))
    sock.bind((host, port))
    sock.listen(128)
    _bound_port = sock.getsockname()[1]

    config = uvicorn.Config(app, log_level="warning", lifespan="on")
    uvicorn.Server(config).run(sockets=[sock])


if __name__ == "__main__":
    main()
