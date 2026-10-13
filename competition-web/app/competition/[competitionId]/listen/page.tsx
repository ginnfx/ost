import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ListeningWorkspace } from "@/components/listening-workspace";
import { SignInRequired, withCurrentUser } from "@/lib/server/database";
import { verifiedCurrentUser } from "@/lib/server/auth";

export const dynamic = "force-dynamic";
export const metadata = {
  title: "Listen and rate · OST Competition",
  robots: { index: false, follow: false },
};

export default async function ListeningPage({
  params,
}: {
  params: Promise<{ competitionId: string }>;
}) {
  const { competitionId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(competitionId)) notFound();
  if (!(await verifiedCurrentUser())) redirect("/login");
  try {
    const batches = await withCurrentUser(async (db) => {
      const result = await db.query(
        "select * from private.my_listening_batches($1)",
        [competitionId],
      );
      return result.rows.map((row) => ({
        number: Number(row.batch_number),
        status: row.status,
        releasedAt: row.released_at,
        entryCount: Number(row.entry_count),
        ratedCount: Number(row.rated_count),
        finalized: row.finalized,
      }));
    });
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
          <p className="eyebrow">LISTENING</p>
          <h1>Rate each soundtrack</h1>
          <p className="intro">
            Rate every anonymous clip from 1 to 10. Your ratings save after the
            server confirms them.
          </p>
          <ListeningWorkspace
            competitionId={competitionId}
            initialBatches={batches}
          />
        </section>
      </main>
    );
  } catch (error) {
    if (error instanceof SignInRequired) redirect("/login");
    notFound();
  }
}
