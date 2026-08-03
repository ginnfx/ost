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
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

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
from fastapi.responses import BackgroundTask, FileResponse, JSONResponse
from pydantic import BaseModel

from ost_tracker.db import history_repo, migrations, notes_repo, ost_repo, people_repo, rating_repo
from ost_tracker.db.models import HistoryEntry, Note, Ost, OstStats, Person, Rating
from ost_tracker.services import batches as batches_service
from ost_tracker.services import coverart
from ost_tracker.services import elimination as elimination_service
from ost_tracker.services import portable
from ost_tracker.services.link_resolver import resolve_playback

TOKEN = os.environ.get("OST_API_TOKEN") or secrets.token_hex(16)
_bound_port: Optional[int] = None  # set by __main__ before uvicorn runs


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


class NoteOut(BaseModel):
    id: int
    title: str
    note: str
    created_at: str


class NoteIn(BaseModel):
    title: str
    note: str = ""


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
    return NoteOut(id=n.id, title=n.title, note=n.note, created_at=_iso(n.created_at))


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
        _emit_phase(ost.id, "externalLink")
        cached = ost_repo.get_playback_watch_url(ost.id)
        result = resolve_playback(ost.title, ost.source, ost.external_link, cached)
        if result.watch_url and result.watch_url != cached:
            ost_repo.set_playback_watch_url(ost.id, result.watch_url)
        if result.stream_url:
            _emit_phase(ost.id, "ready")
            if play:
                _set_player(PlaybackState(
                    status="playing", ost_id=ost.id,
                    stream_url=result.stream_url, watch_url=result.watch_url,
                ))
        else:
            _emit_phase(ost.id, "failed")
            if play:
                _set_player(PlaybackState(status="idle"))
    finally:
        _resolving.ost_id = None


# --- player state (canonical here; the Swift AVPlayer is only the audio sink)


_player = PlaybackState(status="idle")
_player_lock = threading.Lock()


def _set_player(state: PlaybackState) -> None:
    global _player
    with _player_lock:
        _player = state
    hub.broadcast("playbackState", state.model_dump())


def _cover_worker(ost_id: int, title: str, source: Optional[str]) -> None:
    result = coverart.fetch_cover(ost_id, title, source)
    if not result.found:
        return
    ost_repo.set_cover(ost_id, str(result.path))
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
    if request.headers.get("X-OST-Token") != TOKEN:
        return JSONResponse({"detail": "invalid token"}, status_code=401)
    return await call_next(request)


@app.exception_handler(ValueError)
async def _value_error(_request: Request, exc: ValueError):
    return JSONResponse({"detail": str(exc)}, status_code=400)


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


# --- people -------------------------------------------------------------------


@app.get("/people")
def get_people() -> list[PersonOut]:
    return [_person_out(p) for p in people_repo.list_people()]


@app.post("/people", status_code=201)
def post_person(body: PersonIn) -> PersonOut:
    return _person_out(people_repo.add_person(body.name))


@app.delete("/people/{person_id}", status_code=204)
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


@app.delete("/osts/{ost_id}", status_code=204)
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
    ost_repo.set_cover(ost_id, str(result.path))
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
def get_ratings() -> list[RatingOut]:
    return [_rating_out(r) for r in rating_repo.all_ratings()]


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


# --- notes --------------------------------------------------------------------


@app.get("/notes")
def get_notes() -> list[NoteOut]:
    return [_note_out(n) for n in notes_repo.list_notes()]


@app.post("/notes", status_code=201)
def post_note(body: NoteIn) -> NoteOut:
    return _note_out(notes_repo.add_note(body.title, body.note))


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


@app.delete("/notes/{note_id}", status_code=204)
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
    if supplied != TOKEN:
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
    sock.bind(("127.0.0.1", int(os.environ.get("OST_API_PORT", 0))))
    sock.listen(128)
    _bound_port = sock.getsockname()[1]

    config = uvicorn.Config(app, log_level="warning", lifespan="on")
    uvicorn.Server(config).run(sockets=[sock])


if __name__ == "__main__":
    main()
