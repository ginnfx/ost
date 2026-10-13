import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { HostTrialManagement } from "@/components/host-trial-management";
import {
  HostAccessDenied,
  SignInRequired,
  withHost,
} from "@/lib/server/database";

export const dynamic = "force-dynamic";
export const metadata = {
  title: "Trial round · OST Competition",
  robots: { index: false, follow: false },
};

export default async function HostTrialsPage() {
  try {
    await withHost(async () => undefined);
  } catch (error) {
    if (error instanceof SignInRequired) redirect("/login");
    if (error instanceof HostAccessDenied) notFound();
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
        <p className="eyebrow">PRACTICE ROUND</p>
        <h1>Trial round</h1>
        <p className="intro">
          Two entries per participant, one listening batch and one reveal group.
          Submissions close after 24 hours; ratings close after 72 hours.
        </p>
        <HostTrialManagement />
      </section>
    </main>
  );
}
