"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

type Trial = {
  competitionId: string;
  name: string;
  status: string;
  createdAt: string;
  submissionDeadline: string | null;
  ratingDeadline: string | null;
  participantCount: number;
};

export function HostTrialManagement() {
  const [trials, setTrials] = useState<Trial[]>([]);
  const [message, setMessage] = useState("Loading trial rounds…");
  const [busy, setBusy] = useState(false);
  const [inviteUrl, setInviteUrl] = useState<Record<string, string>>({});

  async function reload() {
    const response = await fetch("/api/host/trials", { cache: "no-store" });
    if (!response.ok) {
      setMessage("Trial rounds are unavailable.");
      return;
    }
    const data = await response.json();
    setTrials(data.trials);
    setMessage(
      data.trials.length ? "Trial round status." : "No trial round yet.",
    );
  }
  useEffect(() => {
    void reload();
  }, []);

  async function createTrial() {
    setBusy(true);
    const response = await fetch("/api/host/trials", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
      cache: "no-store",
    });
    const result = await response.json().catch(() => ({}));
    setBusy(false);
    if (!response.ok) {
      setMessage(result.error ?? "Trial round could not be created.");
      return;
    }
    setMessage(
      "Trial round created. Open it to start the 24-hour submission deadline.",
    );
    await reload();
  }

  async function createInvite(trial: Trial) {
    setBusy(true);
    const response = await fetch("/api/host/invites", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ competitionId: trial.competitionId }),
      cache: "no-store",
    });
    const result = await response.json().catch(() => ({}));
    setBusy(false);
    if (!response.ok) {
      setMessage(result.error ?? "Invite could not be created.");
      return;
    }
    setInviteUrl((current) => ({
      ...current,
      [trial.competitionId]: result.inviteUrl,
    }));
    setMessage(
      "One-use invite link created. Share it directly with one participant.",
    );
  }

  async function deleteTrial(trial: Trial) {
    if (
      !window.confirm(
        `Delete all submissions, ratings, accounts for unused invites, and media in ${trial.name}? This cannot be undone.`,
      )
    )
      return;
    setBusy(true);
    const response = await fetch(
      `/api/host/trials/${trial.competitionId}/delete`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ confirmation: "DELETE TRIAL" }),
        cache: "no-store",
      },
    );
    const result = await response.json().catch(() => ({}));
    setBusy(false);
    if (!response.ok) {
      setMessage(result.error ?? "Trial cleanup did not finish.");
      return;
    }
    setMessage("Trial data and media deleted.");
    await reload();
  }

  return (
    <section className="host-trial-management">
      <p role="status" aria-live="polite">
        {message}
      </p>
      <button
        className="button primary"
        disabled={busy || trials.some((trial) => trial.status !== "archived")}
        onClick={() => void createTrial()}
      >
        Create trial round
      </button>
      {trials.map((trial) => (
        <article className="trial-management-row" key={trial.competitionId}>
          <div className="trial-management-heading">
            <div>
              <p className="eyebrow">TRIAL ROUND</p>
              <h2>{trial.name}</h2>
              <p>
                {trial.status.replaceAll("_", " ")} · {trial.participantCount}{" "}
                participants
              </p>
              {trial.submissionDeadline && (
                <p>
                  Submissions close{" "}
                  {new Date(trial.submissionDeadline).toLocaleString()}
                </p>
              )}
              {trial.ratingDeadline && (
                <p>
                  Ratings close{" "}
                  {new Date(trial.ratingDeadline).toLocaleString()}
                </p>
              )}
            </div>
            <Link
              className="button secondary"
              href={`/host/competitions/${trial.competitionId}`}
            >
              Host controls
            </Link>
          </div>
          {trial.status === "submissions_open" &&
            trial.participantCount < 10 && (
              <button
                className="button secondary"
                disabled={busy}
                onClick={() => void createInvite(trial)}
              >
                Create participant invite
              </button>
            )}
          {inviteUrl[trial.competitionId] && (
            <label className="invite-link-field">
              One-use link · expires in seven days
              <input
                readOnly
                value={inviteUrl[trial.competitionId]}
                onFocus={(event) => event.currentTarget.select()}
              />
            </label>
          )}
          <button
            className="button secondary danger-button"
            disabled={busy}
            onClick={() => void deleteTrial(trial)}
          >
            Delete trial data and media
          </button>
        </article>
      ))}
    </section>
  );
}
