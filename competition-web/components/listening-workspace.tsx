"use client";

import { useCallback, useEffect, useRef, useState } from "react";

type Batch = {
  number: number;
  status: "scheduled" | "released" | "closed";
  releasedAt: string | null;
  entryCount: number;
  ratedCount: number;
  finalized: boolean;
};
type Entry = {
  listeningId: string;
  label: string;
  audioUrl: string;
  durationSeconds: number;
  own: boolean;
  automaticScore: number | null;
  rating: number | null;
  version: number;
};
type Result = {
  listeningId: string;
  label: string;
  franchise: string;
  ostTitle: string;
  rank: number;
  meanScore: string;
  ratingCount: number;
  group: number;
};
type QueuedRating = { score: number; version: number; batch: number };

export function ListeningWorkspace({
  competitionId,
  initialBatches,
}: {
  competitionId: string;
  initialBatches: Batch[];
}) {
  const [batches, setBatches] = useState(initialBatches);
  const [selected, setSelected] = useState<number | null>(
    initialBatches.find((batch) => batch.status === "released")?.number ?? null,
  );
  const [entries, setEntries] = useState<Entry[]>([]);
  const [results, setResults] = useState<Result[]>([]);
  const [scores, setScores] = useState<Record<string, number | null>>({});
  const queue = useRef<Record<string, QueuedRating>>({});
  const flushing = useRef(false);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("Choose an open batch to listen.");

  const reloadBatches = useCallback(async () => {
    const response = await fetch(`/api/competitions/${competitionId}/batches`, {
      cache: "no-store",
    });
    if (response.ok) setBatches((await response.json()).batches);
  }, [competitionId]);

  const reloadResults = useCallback(async () => {
    const response = await fetch(`/api/competitions/${competitionId}/results`, {
      cache: "no-store",
    });
    if (response.ok) setResults((await response.json()).results);
  }, [competitionId]);
  const persistQueue = useCallback(() => {
    const key = `ost_pending_ratings_${competitionId}`;
    if (Object.keys(queue.current).length)
      sessionStorage.setItem(key, JSON.stringify(queue.current));
    else sessionStorage.removeItem(key);
  }, [competitionId]);

  const loadBatch = useCallback(
    async (batchNumber: number) => {
      setSelected(batchNumber);
      setLoading(true);
      const response = await fetch(
        `/api/competitions/${competitionId}/batches/${batchNumber}`,
        { cache: "no-store" },
      );
      setLoading(false);
      if (!response.ok) {
        setEntries([]);
        setMessage("This batch is not open yet.");
        return;
      }
      const loaded = (await response.json()).entries as Entry[];
      setEntries(loaded);
      setScores(
        Object.fromEntries(
          loaded.map((entry) => [
            entry.listeningId,
            queue.current[entry.listeningId]?.score ?? entry.rating,
          ]),
        ),
      );
      setMessage("Ratings save when the server confirms them.");
    },
    [competitionId],
  );

  useEffect(() => {
    if (selected !== null && entries.length === 0) void loadBatch(selected);
  }, [selected, entries.length, loadBatch]);
  useEffect(() => {
    if (selected === null || entries.length === 0) return;
    const timer = window.setInterval(() => {
      if (Object.keys(queue.current).length) return;
      void fetch(`/api/competitions/${competitionId}/batches/${selected}`, {
        cache: "no-store",
      }).then(async (response) => {
        if (!response.ok) return;
        const remote = (await response.json()).entries as Entry[];
        setEntries(remote);
        setScores((current) => {
          const next = { ...current };
          for (const entry of remote)
            if (!queue.current[entry.listeningId])
              next[entry.listeningId] = entry.rating;
          return next;
        });
      });
    }, 4000);
    return () => window.clearInterval(timer);
  }, [competitionId, selected, entries.length]);

  const flushQueue = useCallback(async () => {
    if (flushing.current || !navigator.onLine) return;
    flushing.current = true;
    try {
      while (navigator.onLine) {
        const next = Object.entries(queue.current)[0];
        if (!next) break;
        const [listeningId, pending] = next;
        const response = await fetch("/api/ratings", {
          method: "PUT",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            competitionId,
            batch: pending.batch,
            listeningId,
            score: pending.score,
            expectedVersion: pending.version,
          }),
          cache: "no-store",
        });
        const payload = await response.json().catch(() => ({}));
        if (response.status === 409) {
          delete queue.current[listeningId];
          persistQueue();
          if (selected !== null) await loadBatch(selected);
          setMessage(
            payload.error ?? "Rating changed elsewhere. Reload to sync.",
          );
          break;
        }
        if (!response.ok) {
          setMessage("Not saved yet. We will retry when you are online.");
          break;
        }
        setEntries((current) =>
          current.map((entry) =>
            entry.listeningId === listeningId
              ? { ...entry, rating: pending.score, version: payload.version }
              : entry,
          ),
        );
        if (queue.current[listeningId]?.score === pending.score) {
          delete queue.current[listeningId];
        } else if (queue.current[listeningId]) {
          queue.current[listeningId] = {
            ...queue.current[listeningId],
            version: payload.version,
          };
        }
        persistQueue();
        setMessage(
          Object.keys(queue.current).length
            ? "Saving remaining ratings…"
            : "Saved on the server.",
        );
      }
    } finally {
      flushing.current = false;
    }
  }, [competitionId, loadBatch, persistQueue, selected]);

  useEffect(() => {
    void reloadResults();
    const timer = window.setInterval(() => {
      void reloadBatches();
      void reloadResults();
    }, 4000);
    const key = `ost_pending_ratings_${competitionId}`;
    const saved = sessionStorage.getItem(key);
    if (saved) {
      try {
        const parsed = JSON.parse(saved) as Record<string, QueuedRating>;
        if (
          Object.values(parsed).every(
            (item) =>
              Number.isInteger(item.score) &&
              item.score >= 1 &&
              item.score <= 10 &&
              Number.isInteger(item.version) &&
              Number.isInteger(item.batch),
          )
        ) {
          queue.current = parsed;
          if (navigator.onLine) void flushQueue();
          else setMessage("Not saved yet. Waiting for a connection.");
        }
      } catch {
        sessionStorage.removeItem(key);
      }
    }
    return () => window.clearInterval(timer);
  }, [competitionId, flushQueue, reloadBatches, reloadResults]);

  useEffect(() => {
    const online = () => void flushQueue();
    window.addEventListener("online", online);
    return () => window.removeEventListener("online", online);
  }, [flushQueue]);

  function rate(entry: Entry, score: number) {
    if (
      entry.own ||
      batches.find((batch) => batch.number === selected)?.finalized
    )
      return;
    setScores((current) => ({ ...current, [entry.listeningId]: score }));
    queue.current[entry.listeningId] = {
      score,
      version: entry.version,
      batch: selected ?? 0,
    };
    persistQueue();
    setMessage("Not saved yet.");
    void flushQueue();
  }

  async function finalize() {
    if (selected === null) return;
    if (Object.keys(queue.current).length) await flushQueue();
    if (Object.keys(queue.current).length) {
      setMessage("Wait for every rating to save before finalizing.");
      return;
    }
    const response = await fetch(
      `/api/competitions/${competitionId}/batches/${selected}/finalize`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
        cache: "no-store",
      },
    );
    if (!response.ok) {
      setMessage("Batch not finalized. Rate every clip and try again.");
      return;
    }
    setMessage(`Batch ${selected} finalized. Ratings are locked.`);
    await reloadBatches();
  }

  const batch = batches.find((item) => item.number === selected);
  return (
    <div className="listening-workspace">
      <section className="batch-picker" aria-label="Listening batches">
        {batches.map((item) => (
          <button
            className={`batch-choice${selected === item.number ? " selected" : ""}`}
            key={item.number}
            disabled={item.status === "scheduled"}
            onClick={() => void loadBatch(item.number)}
          >
            <strong>Batch {item.number}</strong>
            <span>
              {item.status === "scheduled"
                ? "Waiting"
                : `${item.ratedCount}/${item.entryCount} rated`}
            </span>
            {item.finalized && <span>Finalized</span>}
          </button>
        ))}
      </section>
      <p role="status" aria-live="polite">
        {message}
      </p>
      {loading ? (
        <p className="loading-state">Loading soundtracks…</p>
      ) : entries.length > 0 ? (
        <>
          {entries.map((entry) => (
            <article className="listening-entry" key={entry.listeningId}>
              <div className="listening-entry-heading">
                <h2>{entry.label}</h2>
                <span>{Math.round(entry.durationSeconds)} seconds</span>
              </div>
              {entry.own && (
                <p className="own-entry">
                  Your entry · scored automatically: 10
                </p>
              )}
              {/* Anonymous soundtrack audio has no transcript or captions. */}
              {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
              <audio
                controls
                preload="none"
                src={entry.audioUrl}
                onPlay={() => {
                  if ("mediaSession" in navigator && "MediaMetadata" in window)
                    navigator.mediaSession.metadata = new MediaMetadata({
                      title: entry.label,
                    });
                }}
                onError={() => selected !== null && void loadBatch(selected)}
              />
              {entry.own ? (
                <p>Automatic rating: 10</p>
              ) : (
                <fieldset className="rating-field" disabled={batch?.finalized}>
                  <legend>Rate {entry.label}</legend>
                  <div
                    className="rating-options"
                    role="radiogroup"
                    aria-label={`Rate ${entry.label}`}
                  >
                    {Array.from({ length: 10 }, (_, index) => index + 1).map(
                      (score) => (
                        <button
                          type="button"
                          role="radio"
                          aria-checked={scores[entry.listeningId] === score}
                          aria-label={`${entry.label}, rating ${score} of 10`}
                          tabIndex={
                            scores[entry.listeningId] === score ||
                            (scores[entry.listeningId] == null && score === 1)
                              ? 0
                              : -1
                          }
                          className={`rating-option${scores[entry.listeningId] === score ? " selected" : ""}`}
                          key={score}
                          onClick={() => rate(entry, score)}
                          onKeyDown={(event) => {
                            if (
                              ![
                                "ArrowLeft",
                                "ArrowUp",
                                "ArrowRight",
                                "ArrowDown",
                                "Home",
                                "End",
                              ].includes(event.key)
                            )
                              return;
                            event.preventDefault();
                            const options = Array.from(
                              event.currentTarget
                                .closest("[role='radiogroup']")
                                ?.querySelectorAll<HTMLButtonElement>(
                                  "[role='radio']",
                                ) ?? [],
                            );
                            const current = options.indexOf(
                              event.currentTarget,
                            );
                            const next =
                              event.key === "Home"
                                ? 0
                                : event.key === "End"
                                  ? options.length - 1
                                  : (current +
                                      (["ArrowRight", "ArrowDown"].includes(
                                        event.key,
                                      )
                                        ? 1
                                        : -1) +
                                      options.length) %
                                    options.length;
                            options[next]?.focus();
                            options[next]?.click();
                          }}
                        >
                          {score}
                        </button>
                      ),
                    )}
                  </div>
                </fieldset>
              )}
            </article>
          ))}
          {!batch?.finalized && (
            <button
              className="button primary"
              disabled={
                entries.some((entry) => scores[entry.listeningId] === null) ||
                Object.keys(queue.current).length > 0
              }
              onClick={() => void finalize()}
            >
              Finalize batch {selected}
            </button>
          )}
        </>
      ) : selected !== null ? (
        <p className="empty-state">
          No soundtracks in this batch are available yet.
        </p>
      ) : (
        <p className="empty-state">The host has not opened a batch yet.</p>
      )}
      {results.length > 0 && (
        <section className="published-results" aria-label="Published results">
          <h2>Revealed soundtracks</h2>
          <ol>
            {results.map((result) => (
              <li key={result.listeningId}>
                <span>
                  #{result.rank} · {result.label}
                </span>
                <strong>{result.ostTitle}</strong>
                <span>
                  {result.franchise} · {result.meanScore} ({result.ratingCount}{" "}
                  ratings)
                </span>
              </li>
            ))}
          </ol>
        </section>
      )}
    </div>
  );
}
