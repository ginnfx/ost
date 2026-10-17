# OST Tracker sidecar contract

Single source of truth for the HTTP + `/ws` interface that every client
(SwiftUI app, WinUI 3 client, GTK4 client) programs against. The sidecar
(`backend/api.py`) is the ONLY implementer; clients are thin delegations.
If you change an endpoint here, change `backend/api.py` and re-verify the
three clients still compile/import.

## Transport

- Launch: `python backend/api.py` binds `127.0.0.1:<ephemeral>` (or `OST_API_PORT`)
  and prints one line on stdout: `OSTTRACKER_READY port=<port> token=<secret>`.
- Auth: every HTTP request and the WS upgrade require `X-OST-Token: <token>`
  (WS also accepts `?token=`). `/player/audio/*` is exempt (URL already
  carries a per-play token) because AVPlayer can't attach headers.
- Errors: HTTP 4xx with `{"detail": "..."}`; anything `ValueError` from the
  domain layer becomes 400.
- Lifecycle: the sidecar exits when its parent dies (ppid poll on POSIX,
  parent-pid probe on Windows; WinUI additionally kills its tree via a Job).

## Wire format

JSON, snake_case keys, ISO-8601 UTC timestamps ending in `Z`. Decimal scores
are 0–10 floats stored rounded to 2 places.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | liveness |
| GET | `/people` | roster |
| POST | `/people` | `{name}` → person |
| DELETE | `/people/{id}` | delete (cascades ratings, nulls submissions) |
| GET | `/osts` | active round OSTs |
| POST | `/osts` | `{title, source?, submitter_id, external_link?}` → OST (spawns cover fetch) |
| PATCH | `/osts/{id}` | edit title/source/submitter/link |
| DELETE | `/osts/{id}` | delete |
| POST | `/osts/{id}/resolve` | pre-resolve playback, no play |
| GET | `/history` | retired-round history |
| GET | `/history/matches?title=&source=` | duplicate check for Add-OST |
| PATCH | `/history/label` | rename a batch label |
| POST | `/history/import-competition` | bulk import past competition `{entries[], source_id, name}` |
| GET / POST | `/rounds` `/rounds/start` | round status / start `{name}` |
| GET | `/rounds/{id}` | retired archive |
| GET | `/rounds/retire-challenge` | `{challenge_id, word}` |
| POST | `/rounds/retire` | `{challenge_id, word}` → retire + archive |
| POST | `/rounds/{id}/restore` | restore a round |
| GET | `/osts/{id}/cover/candidates` | source-tagged artwork options |
| POST | `/osts/{id}/cover` | `{image_url}` → apply, re-fetch accent |
| GET | `/ratings?rater_id=` | scores |
| PUT | `/ratings` | `{ost_id, rater_id, score?}` (null clears) |
| POST | `/ratings/bulk` | `{ratings[]{ost_id, rater_id, score?}}` one transaction |
| GET / PUT | `/settings/reveal` | reveal gate `{unlocked}` |
| GET | `/notes` | scratchpad |
| GET | `/notes/catalog-search?q=` | music catalog lookup (external) |
| POST | `/notes` | `{title, note?, source?, artist?, external_link?}` |
| PATCH | `/notes/{id}` | `{title?, note?}` |
| DELETE | `/notes/{id}` | delete |
| GET | `/leaderboard` | ranked entries with stats |
| GET | `/elimination` | slice elimination board |
| PUT | `/elimination/threshold` | `{threshold}` → board |
| GET | `/batches` | listening batches |
| POST | `/batches/randomize` | re-shuffle |
| PUT | `/batches/count` | `{count}` (1–8) |
| POST | `/batches/arrange` | `{batches: [[ost_id,…],…]}` host-ordered |
| POST | `/batches/pin` | `{ost_id, pinned}` host-only pin |
| POST | `/player/play` | `{ost_id}` → resolves (cached audio OK) then plays |
| POST | `/player/pause` `/player/stop` | canonical player state |
| POST | `/player/seek` | `{position}` seconds |
| GET/HEAD | `/player/audio/{stream_id}` | ranged localhost relay for yt-dlp streams |
| GET | `/export/portable` | zip of `ost.db` + covers |
| POST | `/import/portable` | stages a zip; applied on next launch |
| GET / PUT | `/sync/state` | portable competition snapshot for cloud sync |

## WebSocket `/ws`

Server pushes `{"type": …, "payload": …}` envelopes; clients ping freely.

| Type | Payload | Emitted when |
|---|---|---|
| `playbackState` | PlaybackState (also sent on connect) | play/pause/seek/stop/resolve |
| `leaderboardResorted` | `RankEntry[]` | any scoring change (debounced ~150 ms) |
| `ratingUpdated` | `{ost_id, rater_id, score}` | single PUT /ratings |
| `revealState` | `{unlocked}` | reveal gate toggled |
| `coverArtReady` | `{ost_id, path, accent_hex}` | artwork fetched/applied |
| `resolutionProgress` | `{ost_id, phase}` | `searchingYouTube`, `searchingSpotifyMeta`, `searchingBing`, `extracting`, `ready`, `externalLink`, `failed` |

## Non-goals

Lyrics are NOT part of the contract: every client fetches from LRCLIB /
lyrics.ovh directly (Swift `LyricsService`, C# `LyricsService`, GTK `lyrics.py`)
so the sidecar never sees lyric traffic. Visualizer band data is measured
client-locally (GTK GStreamer `spectrum` element; Swift/WinUI use the ambient
fallback where no PCM tap exists).
