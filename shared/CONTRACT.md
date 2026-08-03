# OST Tracker sidecar contract

The reference spec for the Swift <-> Python interface. Python (`backend/api.py`,
Pydantic) is the writer of these shapes; Swift (`OSTTracker/Sources/Networking`,
Codable) mirrors them. Wire keys are snake_case; Swift decodes with
`.convertFromSnakeCase`.

## Transport

- HTTP + one WebSocket on `127.0.0.1:<ephemeral>`.
- Handshake: sidecar prints exactly one stdout line when ready:
  `OSTTRACKER_READY port=<port> token=<secret>`
- iOS (in-process sidecar): the sandbox forbids subprocesses, so `backend/api.py`
  runs on an embedded CPython thread inside the app instead of as a child. The
  ready line is identical but written to a handshake file in the app container
  (`<Documents>/sidecar-handshake.txt`), which the app polls; the token is
  app-generated and injected via `OST_API_TOKEN` before interpreter init.
- Every HTTP request and the `/ws` upgrade require header `X-OST-Token: <secret>`
  (401 / close 4401 otherwise). `/ws` also accepts `?token=` for dev tooling.
- Timestamps: ISO-8601 UTC strings (`2026-07-15T21:14:20Z`).
- Errors: `{"detail": <string>}`; domain `ValueError`s map to 400.
- Sidecar self-terminates when its parent dies (ppid watchdog) and is a
  process-group leader (host tears down with `kill(-pgid, SIGTERM)`, then
  SIGKILL after 2 s grace).
- Dev mode: `OST_API_TOKEN=dev OST_API_PORT=8765 uvicorn backend.api:app --reload --port 8765`.

## Objects

```jsonc
Person        {"id": 1, "name": "Alice"}
Ost           {"id": 1, "title": "…", "source": "…"|null, "submitter_id": 1|null,
               "submitter_name": "…"|null, "cover_image_path": "…"|null,
               "cover_accent_hex": "#RRGGBB"|null, "external_link": "…"|null,
               "created_at": "…"}
Rating        {"ost_id": 1, "rater_id": 2, "rater_name": "Bob", "score": 8.66,
               "updated_at": "…"}       // score: 0–10, any decimal (2 dp)
Note          {"id": 1, "title": "…", "note": "…", "created_at": "…"}
RankEntry     {"ost": Ost, "rating_count": 2, "average": 9.0|null,
               "minimum": 7.5|null, "maximum": 10|null, "stddev": 1.0|null,
               "rank": 1|null}          // all math computed in Python
PlaybackState {"status": "idle|resolving|playing|paused|stopped",
               "ost_id": 1|null, "stream_url": "…"|null,
               "watch_url": "…"|null, "position": 0.0}
BatchSlot     {"slot": 1, "ost": Ost, "pinned": true}   // slot is 1-based (OST 1, OST 2…); pinned is host-editable
BatchGroup    {"index": 1, "day": 1, "slots": [BatchSlot]}
Batches       {"generated_at": "…"|null, "batches": [BatchGroup]}

SliceTally    {"person_id": 1, "name": "Alice", "out_here": 2, "total_out": 4,
               "remaining": 1, "eliminated_here": false}
RankSlice     {"index": 1, "bottom_rank": 50, "top_rank": 41, "label": "50–41",
               "ost_ids": [12, 7, …], "tallies": [SliceTally]}   // ost_ids worst rank first
Elimination   {"person_id": 1, "name": "Alice", "place": 7, "slice_index": 2,
               "out_at_rank": 37, "total_out": 5}
Survivor      {"person_id": 2, "name": "Bob", "total_out": 3, "remaining": 2}
EliminationBoard {"threshold": 5, "slice_size": 10, "ranked_count": 50,
               "slices": [RankSlice], "eliminated": [Elimination],
               "survivors": [Survivor]}

HistoryEntry  {"id": 1, "title": "…", "source": "…"|null,
               "batch_label": "…"|null, "sender": "…"|null, "created_at": "…"}
```

Notes:
- `RankEntry.rank` is 1-based, `null` for unrated OSTs. Submitter auto-score=10
  is seeded by Python on OST create/update — Swift never fakes it.
- Scores are numbers 0–10, any decimal (JSON int or float — decode as double),
  stored rounded to 2 places; anything outside 0–10 is rejected with a 422.
- `PlaybackState.stream_url` is a yt-dlp-resolved media URL; the Swift AVPlayer
  is only the audio sink. Position/seek are advisory passthrough state.
- `RankSlice`s are bottom-anchored bands of `slice_size` (10) ranks, worst band
  first, so the ragged band lands at the TOP (47 OSTs → 47–38 … 7–1). Unrated
  OSTs have no rank and appear in no slice. A person is eliminated when
  `total_out` reaches `threshold`; `place` counts down from the field size, so
  the first person out gets the last place and place 1 is the winner.
- `POST /osts` rejects (400) a `{title, source}` pair that matches an existing
  `HistoryEntry` — case/whitespace-insensitive on both fields, except a blank
  or absent `source` on either side matches any source (so "Main Theme" from
  two different games are NOT duplicates, but a blank-source resubmission of
  a sourced title is still blocked). An OST from any past or current ranking
  can never be re-submitted this way. Every OST that's successfully created
  is auto-recorded into history (`batch_label: "Current Ranking"`, `sender`:
  the submitter's name) — no separate write path needed.
- `PATCH /osts/{id}` keeps the OST's own "Current Ranking" history row in
  sync when `title`/`source`/`submitter_id` change: the old title/source
  becomes re-submittable and the new one becomes protected. OSTs that predate
  this feature (no matching history row) are left alone.

## REST

| Method | Path                 | Body                | Returns              |
|--------|----------------------|---------------------|----------------------|
| GET    | /health              | —                   | `{"status":"ok"}`    |
| GET    | /people              | —                   | `[Person]`           |
| POST   | /people              | `{name}`            | `Person` (201)       |
| GET    | /osts                | —                   | `[Ost]`              |
| POST   | /osts                | `{title, source?, submitter_id?, external_link?}` | `Ost` (201) |
| PATCH  | /osts/{id}           | any subset of above | `Ost`                |
| DELETE | /osts/{id}           | —                   | 204                  |
| POST   | /osts/{id}/resolve   | —                   | `{"started":true}` (202), progress on /ws |
| GET    | /history             | —                   | `[HistoryEntry]`     |
| GET    | /history/matches     | `?title=&source=`   | `[HistoryEntry]` (case/whitespace-insensitive match on title, and on source unless either side's source is blank/absent) |
| GET    | /ratings             | —                   | `[Rating]`           |
| PUT    | /ratings             | `{ost_id, rater_id, score\|null}` (null clears) | echo |
| GET    | /notes               | —                   | `[Note]`             |
| POST   | /notes               | `{title, note}`     | `Note` (201)         |
| PATCH  | /notes/{id}          | `{title?, note?}`   | `Note`               |
| DELETE | /notes/{id}          | —                   | 204                  |
| GET    | /leaderboard         | —                   | `[RankEntry]`        |
| GET    | /elimination         | —                   | `EliminationBoard`   |
| PUT    | /elimination/threshold | `{threshold}` (1–20) | `EliminationBoard` |
| GET    | /batches             | —                   | `Batches` (empty until randomized) |
| POST   | /batches/randomize   | —                   | `Batches` (re-shuffles unpinned, pins keep slot, persisted) |
| PUT    | /batches/count       | `{count}` (1–8)     | `Batches` (re-flows current order into new sizes) |
| POST   | /batches/arrange     | `{batches: [[ost_id]]}` | `Batches` (host-placed order; 400 on unknown/dup id) |
| POST   | /batches/pin         | `{ost_id, pinned}`  | `Batches` (pin/unpin any OST) |
| POST   | /player/play         | `{ost_id}`          | `PlaybackState`      |
| POST   | /player/pause        | —                   | `PlaybackState`      |
| POST   | /player/seek         | `{position}`        | `PlaybackState`      |
| POST   | /player/stop         | —                   | `PlaybackState`      |
| GET    | /export/portable     | —                   | zip download (`ost-tracker-portable.zip`: `ost.db` + `covers/`, sqlite-backup snapshot) |
| POST   | /import/portable     | multipart `bundle`  | `{"staged": true, "applies_after": "restart"}` — files are applied at next launch (startup swap before the DB opens) |

## WebSocket /ws

Envelope: `{"type": <string>, "payload": <object|array>}`. On connect the
server immediately sends a `playbackState` snapshot. Client → server messages
are ignored (keepalive only).

| type                 | payload                                             |
|----------------------|-----------------------------------------------------|
| playbackState        | `PlaybackState`                                     |
| resolutionProgress   | `{"ost_id", "phase"}` — phase ∈ externalLink, searchingYouTube, searchingSpotifyMeta, searchingBing, extracting, ready, failed |
| ratingUpdated        | `{"ost_id", "rater_id", "score"\|null}`             |
| leaderboardResorted  | `[RankEntry]`                                       |
| coverArtReady        | `{"ost_id", "path", "accent_hex"}`                  |
