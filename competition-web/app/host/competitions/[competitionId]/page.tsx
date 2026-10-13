import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { HostRoundControl } from "@/components/host-round-control";
import {
  HostAccessDenied,
  SignInRequired,
  withHost,
} from "@/lib/server/database";

export const dynamic = "force-dynamic";
export const metadata = {
  title: "Host competition · OST Competition",
  robots: { index: false, follow: false },
};

export default async function HostCompetitionPage({
  params,
}: {
  params: Promise<{ competitionId: string }>;
}) {
  const { competitionId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) notFound();
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
        <Link className="text-link" href="/host/submissions">
          Submission checks
        </Link>
      </header>
      <section className="participant-home">
        <p className="eyebrow">HOST CONSOLE</p>
        <h1>Run this competition</h1>
        <HostRoundControl competitionId={competitionId} />
      </section>
    </main>
  );
}
