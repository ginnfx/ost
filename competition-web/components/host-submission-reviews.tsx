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

export function HostSubmissionReviews() {
  const [reviews, setReviews] = useState<Review[]>([]);
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
    setMessage(
      data.reviews.length
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
