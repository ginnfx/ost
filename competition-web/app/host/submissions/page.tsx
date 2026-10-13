import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { HostSubmissionReviews } from "@/components/host-submission-reviews";
import { SignInRequired, withHost } from "@/lib/server/database";

export const metadata = {
  title: "Submission review · OST Competition",
  robots: { index: false, follow: false },
};
export const dynamic = "force-dynamic";

export default async function HostSubmissionsPage() {
  try {
    await withHost(async () => undefined);
  } catch (error) {
    if (error instanceof SignInRequired) redirect("/login");
    notFound();
  }
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/app">
          OST TRACKER <span>COMPETITION</span>
        </Link>
        <Link className="text-link" href="/host/security">
          Host security
        </Link>
      </header>
      <section className="participant-home">
        <p className="eyebrow">HOST REVIEW</p>
        <h1>Submissions</h1>
        <p className="intro">
          Duplicate and prior-round reuse checks stay private to the host. Clips
          with a duration mismatch need review before submitter confirmation.
          Decisions are recorded in the host audit log.
        </p>
        <HostSubmissionReviews />
      </section>
    </main>
  );
}
