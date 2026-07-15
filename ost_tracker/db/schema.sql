-- OST Tracker schema. See ost_tracker/db/connection.py for how it is applied.
-- Foreign keys are enforced at runtime via `PRAGMA foreign_keys = ON`.

CREATE TABLE IF NOT EXISTS people (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS osts (
    id               INTEGER PRIMARY KEY,
    title            TEXT NOT NULL,
    source           TEXT,                       -- game / anime / media the OST is from
    submitter_id     INTEGER REFERENCES people(id) ON DELETE SET NULL,
    cover_image_path TEXT,                        -- local cached file path, never a URL
    cover_accent_hex TEXT,                        -- #rrggbb derived from the cover (see services/accent.py)
    external_link    TEXT,                        -- optional YouTube/Spotify URL
    playback_watch_url TEXT,                      -- cached resolved YouTube page (services/link_resolver.py)
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS ratings (
    id         INTEGER PRIMARY KEY,
    ost_id     INTEGER NOT NULL REFERENCES osts(id) ON DELETE CASCADE,
    rater_id   INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    -- Any decimal 0–10, rounded to 2 places on write. Databases created before
    -- this was REAL keep INTEGER affinity, which still stores fractions losslessly.
    score      REAL NOT NULL CHECK (score BETWEEN 0 AND 10),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (ost_id, rater_id)
);

-- Personal scratchpad. Deliberately disconnected from `osts`: entries here must
-- never influence rankings, stats, or exports.
CREATE TABLE IF NOT EXISTS notes (
    id         INTEGER PRIMARY KEY,
    title      TEXT NOT NULL,
    note       TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Previously-used OSTs from earlier competitions. Not competition data — this
-- is a reference/exclusion list: adding a new OST warns if its title already
-- appears here so the same track isn't submitted twice across seasons.
CREATE TABLE IF NOT EXISTS ost_history (
    id         INTEGER PRIMARY KEY,
    title      TEXT NOT NULL,
    source     TEXT,
    batch_label TEXT,                             -- which past ranking this came from (free text)
    sender     TEXT,                               -- who submitted it (free text, not a people(id) FK)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Simple key/value store for app state that is not competition data
-- (e.g. the locked-reveal flag, remembered sort/filter). Not in the original
-- spec's data model; added so reveal state survives restarts.
CREATE TABLE IF NOT EXISTS app_settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE INDEX IF NOT EXISTS idx_history_title ON ost_history(title COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_ratings_ost   ON ratings(ost_id);
CREATE INDEX IF NOT EXISTS idx_ratings_rater ON ratings(rater_id);
CREATE INDEX IF NOT EXISTS idx_osts_submitter ON osts(submitter_id);
