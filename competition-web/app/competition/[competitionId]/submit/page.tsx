import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { SubmissionWorkspace } from "@/components/submission-workspace";
import { SignInRequired, withCurrentUser } from "@/lib/server/database";
import { verifiedCurrentUser } from "@/lib/server/auth";

export const dynamic = "force-dynamic";
export const metadata = {
  title: "Submit entries · OST Competition",
  robots: { index: false, follow: false },
};

export default async function SubmissionPage({
  params,
}: {
  params: Promise<{ competitionId: string }>;
}) {
  const { competitionId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) notFound();
  const identity = await verifiedCurrentUser();
  if (!identity) redirect("/login");
  let policy;
  let submissions;
  try {
    ({ policy, submissions } = await withCurrentUser(async (db) => {
      const policyResult = await db.query(
        "select * from private.my_submission_upload_policy($1)",
        [competitionId],
      );
      if (!policyResult.rows[0]) return { policy: null, submissions: [] };
      const submissionResult = await db.query(
        "select * from private.list_my_submissions($1)",
        [competitionId],
      );
      return {
        policy: policyResult.rows[0],
        submissions: submissionResult.rows,
      };
    }));
  } catch (error) {
    if (error instanceof SignInRequired) redirect("/login");
    notFound();
  }
  if (!policy) notFound();
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/app">
          OST TRACKER <span>COMPETITION</span>
        </Link>
        <Link className="text-link" href="/app">
          Your rounds
        </Link>
      </header>
      <section className="participant-home">
        <p className="eyebrow">SUBMISSIONS</p>
        <h1>Choose your clips</h1>
        <p className="intro">
          Submit {policy.entries_per_participant} clips. Each file must include
          audio and last {policy.min_clip_seconds} to {policy.max_clip_seconds}{" "}
          seconds.
        </p>
        <SubmissionWorkspace
          competitionId={competitionId}
          policy={{
            maxUploadBytes: Number(policy.max_upload_bytes),
            minClipSeconds: Number(policy.min_clip_seconds),
            maxClipSeconds: Number(policy.max_clip_seconds),
            entriesPerParticipant: Number(policy.entries_per_participant),
          }}
          initialSubmissions={submissions.map((item) => ({
            submissionId: item.submission_id,
            slot: Number(item.slot),
            franchise: item.franchise,
            aniListId: item.anilist_id,
            ostTitle: item.ost_title,
            status: item.status,
            durationMismatch: item.duration_mismatch,
            version: Number(item.version),
          }))}
        />
      </section>
    </main>
  );
}
