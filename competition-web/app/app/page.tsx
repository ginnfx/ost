import Link from "next/link";
import { redirect } from "next/navigation";
import { SignOutButton } from "@/components/signout-button";
import { withCurrentUser } from "@/lib/server/database";
import { verifiedCurrentUser } from "@/lib/server/auth";

export const dynamic = "force-dynamic";
type Membership = {
  round_name: string;
  round_status: string;
  nickname: string;
  is_trial: boolean;
};

export default async function ParticipantHome() {
  const identity = await verifiedCurrentUser();
  if (!identity) redirect("/login");
  const { memberships, isHost } = await withCurrentUser(async (db) => {
    const { rows } = await db.query<Membership>(
      "select * from private.current_memberships()",
    );
    const host = await db.query<{ is_host: boolean }>(
      "select private.is_platform_host() as is_host",
    );
    return { memberships: rows, isHost: host.rows[0]?.is_host === true };
  });
  return (
    <main className="page-shell">
      <header className="topbar">
        <Link className="wordmark" href="/">
          OST TRACKER <span>COMPETITION</span>
        </Link>
        <div className="signout-control">
          {isHost && (
            <Link className="text-link" href="/host/security">
              Host security
            </Link>
          )}
          <SignOutButton />
        </div>
      </header>
      <section className="welcome participant-home">
        <p className="eyebrow">PRIVATE COMPETITION</p>
        <h1>Your rounds</h1>
        {memberships.length === 0 ? (
          <div className="empty-state">
            <h2>No active round</h2>
            <p>
              When the host invites you to a round, it will appear here. Your
              account is signed in and ready.
            </p>
            <Link className="text-link" href="/how-it-works">
              How it works
            </Link>
          </div>
        ) : (
          <div className="round-list">
            {memberships.map((round, index) => (
              <article
                className="round-row"
                key={`${round.round_name}-${index}`}
              >
                <div>
                  <h2>{round.round_name}</h2>
                  <p>
                    {round.nickname} · {round.round_status.replaceAll("_", " ")}
                  </p>
                </div>
                {round.is_trial && <span className="trial-chip">TRIAL</span>}
              </article>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}
