"use client";

import { useCallback, useEffect, useRef, useState } from "react";

type RoundState = {
  name: string;
  status: string;
  isTrial: boolean;
  participants: Array<{
    id: string;
    nickname: string;
    withdrawn: boolean;
    finalizedBatches: number[];
  }>;
  batches: Array<{ number: number; status: string; entryCount: number }>;
  groups: Array<{
    number: number;
    published: boolean;
    entryCount: number;
    revealedCount: number;
  }>;
};

export function HostRoundControl({ competitionId }: { competitionId: string }) {
  const [state, setState] = useState<RoundState | null>(null);
  const [message, setMessage] = useState("Loading competition status…");
  const [busy, setBusy] = useState(false);
  const [holding, setHolding] = useState(false);
  const holdTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const reload = useCallback(
    async (announce = true) => {
      const response = await fetch(`/api/host/competitions/${competitionId}`, {
        cache: "no-store",
      });
      if (!response.ok) {
        setMessage("Competition controls are unavailable.");
        return;
      }
      const data = await response.json();
      setState(data.state);
      if (announce) setMessage("Status refreshed.");
    },
    [competitionId],
  );
  useEffect(() => {
    void reload(false);
    const timer = window.setInterval(() => void reload(false), 5000);
    return () => window.clearInterval(timer);
  }, [reload]);

  async function action(
    name: string,
    fields: Record<string, number | string> = {},
  ) {
    setBusy(true);
    const response = await fetch(
      `/api/host/competitions/${competitionId}/actions`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action: name, ...fields }),
        cache: "no-store",
      },
    );
    const result = await response.json().catch(() => ({}));
    setBusy(false);
    if (!response.ok) {
      setMessage(result.error ?? "That host action could not be completed.");
      return;
    }
    if (name === "start_listening")
      setMessage(`Listening started with ${result.batches} batches.`);
    else if (name === "score")
      setMessage(
        `Scoring is frozen across ${result.revealGroups} reveal groups.`,
      );
    else if (name === "reveal_next")
      setMessage(
        result.revealed
          ? "The next soundtrack is revealed."
          : "This group is fully revealed.",
      );
    else setMessage("Action complete.");
    await reload(false);
  }

  function beginPublishHold(group: number) {
    setHolding(true);
    holdTimer.current = setTimeout(() => {
      holdTimer.current = null;
      setHolding(false);
      void action("publish_group", { group });
    }, 1200);
  }
  function cancelPublishHold() {
    if (holdTimer.current) clearTimeout(holdTimer.current);
    holdTimer.current = null;
    setHolding(false);
  }
  function publishButton(group: number, label: string) {
    return (
      <button
        className="button primary"
        disabled={busy}
        onPointerDown={() => beginPublishHold(group)}
        onPointerUp={cancelPublishHold}
        onPointerLeave={cancelPublishHold}
        onPointerCancel={cancelPublishHold}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            cancelPublishHold();
            void action("publish_group", { group });
          }
        }}
      >
        {holding ? "Keep holding to publish…" : label}
      </button>
    );
  }

  if (!state)
    return (
      <section className="host-round-control">
        <p role="status">{message}</p>
      </section>
    );

  const pendingGroup = state.groups.find((group) => !group.published);
  const activeGroup = [...state.groups]
    .reverse()
    .find((group) => group.published && group.revealedCount < group.entryCount);
  return (
    <section className="host-round-control" aria-label="Competition controls">
      <p role="status" aria-live="polite">
        {message}
      </p>
      {state.isTrial && <p className="trial-chip">TRIAL ROUND</p>}
      <h2>{state.status.replaceAll("_", " ")}</h2>
      {state.status === "submissions_open" && (
        <button
          className="button primary"
          disabled={busy}
          onClick={() => void action("lock_submissions")}
        >
          Lock confirmed submissions
        </button>
      )}
      {state.status === "submissions_locked" && (
        <button
          className="button primary"
          disabled={busy}
          onClick={() => void action("start_listening")}
        >
          Create batches and start listening
        </button>
      )}
      {state.status === "listening" && (
        <>
          <div className="round-list">
            {state.batches.map((batch) => (
              <article className="round-row" key={batch.number}>
                <div>
                  <h3>Batch {batch.number}</h3>
                  <p>
                    {batch.entryCount} soundtracks · {batch.status}
                  </p>
                </div>
                {batch.status === "scheduled" && (
                  <button
                    className="button secondary"
                    disabled={busy}
                    onClick={() =>
                      void action("release_batch", { batch: batch.number })
                    }
                  >
                    Open batch {batch.number}
                  </button>
                )}
              </article>
            ))}
          </div>
          <section
            className="host-finalization-list"
            aria-label="Participant batch progress"
          >
            <h3>Participant progress</h3>
            {state.participants.map((participant) => (
              <article className="round-row" key={participant.id}>
                <div>
                  <strong>
                    {participant.nickname}
                    {participant.withdrawn ? " · withdrawn" : ""}
                  </strong>
                  <p>
                    Finalized batches:{" "}
                    {participant.finalizedBatches.length
                      ? participant.finalizedBatches.join(", ")
                      : "none"}
                  </p>
                </div>
                {participant.finalizedBatches.map((number) => (
                  <button
                    className="text-link"
                    key={number}
                    disabled={busy}
                    onClick={() =>
                      void action("reopen_batch", {
                        batch: number,
                        participantId: participant.id,
                      })
                    }
                  >
                    Reopen batch {number}
                  </button>
                ))}
              </article>
            ))}
          </section>
          <button
            className="button secondary"
            disabled={busy}
            onClick={() => void action("close_ratings")}
          >
            Close ratings
          </button>
        </>
      )}
      {state.status === "rating_closed" && (
        <button
          className="button primary"
          disabled={busy}
          onClick={() => void action("score")}
        >
          Freeze scores and create reveal groups
        </button>
      )}
      {state.status === "scored" && pendingGroup && (
        <div className="reveal-confirm-control">
          <p>
            Reveal group {pendingGroup.number} contains{" "}
            {pendingGroup.entryCount} soundtracks.
          </p>
          {publishButton(
            pendingGroup.number,
            `Hold to publish group ${pendingGroup.number}`,
          )}
        </div>
      )}
      {state.status === "revealing" && (
        <>
          {activeGroup && (
            <p>
              Group {activeGroup.number}: {activeGroup.revealedCount} of{" "}
              {activeGroup.entryCount} soundtracks revealed.
            </p>
          )}
          <button
            className="button primary"
            disabled={busy || !activeGroup}
            onClick={() =>
              activeGroup &&
              void action("reveal_next", { group: activeGroup.number })
            }
          >
            Reveal next soundtrack
          </button>
          {pendingGroup && (
            <div className="reveal-confirm-control">
              <p>
                Group {pendingGroup.number} contains {pendingGroup.entryCount}{" "}
                soundtracks.
              </p>
              {publishButton(
                pendingGroup.number,
                `Hold to publish group ${pendingGroup.number}`,
              )}
            </div>
          )}
        </>
      )}
      {state.status === "complete" && <p>The reveal is complete.</p>}
    </section>
  );
}
