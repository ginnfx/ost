"use client";

import { useEffect, useState } from "react";

type Review = {
  submissionId: string;
  competitionId: string;
  roundName: string;
  nickname: string;
  slot: number;
  franchise: string;
  anilistId: number | null;
  ostTitle: string;
  originalSeconds: number;
  audioSeconds: number;
  status: string;
  duplicateCount: number;
  historyReuseCount: number;
  originalUrl: string;
  audioUrl: string;
};

type FailedJob = {
  uploadId: string;
  roundName: string;
  nickname: string;
  slot: number;
  ostTitle: string;
  errorCode: string;
  attemptCount: number;
  updatedAt: string;
};

export function HostSubmissionReviews() {
  const [reviews, setReviews] = useState<Review[]>([]);
  const [failures, setFailures] = useState<FailedJob[]>([]);
  const [message, setMessage] = useState("Loading flagged submissions…");
  const [busy, setBusy] = useState("");
  async function reload() {
    const response = await fetch("/api/host/submission-reviews", {
      cache: "no-store",
    });
    if (!response.ok) {
      setMessage("Reviews are not available.");
      return;
    }
    const data = await response.json();
    setReviews(data.reviews);
    setFailures(data.failures ?? []);
    setMessage(
      data.reviews.length || data.failures?.length
        ? "Private checks for this round's submissions."
        : "No submissions yet.",
    );
  }
  useEffect(() => {
    void reload();
  }, []);
  async function decide(review: Review, action: "approve" | "reject") {
    setBusy(review.submissionId);
    const response = await fetch(
      `/api/host/submission-reviews/${review.submissionId}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action }),
        cache: "no-store",
      },
    );
    setBusy("");
    if (!response.ok) {
      setMessage("This review could not be saved. Refresh and try again.");
      return;
    }
    setMessage(
      action === "approve"
        ? "Review approved. The submitter can confirm the clip."
        : "Clip rejected. The submitter can replace it.",
    );
    await reload();
  }
  return (
    <section className="host-review-list" aria-label="Flagged submissions">
      <p role="status" aria-live="polite">
        {message}
      </p>
      {failures.length > 0 && (
        <section aria-labelledby="processing-failures-heading">
          <h2 id="processing-failures-heading">Processing failures</h2>
          <p>These uploads stopped after retries or failed validation.</p>
          {failures.map((failure) => (
            <article className="host-review" key={failure.uploadId}>
              <p className="eyebrow">
                {failure.roundName} · ENTRY {failure.slot}
              </p>
              <h3>{failure.ostTitle}</h3>
              <p>
                Submitted by {failure.nickname}. Reason:{" "}
                {failure.errorCode.replaceAll("_", " ")}. Attempts:{" "}
                {failure.attemptCount}.
              </p>
              <p>
                The participant can retry the upload. Check Cloud Run logs for
                service errors.
              </p>
            </article>
          ))}
        </section>
      )}
      {reviews.map((review) => (
        <article className="host-review" key={review.submissionId}>
          <header>
            <div>
              <p className="eyebrow">
                {review.roundName} · ENTRY {review.slot}
              </p>
              <h2>{review.ostTitle}</h2>
              <p>
                {review.franchise} · submitted by {review.nickname}
                {review.anilistId ? ` · AniList ${review.anilistId}` : ""}
              </p>
            </div>
          </header>
          {review.duplicateCount > 1 && (
            <p className="review-duplicate">
              Same franchise and OST title appears {review.duplicateCount} times
              in this round.
            </p>
          )}
          {review.historyReuseCount > 0 && (
            <p className="review-duplicate">
              This participant used this franchise and title in a previous
              round.
            </p>
          )}
          <div className="review-media-grid">
            <div>
              <h3>Original video</h3>
              {/* Host-only video contains user-provided music clips; no transcript is supplied. */}
              {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
              <video controls preload="none" src={review.originalUrl} />
              <p>
                Detected duration: {review.originalSeconds.toFixed(2)} seconds
              </p>
            </div>
            <div>
              <h3>Processed audio</h3>
              {/* Anonymous OST audio is intentionally not accompanied by lyrics or transcript. */}
              {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
              <audio controls preload="none" src={review.audioUrl} />
              <p>
                Processed duration: {review.audioSeconds.toFixed(2)} seconds
              </p>
            </div>
          </div>
          {review.status === "needs_review" && (
            <div className="action-row">
              <button
                className="button primary"
                disabled={busy === review.submissionId}
                onClick={() => void decide(review, "approve")}
              >
                Approve for submitter confirmation
              </button>
              <button
                className="button secondary"
                disabled={busy === review.submissionId}
                onClick={() => void decide(review, "reject")}
              >
                Reject clip
              </button>
            </div>
          )}
        </article>
      ))}
    </section>
  );
}
